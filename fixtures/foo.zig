const std = @import("std");

var bad: []const u8 = undefined;

pub const good: ?[]const u8 = null;

const Foo = struct {
    foo: u32 = undefined,
    const Bar: u32 = 1;
    fn baz(self: *Foo) void {
        std.debug.print("{d}\n", .{self.foo});
    }
};
