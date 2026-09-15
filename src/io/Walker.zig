pub const Options = struct {
    /// Where to start walking from
    dir: Dir,
    prefix: ?[]const u8 = null,
};

pub const WalkState = enum {
    /// Continue walking the directory tree as normal.
    Continue,
    /// Skip this directory, but continue walking the rest of the tree. This
    /// directory's children will not be visited.
    Skip,
    /// Stop directory traversal.
    Stop,
};

pub const Entry = struct {
    /// The containing directory. This can be used to operate directly on `basename`
    /// rather than `path`, avoiding `error.NameTooLong` for deeply nested paths.
    /// The directory remains open until `next` or `deinit` is called.
    dir: Dir,
    basename: []const u8,
    /// Directory paths include a trailing separator. File paths do not.
    path: [:0]const u8,
    kind: Io.File.Kind,
};

pub fn Walker(comptime Visitor: type) type {
    comptime {
        const info = @typeInfo(Visitor);
        if (info != .@"struct") {
            @compileError("Visitor must be a Visitor struct type.");
        }
    }

    return struct {
        stack: std.ArrayList(StackItem),
        name_buffer: std.ArrayList(u8),
        visitor: *Visitor,
        allocator: Allocator,
        io: Io,

        const Self = @This();
        // TODO: benchmark and experiment with different initial capacities
        const INITIAL_STACK_CAPACITY: usize = 8;
        const INITIAL_NAME_BUFFER_SIZE: usize = INITIAL_STACK_CAPACITY * 32;

        pub fn initAtDir(allocator: Allocator, io: Io, options: Options, visitor: *Visitor) Allocator.Error!Self {
            var walker = try init(allocator, io, visitor);
            errdefer walker.deinit();

            const dirname_len = if (options.prefix) |p| blk: {
                try walker.name_buffer.appendSlice(allocator, p);
                break :blk p.len;
            } else 0;

            walker.stack.appendAssumeCapacity(.{
                .iter = options.dir.iterate(),
                .dirname_len = dirname_len,
            });

            return walker;
        }
        pub fn init(allocator: Allocator, io: std.Io, visitor: *Visitor) Allocator.Error!Self {
            var walker = Self{
                .stack = .empty,
                .name_buffer = .empty,
                .visitor = visitor,
                .allocator = allocator,
                .io = io,
            };

            try walker.stack.ensureTotalCapacity(allocator, INITIAL_STACK_CAPACITY);

            return walker;
        }

        pub fn walk(self: *Self) !void {
            const gpa = self.allocator;
            const io = self.io;
            while (self.stack.items.len != 0) {
                // `top` and `containing` become invalid after appending to `self.stack`
                var top = &self.stack.items[self.stack.items.len - 1];
                var containing = top;
                var dirname_len = top.dirname_len;
                if (top.iter.next(io) catch |err| {
                    // If we get an error, then we want the user to be able to continue
                    // walking if they want, which means that we need to pop the directory
                    // that errored from the stack. Otherwise, all future `next` calls would
                    // likely just fail with the same error.
                    var item = self.stack.pop() orelse unreachable;
                    if (self.stack.items.len != 0) {
                        item.iter.reader.dir.close(io);
                    }
                    // TODO: report errors
                    return err;
                }) |base| {
                    self.name_buffer.shrinkRetainingCapacity(dirname_len);
                    if (self.name_buffer.items.len != 0 and
                        !path.isSep(self.name_buffer.items[self.name_buffer.items.len - 1]))
                    {
                        try self.name_buffer.append(gpa, path.sep);
                        dirname_len += 1;
                    }
                    const path_suffix_len: usize = if (base.kind == .directory) 2 else 1;
                    try self.name_buffer.ensureUnusedCapacity(gpa, base.name.len + path_suffix_len);
                    self.name_buffer.appendSliceAssumeCapacity(base.name);
                    const basename_end = self.name_buffer.items.len;
                    if (base.kind == .directory) {
                        self.name_buffer.appendAssumeCapacity(path.sep);
                    }
                    self.name_buffer.appendAssumeCapacity(0);
                    const ent = Entry{
                        .dir = containing.iter.reader.dir,
                        .basename = self.name_buffer.items[dirname_len..basename_end],
                        .path = self.name_buffer.items[0 .. self.name_buffer.items.len - 1 :0],
                        .kind = base.kind,
                    };
                    const state: WalkState = self.visitor.visit(ent) orelse WalkState.Continue;
                    switch (state) {
                        WalkState.Continue => {},
                        WalkState.Stop => return,
                        WalkState.Skip => continue,
                    }
                    if (base.kind == .directory) {
                        var new_dir = top.iter.reader.dir.openDir(io, base.name, .{ .iterate = true }) catch |err| switch (err) {
                            error.NameTooLong => unreachable, // no path sep in base.name
                            // TODO: report errors
                            // else => |e| return e,
                            else => continue,
                        };
                        {
                            errdefer new_dir.close(io);
                            try self.stack.append(gpa, .{
                                .iter = new_dir.iterateAssumeFirstIteration(),
                                .dirname_len = self.name_buffer.items.len - 1,
                            });
                            top = &self.stack.items[self.stack.items.len - 1];
                            containing = &self.stack.items[self.stack.items.len - 2];
                        }
                    }
                } else {
                    var item = self.stack.pop() orelse unreachable;
                    if (self.stack.items.len != 0) {
                        item.iter.reader.dir.close(io);
                    }
                }
            }
            return;
        }

        pub fn deinit(self: *Self) void {
            const gpa = self.allocator;
            // Close any remaining directories except the initial one (which is always at index 0)
            if (self.stack.items.len > 1) {
                for (self.stack.items[1..]) |*item| {
                    item.iter.reader.dir.close(self.io);
                }
            }
            self.stack.deinit(gpa);
            self.name_buffer.deinit(gpa);
            self.* = undefined;
        }

        /// Prepare this walker for iteration over a new root directory.
        ///
        /// `dir` must be opened with iteration enabled.  Calling `reset` before
        /// `init` is checked illegal behavior.
        pub fn reset(self: *Self, options: Options) Allocator.Error!void {
            self.name_buffer.clearRetainingCapacity();

            const dirname_len = if (options.prefix) |p| blk: {
                try self.name_buffer.appendSlice(self.allocator, p);
                break :blk p.len;
            } else 0;

            if (self.stack.items.len > 1) {
                for (self.stack.items[1..]) |*item| {
                    item.iter.reader.dir.close(self.io);
                }
            }

            // `init` pre-allocates capacity, so there's always room.
            self.stack.clearRetainingCapacity();
            self.stack.appendAssumeCapacity(.{
                .dirname_len = dirname_len,
                .iter = options.dir.iterate(),
            });
        }
    };
}

const StackItem = struct {
    iter: Dir.Iterator,
    dirname_len: usize,
};

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const path = std.fs.path;
const Dir = Io.Dir;
