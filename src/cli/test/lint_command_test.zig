const std = @import("std");
const Fixture = @import("Fixture.zig");
const t = std.testing;

test "ignore behavior" {
    var f = try Fixture.new(t.io, &[_]Fixture.File{});
    defer f.deinit();
}
