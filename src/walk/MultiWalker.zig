pub fn MultiWalker(comptime Visitor: type) type {
    comptime {
        const info = @typeInfo(Visitor);
        if (info != .Struct) {
            @compileError("Visitor must be a Visitor struct type.");
        }
    }

    return struct {
        /// FS entries to visit
        stack: std.ArrayListUnmanaged(StackItem),
        visitor: *Visitor,
        allocator: Allocator,

        const Self = @This();
        // TODO: benchmark and experiment with different initial capacities
        const INITIAL_STACK_CAPACITY: usize = 8;
        const INITIAL_NAME_BUFFER_SIZE: usize = INITIAL_STACK_CAPACITY * 32;

        pub fn init(allocator: Allocator, paths: [][:0]const u8, visitor: *Visitor) !Self {
            var stack: std.ArrayListUnmanaged(StackItem) = .{};
            try stack.ensureTotalCapacity(allocator, paths.len);

            const cwd = fs.cwd();
            for (paths) |p| {
                const stat = try cwd.statFile(p);
                const path = try allocator.dupeZ(u8, p);
                switch (stat.kind) {
                    .directory => {
                        const dir = try cwd.openDir(p, .{ .iterate = true });
                        try stack.append(allocator, .{ .dir = .{
                            .iter = dir.iterate(),
                            .path = path,
                        } });
                    },
                    else => {
                        try stack.append(allocator, .{ .filelike = .{
                            .kind = stat.kind,
                            .path = path,
                        } });
                    },
                }
            }

            return Self{
                .stack = stack,
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
                switch (top) {
                    .dir => {
                        if (top.dir.iter.next() catch |err| {
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
                            const ent = .{
                                .dir = containing.dir.iter.dir,
                                .basename = base.name,
                                // path is moved into the next directory, or if
                                // its any other kind of entry it's freed.
                                .path = fs.path.join(gpa, containing.dir.path[0..containing.dir.path.len], base.name),
                                .kind = base.kind,
                            };
                            const state: WalkState = self.visitor.visit(ent) orelse WalkState.Continue;
                            switch (state) {
                                WalkState.Continue => {},
                                WalkState.Stop => return,
                                WalkState.Skip => continue,
                            }
                            // TODO: add option to follow symlinks
                            if (base.kind == .directory) {
                                var new_dir = top.iter.dir.openDir(base.name, .{ .iterate = true }) catch |err| switch (err) {
                                    error.NameTooLong => unreachable, // no path sep in base.name
                                    // TODO: report errors
                                    // else => |e| return e,
                                    else => continue,
                                };
                                {
                                    errdefer new_dir.close();
                                    errdefer gpa.free(ent.path);
                                    try self.stack.append(gpa, .{
                                        .dir = .{
                                            .iter = new_dir.iterateAssumeFirstIteration(),
                                            .path = ent.path,
                                        },
                                    });
                                    top = &self.stack.items[self.stack.items.len - 1];
                                    containing = &self.stack.items[self.stack.items.len - 2];
                                }
                            } else {
                                gpa.free(ent.path);
                            }
                        } else {
                            var item = self.stack.pop();
                            if (self.stack.items.len != 0) {
                                item.iter.dir.close();
                            }
                        }
                    },
                    .filelike => {
                        const ent = Walker.Entry{
                            .dir = containing.dir.iter.dir,
                            .basename = fs.path.basename(top.filelike.path),
                            .path = top.filelike.path,
                            .kind = top.filelike.kind,
                        };
                        const state: WalkState = self.visitor.visit(ent) orelse WalkState.Continue;
                        switch (state) {
                            WalkState.Continue, WalkState.Continue => {},
                            WalkState.Stop => return,
                        }
                    },
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
        }
    };
}

const StackItem = union(enum) {
    dir: struct {
        iter: Dir.Iterator,
        path: [:0]const u8,
    },
    filelike: struct {
        path: [:0]const u8,
        kind: Dir.Entry.Kind,
    },

    fn path(self: *const StackItem) [:0]const u8 {
        return switch (self) {
            .dir => self.dir.path,
            .filelike => self.filelike.path,
        };
    }
};

const std = @import("std");
const fs = std.fs;
const Walker = @import("Walker.zig");

const Allocator = std.mem.Allocator;
const Dir = fs.Dir;
const WalkState = Walker.WalkState;
