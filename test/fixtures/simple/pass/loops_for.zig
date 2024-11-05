const std = @import("std");

fn forOverArr() void {
    const arr = [_]u32{ 1, 2, 3, 4, 5 };

    for (arr) |i| {
        const power_of_two = 1 << i;
        std.debug.print("2^{} = {}\n", .{ i, power_of_two });
    }
}

// Copied from https://ziglang.org/documentation/master/#toc-Multidimensional-Arrays
fn forWithMultiBindingClosure() void {
    const mat4x4 = [4][4]f32{
        [_]f32{ 1.0, 0.0, 0.0, 0.0 },
        [_]f32{ 0.0, 1.0, 0.0, 1.0 },
        [_]f32{ 0.0, 0.0, 1.0, 0.0 },
        [_]f32{ 0.0, 0.0, 0.0, 1.0 },
    };
    for (mat4x4, 0..) |row, row_index| {
        for (row, 0..) |cell, column_index| {
            if (row_index == column_index) {
                try std.testing.expect(cell == 1.0);
            }
        }
    }
}
