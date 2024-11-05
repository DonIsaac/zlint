const std = @import("std");
const builtin = @import("builtin");

// comptime if expression
const msg = if (builtin.mode == .Debug)
    "Debug mode"
else
    "Release mode";

fn simpleIf() void {
    var i: u32 = 1;

    // lonely if
    if (i % 2 == 0) {
        std.debug.print("Even\n", .{});
    }

    if (i > 5) {
        const pow = i * i; // should be in new scope
        i = pow;
    } else {
        i = 0;
    }
}

fn comptimeIf() void {

    comptime if (builtin.os.tag == .windows) {
         @compileError("Windows is not supported");
    };
}
