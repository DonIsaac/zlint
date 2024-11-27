const std = @import("std");

fn add(a: u32, b: u32) u32 {
    return a + b;
}

test add {
    try std.testing.expectEqual(2, add(1, 1));
}
test "add twice" {
    try std.testing.expectEqual(3, add(1, add(1, 1)));
}
