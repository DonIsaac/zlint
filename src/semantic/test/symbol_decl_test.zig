const std = @import("std");
const test_util = @import("util.zig");

const Semantic = @import("../Semantic.zig");
const Symbol = @import("../Symbol.zig");

const t = std.testing;
const build = test_util.build;
const panic = std.debug.panic;
const print = std.debug.print;

test "Symbol flags for various declarations of `x`" {
    const TestCase = std.meta.Tuple(&[_]type{ [:0]const u8, Symbol.Flags });

    const cases = [_]TestCase{
        // variables
        .{
            "const x = 1;",
            .{ .s_const = true, .s_variable = true },
        },
        .{
            "fn foo() void { const x, const y = bar(); }",
            .{ .s_const = true, .s_variable = true },
        },
        .{
            "fn foo() void { var x, const y = bar(); }",
            .{ .s_const = false, .s_variable = true },
        },
        .{
            "fn foo(x: u32) u32 { return x; }",
            .{ .s_fn_param = true, .s_const = true },
        },
        .{
            "fn foo(comptime x: u32) u32 { return x; }",
            .{ .s_fn_param = true, .s_const = true, .s_comptime = true },
        },
        .{
            "fn foo() u32 { comptime var x = 1; return x; }",
            .{ .s_variable = true, .s_comptime = true },
        },

        // members
        .{
            "const Foo = struct { x: u32 };",
            .{ .s_member = true },
        },
        .{
            "const Foo = enum { x };",
            .{ .s_member = true },
        },
        .{
            "const Foo = union(enum) { x };",
            .{ .s_member = true },
        },

        // FIXME
        // .{
        //     "const Foo = error { x };",
        //     .{ .s_member = true },
        // },

        // functions
        .{
            "fn x() void {}",
            .{ .s_fn = true },
        },

        // payloads
        .{
            "fn foo() void { const a = try std.heap.page_allocator.alloc(u8, 8) catch |x| return; _ = a; }",
            .{ .s_payload = true, .s_const = true, .s_catch_param = true },
        },
        .{
            "fn foo() void { const a: ?u32 = null; if(a) |x| { _ = x; } }",
            .{ .s_payload = true, .s_const = true },
        },
        .{
            \\fn foo() void {
            \\  const a: anyerror!u32 = 1;
            \\  if (a) {
            \\    // don't care
            \\  } else |x| {
            \\    _ = x;
            \\  }
            \\}
            ,
            .{ .s_payload = true, .s_const = true },
        },
        // FIXME: x not bound
        // .{
        //     \\const std = @import("std");
        //     \\fn foo(map: std.StringHashMap(u32)) void {
        //     \\  var it = map.entries();
        //     \\  while(it.next()) |x| {
        //     \\    std.debug.print("{d}\n", .{x.valuePtr.*});
        //     \\  }
        //     \\}
        //     ,
        //     .{ .s_payload = true, .s_const = true },
        // },
        .{
            "fn foo() void { for(0..10) |x| { _ = x; } }",
            .{ .s_payload = true, .s_const = true },
        },
        .{
            "fn foo() void { for(0..10) |*x| { _ = x; } }",
            .{ .s_payload = true, .s_const = true },
        },
    };

    for (cases) |case| {
        const source = case[0];
        const expected_flags = case[1];
        var sem = try build(source);
        defer sem.deinit();

        const x: Symbol.Id = sem.symbols.getSymbolNamed("x") orelse {
            panic("Symbol 'x' not found in source:\n\n{s}\n\n", .{source});
        };

        const flags: Symbol.Flags = sem.symbols.symbols.items(.flags)[x.int()];
        t.expectEqual(expected_flags, flags) catch |e| {
            print("Expected: {any}\nActual:   {any}\n\n", .{ expected_flags, flags });
            print("Source:\n\n{s}\n\n", .{source});
            return e;
        };
    }
}

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
        ,
        \\fn main() void {
        \\  const placeholder: ?u32 = null;
        \\  try foo() catch |err| @panic(@errorName(err));
        \\  if (placeholder) |x| {
        \\    // don't care
        \\  }
        \\}
        ,
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
