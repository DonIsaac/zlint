const std = @import("std");
const test_util = @import("util.zig");

const Semantic = @import("../Semantic.zig");
const Symbol = @import("../Symbol.zig");

const t = std.testing;
const build = test_util.build;
const panic = std.debug.panic;
const print = std.debug.print;

const TestCase = std.meta.Tuple(&[_]type{ [:0]const u8, Symbol.Flags });
const TestFlagsError = error{IdentNotFound};

fn testFlags(cases: []const TestCase) !void {
    for (cases) |case| {
        const source = case[0];
        const expected_flags = case[1];
        var sem = try build(source);
        defer sem.deinit();

        const x: Symbol.Id = sem.symbols.getSymbolNamed("x") orelse {
            print("Symbol 'x' not found in source:\n\n{s}\n\n", .{source});
            return error.IdentNotFound;
        };

        const flags: Symbol.Flags = sem.symbols.symbols.items(.flags)[x.int()];
        t.expectEqual(expected_flags, flags) catch |e| {
            print("Expected: {any}\nActual:   {any}\n\n", .{ expected_flags, flags });
            print("Source:\n\n{s}\n\n", .{source});
            return e;
        };
    }
}

test "Symbol flags - variable declarations" {
    try testFlags(&[_]TestCase{
        .{
            "const x = 1;",
            .{ .s_const = true, .s_variable = true },
        },
        .{
            "export const x = 1;",
            .{ .s_const = true, .s_variable = true, .s_export = true },
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
            "fn foo() u32 { comptime var x = 1; return x; }",
            .{ .s_variable = true, .s_comptime = true },
        },
    });
}
test "Symbol flags - container declarations" {
    try testFlags(&[_]TestCase{
        .{
            "const x = struct { y: u32 };",
            .{ .s_struct = true, .s_variable = true, .s_const = true },
        },
        .{
            "const x = enum { y };",
            .{ .s_enum = true, .s_variable = true, .s_const = true },
        },
        .{
            "const x = union(enum) { y };",
            .{ .s_union = true, .s_variable = true, .s_const = true },
        },
    });
}

test "Symbol flags - container fields" {
    try testFlags(&[_]TestCase{

        // members
        .{
            "const Foo = struct { x: u32 };",
            .{ .s_struct = true, .s_member = true },
        },
        .{
            "const Foo = enum { x };",
            .{ .s_enum = true, .s_member = true },
        },
        .{
            "const Foo = union(enum) { x };",
            .{ .s_union = true, .s_member = true },
        },
        .{
            "const Foo = error { x };",
            .{ .s_error = true, .s_member = true },
        },
        .{
            "const Foo = error { z, y, x };",
            .{ .s_error = true, .s_member = true },
        },
    });
}
test "Symbol flags - in-container declarations" {
    try testFlags(&[_]TestCase{
        // non-member symbols inside containers
        .{
            "const Foo = struct { fn x() void {} };",
            .{ .s_fn = true },
        },
        .{
            "const Foo = struct { a, b, fn x() void {} };",
            .{ .s_fn = true },
        },
    });
}

test "Symbol flags - functions and function parameters" {
    try testFlags(&[_]TestCase{
        .{
            "fn x() void {}",
            .{ .s_fn = true },
        },
        .{
            "export fn x() void {}",
            .{ .s_fn = true, .s_export = true },
        },
        .{
            "extern fn x() void;",
            .{ .s_fn = true, .s_extern = true },
        },
        .{
            "const Foo = fn(x: u32) void;",
            .{ .s_fn_param = true, .s_const = true },
        },
        .{
            "const Foo = *const fn(x: u32) void;",
            .{ .s_fn_param = true, .s_const = true },
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
            "fn foo(x: type) x { @panic(\"not implemented\"); }",
            .{ .s_fn_param = true, .s_const = true },
        },
    });
}

test "Symbol flags - control flow payloads" {
    try testFlags(&[_]TestCase{
        // if
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
        // while
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
        // for
        .{
            "fn foo() void { for(0..10) |x| { _ = x; } }",
            .{ .s_payload = true, .s_const = true },
        },
        .{
            "fn foo() void { for(arr, 0..) |y, x| { _ = y; _ = x; } }",
            .{ .s_payload = true, .s_const = true },
        },
        .{
            "fn foo() void { for(0..10) |*x| { _ = x; } }",
            .{ .s_payload = true, .s_const = true },
        },
        .{
            \\fn foo() u32 {
            \\  switch (1 + 1) {
            \\    2 => |x| return x,
            \\    else => unreachable,
            \\  }
            \\}
            ,
            .{ .s_payload = true, .s_const = true },
        },
    });
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
