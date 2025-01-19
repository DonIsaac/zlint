pub fn Walker(comptime Visitor: type) type {
    comptime {
        const info = @typeInfo(Visitor);
        if (info != .Struct) {
            @compileError("Visitor must be a Visitor struct type.");
        }
    }

    return struct {
        stack: std.ArrayListUnmanaged(StackItem),
        name_buffer: std.ArrayListUnmanaged(u8),
        visitor: *Visitor,
        allocator: Allocator,

        const Self = @This();
        // TODO: benchmark and experiment with different initial capacities
        const INITIAL_STACK_CAPACITY: usize = 8;
        const INITIAL_NAME_BUFFER_SIZE: usize = INITIAL_STACK_CAPACITY * 32;

        pub fn init(allocator: Allocator, dir: fs.Dir, visitor: *Visitor) Allocator.Error!Self {
            var stack: std.ArrayListUnmanaged(StackItem) = .{};
            try stack.ensureTotalCapacity(allocator, INITIAL_STACK_CAPACITY);
            errdefer stack.deinit(allocator);

            try stack.append(allocator, .{
                .iter = dir.iterate(),
                .dirname_len = 0,
            });

            return Self{
                .stack = stack,
                .name_buffer = .{},
                .visitor = visitor,
                .allocator = allocator,
            };
        }

        pub fn walk(self: *Self) !void {
            const gpa = self.allocator;
            while (self.stack.items.len != 0) {
                // `top` and `containing` become invalid after appending to `self.stack`
                var top = &self.stack.items[self.stack.items.len - 1];
                var containing = top;
                var dirname_len = top.dirname_len;
                if (top.iter.next() catch |err| {
                    // If we get an error, then we want the user to be able to continue
                    // walking if they want, which means that we need to pop the directory
                    // that errored from the stack. Otherwise, all future `next` calls would
                    // likely just fail with the same error.
                    var item = self.stack.pop();
                    if (self.stack.items.len != 0) {
                        item.iter.dir.close();
                    }
                    // TODO: report errors
                    return err;
                }) |base| {
                    self.name_buffer.shrinkRetainingCapacity(dirname_len);
                    if (self.name_buffer.items.len != 0) {
                        try self.name_buffer.append(gpa, fs.path.sep);
                        dirname_len += 1;
                    }
                    try self.name_buffer.ensureUnusedCapacity(gpa, base.name.len + 1);
                    self.name_buffer.appendSliceAssumeCapacity(base.name);
                    self.name_buffer.appendAssumeCapacity(0);
                    const ent = .{
                        .dir = containing.iter.dir,
                        .basename = self.name_buffer.items[dirname_len .. self.name_buffer.items.len - 1 :0],
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
                        var new_dir = top.iter.dir.openDir(base.name, .{ .iterate = true }) catch |err| switch (err) {
                            error.NameTooLong => unreachable, // no path sep in base.name
                            // TODO: report errors
                            // else => |e| return e,
                            else => continue,
                        };
                        {
                            errdefer new_dir.close();
                            try self.stack.append(gpa, .{
                                .iter = new_dir.iterateAssumeFirstIteration(),
                                .dirname_len = self.name_buffer.items.len - 1,
                            });
                            top = &self.stack.items[self.stack.items.len - 1];
                            containing = &self.stack.items[self.stack.items.len - 2];
                        }
                    }
                } else {
                    var item = self.stack.pop();
                    if (self.stack.items.len != 0) {
                        item.iter.dir.close();
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
                    item.iter.dir.close();
                }
            }
            self.stack.deinit(gpa);
            self.name_buffer.deinit(gpa);
        }
    };
}

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
    basename: [:0]const u8,
    path: [:0]const u8,
    kind: Dir.Entry.Kind,
};

const StackItem = struct {
    iter: Dir.Iterator,
    dirname_len: usize,
};

const std = @import("std");
const fs = std.fs;

const Allocator = std.mem.Allocator;
const Dir = fs.Dir;
