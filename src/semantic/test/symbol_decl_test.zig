const std = @import("std");
const test_util = @import("util.zig");

const Semantic = @import("../Semantic.zig");
const Symbol = @import("../Symbol.zig");

const t = std.testing;
const build = test_util.build;
const panic = std.debug.panic;
const print = std.debug.print;

test "control flow payloads - value and error" {
    // all of these should have `x` and `err` bound.
    const sources = [_][:0]const u8{
        \\fn main() void {
        \\  const res: anyerror!u32 = 1;
        \\  if (res) |x| {
        \\    _ = x;
        \\  } else |err| {
        \\    _ = err;
        \\  }
        \\}
    };

    for (sources) |source| {
        var sem = try build(source);
        defer sem.deinit();

        const x: Symbol.Id = sem.symbols.getSymbolNamed("x") orelse {
            panic("Symbol 'x' not found in source:\n\n{s}\n\n", .{source});
        };
        const err: Symbol.Id = sem.symbols.getSymbolNamed("err") orelse {
            panic("Symbol 'err' not found in source:\n\n{s}\n\n", .{source});
        };

        {
            const flags: Symbol.Flags = sem.symbols.symbols.items(.flags)[x.int()];
            try t.expect(flags.s_payload);
            try t.expect(flags.s_const);
        }

        {
            const flags: Symbol.Flags = sem.symbols.symbols.items(.flags)[err.int()];
            try t.expect(flags.s_payload);
            try t.expect(flags.s_const);
        }
    }
}
