const std = @import("std");
const test_util = @import("util.zig");

const Symbol = @import("../Symbol.zig");

const t = std.testing;
const build = test_util.build;
const panic = std.debug.panic;
const print = std.debug.print;

const TestCase = std.meta.Tuple(&[_]type{ [:0]const u8, Symbol.Flags });

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
            \\fn foo() void {
            \\  _, const x = .{ @as(u32, 1), @as(u32, 2) };
            \\}
            ,
            .{ .s_const = true, .s_variable = true },
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
            "const x = extern struct { y: u32 };",
            .{ .s_struct = true, .s_extern = true, .s_variable = true, .s_const = true },
        },
        .{
            "const x = enum { y };",
            .{ .s_enum = true, .s_variable = true, .s_const = true },
        },
        .{
            "const x = union(enum) { y };",
            .{ .s_union = true, .s_variable = true, .s_const = true },
        },
        .{
            "const x = extern union { x: Foo, y: Bar };",
            .{ .s_union = true, .s_extern = true, .s_variable = true, .s_const = true },
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
            "x: u32", // top-level struct member
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
        .{
            \\const std = @import("std");
            \\fn foo(map: std.StringHashMap(u32)) void {
            \\  var it = map.entries();
            \\  while(it.next()) |x| {
            \\    std.debug.print("{d}\n", .{x.valuePtr.*});
            \\  }
            \\}
            ,
            .{ .s_payload = true, .s_const = true },
        },
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

// ---------------------------------------------------------------------------
// visitContainer must restore `_curr_symbol_flags` rather than re-applying
// it, or container bits latch on for declarations that follow the container
// visit. declareSymbol merges `_curr_symbol_flags` into each new symbol's
// flags, so the leak would taint subsequent sibling members.
// ---------------------------------------------------------------------------

test "visitContainer: sibling members after a nested enum do not inherit s_enum" {
    const src =
        \\pub const Foo = struct {
        \\    pub const Kind = enum { a, b };
        \\    pub const x: u32 = 0;
        \\};
    ;
    var sem = try build(src);
    defer sem.deinit();

    const kind = sem.symbols.getSymbolNamed("Kind") orelse return error.SymbolNotFound;
    const x = sem.symbols.getSymbolNamed("x") orelse return error.SymbolNotFound;

    const flags = sem.symbols.symbols.items(.flags);
    try t.expect(flags[kind.int()].s_enum);
    try t.expect(!flags[x.int()].s_enum);
    try t.expect(!flags[x.int()].s_struct);
    try t.expect(!flags[x.int()].s_union);
}

test "visitContainer: sibling members after a nested union do not inherit s_union" {
    const src =
        \\pub const Foo = struct {
        \\    pub const U = union { a: u32, b: u32 };
        \\    pub const y: u32 = 0;
        \\};
    ;
    var sem = try build(src);
    defer sem.deinit();

    const u = sem.symbols.getSymbolNamed("U") orelse return error.SymbolNotFound;
    const y = sem.symbols.getSymbolNamed("y") orelse return error.SymbolNotFound;
    const flags = sem.symbols.symbols.items(.flags);
    try t.expect(flags[u.int()].s_union);
    try t.expect(!flags[y.int()].s_union);
}

// ---------------------------------------------------------------------------
// visitFnDecl save/restore path: previously `prev_symbol_flags` captured
// `_curr_reference_flags` but the next line mutated `_curr_symbol_flags`.
// The defer restored reference flags (no-op), leaving symbol flags desynced.
// Exercise the save/restore in a nested container: repeated sibling fns must
// each correctly record as s_fn on their own symbol, and a sibling const
// must keep its expected flag shape.
// ---------------------------------------------------------------------------

test "visitFnDecl: multiple sibling fns in a container keep correct flags" {
    const src =
        \\pub const Foo = struct {
        \\    pub fn a() void {}
        \\    pub fn b() void {}
        \\    pub const c: u32 = 0;
        \\};
    ;
    var sem = try build(src);
    defer sem.deinit();

    const a = sem.symbols.getSymbolNamed("a") orelse return error.SymbolNotFound;
    const b = sem.symbols.getSymbolNamed("b") orelse return error.SymbolNotFound;
    const c = sem.symbols.getSymbolNamed("c") orelse return error.SymbolNotFound;

    const flags = sem.symbols.symbols.items(.flags);
    try t.expect(flags[a.int()].s_fn);
    try t.expect(flags[b.int()].s_fn);
    // c is a const variable, not a function
    try t.expect(!flags[c.int()].s_fn);
    try t.expect(flags[c.int()].s_const);
    try t.expect(flags[c.int()].s_variable);
}

// ---------------------------------------------------------------------------
// visitSwitchCase previously had an unbalanced scope stack on the
// MissingIdentifier early-return path because the exitScope defer was
// registered after the early return. Lock in the payload scoping behavior.
// ---------------------------------------------------------------------------

test "visitSwitchCase: valid payload declares scoped binding" {
    const src =
        \\fn foo(x: anyerror!u32) void {
        \\    switch (x) {
        \\        else => |v| {
        \\            _ = v;
        \\        },
        \\    }
        \\}
    ;
    var sem = try build(src);
    defer sem.deinit();

    const v = sem.symbols.getSymbolNamed("v") orelse return error.SymbolNotFound;
    const flags = sem.symbols.symbols.items(.flags);
    try t.expect(flags[v.int()].s_payload);
    try t.expect(flags[v.int()].s_const);
}

test "visitSwitchCase: pointer payload declares scoped binding" {
    const src =
        \\fn foo(x: *u32) void {
        \\    switch (x.*) {
        \\        else => |*p| {
        \\            _ = p;
        \\        },
        \\    }
        \\}
    ;
    var sem = try build(src);
    defer sem.deinit();

    const p = sem.symbols.getSymbolNamed("p") orelse return error.SymbolNotFound;
    const flags = sem.symbols.symbols.items(.flags);
    try t.expect(flags[p.int()].s_payload);
}

test "visitSwitchCase: no payload leaves scope stack intact" {
    const src =
        \\fn foo(x: u32) void {
        \\    switch (x) {
        \\        0 => {},
        \\        else => {},
        \\    }
        \\}
    ;
    var sem = try build(src);
    defer sem.deinit();
    // Build returned cleanly; previously this path didn't touch the buggy
    // defer but we lock it in as a regression guard.
    try t.expect(sem.symbols.getSymbolNamed("foo") != null);
}
