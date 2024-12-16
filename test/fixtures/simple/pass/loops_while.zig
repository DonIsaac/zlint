const std = @import("std");

fn simpleWhile() void {
    var i: u32 = 0;

    while (i < 5) {
        const power_of_two = 1 << i;
        std.debug.print("2^{} = {}\n", .{ i, power_of_two });
        i += 1;
    }
}

fn whileWithClosure() void {
    var map = std.AutoHashMap(u32, u32){};
    map.put(1, 1);
    map.put(2, 2);
    const iter = map.iterator();
    while (iter.next()) |ent| {
        const k = ent.key_ptr.*;
        const v = ent.value_ptr.*;
        std.debug.print("{d}: {d}\n", .{ k, v });
    }
}

// copied from https://ziglang.org/documentation/master/#while
fn whileWithExpr() !void {
    var x: usize = 1;
    var y: usize = 1;
    while (x * y < 2000) : ({
        x *= 2;
        y *= 3;
    }) {
        const my_xy = x * y;
        try std.testing.expect(my_xy < 2000);
    }
}

// copied from https://ziglang.org/documentation/master/#while
fn rangeHasNumber(begin: usize, end: usize, number: usize) bool {
    var i = begin;
    return while (i < end) : (i += 1) {
        if (i == number) {
            break true;
        }
    } else false;
}
