// source: https://stackoverflow.com/q/70761612
const std = @import("std");
const Managed = std.math.big.int.Managed;

pub fn main() anyerror!void {
    const allocator = std.heap.c_allocator;

    var a = try Managed.initSet(allocator, 0);
    defer a.deinit();
    var b = try Managed.initSet(allocator, 1);
    defer b.deinit();
    var i: u128 = 0;

    var c = try Managed.init(allocator);
    defer c.deinit();

    while (i < 1000000) : (i += 1) {
        try c.add(a.toConst(), b.toConst());

        a.swap(&b); // This is more efficient than using Clone!
        b.swap(&c); // This reduced memory leak.
    }

    const as = try a.toString(allocator, 10, std.fmt.Case.lower);
    defer allocator.free(as);
    std.log.info("Fib: {s}", .{as});
}
