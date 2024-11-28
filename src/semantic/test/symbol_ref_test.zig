const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const util = @import("util");
const test_util = @import("util.zig");

const SemanticBuilder = @import("../SemanticBuilder.zig");
const Semantic = @import("../Semantic.zig");
const Symbol = @import("../Symbol.zig");
const report = @import("../../reporter.zig");
const Reference = @import("../Reference.zig");

const printer = @import("../../root.zig").printer;

const t = std.testing;
const panic = std.debug.panic;
const print = std.debug.print;
const build = test_util.build;

test "references record where and how a symbol is used" {
    const src =
        \\fn foo() u32 {
        \\  var x: u32 = 1;
        \\  const y: u32 = x + 1;
        \\  x += y;
        \\  return x;
        \\}
    ;
    var semantic = try build(src);
    defer semantic.deinit();
    const symbols = semantic.symbols;
    const scopes = semantic.scopes;

    // 0: root, 1: function signature (and params), 2: function body
    try t.expectEqual(3, scopes.len());
    try t.expectEqual(0, symbols.unresolved_references.items.len);

    const x: Symbol.Id = symbols.getSymbolNamed("x") orelse {
        @panic("Could not find variable `x`.");
    };

    var refs = symbols.iterReferences(x);
    try t.expectEqual(3, refs.len());

    // const y: u32 = x + 1;
    var ref = refs.next().?;
    try t.expectEqual(ref.flags, Reference.Flags{ .read = true });

    // x += y;
    ref = refs.next().?;
    try t.expectEqual(ref.flags, Reference.Flags{ .read = true, .write = true });

    // return x;
    ref = refs.next().?;
    try t.expectEqual(ref.flags, Reference.Flags{ .read = true });
}

const TestCase = meta.Tuple(&[_]type{ [:0]const u8, Reference.Flags });
fn testRefsOnX(cases: []const TestCase) !void {
    for (cases) |case| {
        const source = case[0];
        const expected_flags = case[1];
        var sem = try build(source);
        defer sem.deinit();

        const x: Symbol.Id = brk: {
            if (sem.symbols.getSymbolNamed("x")) |_x| {
                break :brk _x;
            } else {
                panic("Symbol 'x' not found in source:\n\n{s}\n\n", .{source});
            }
        };

        // there should be exactly 1 reference on `x` with the expected flags.
        const refs = sem.symbols.getReferences(x);
        t.expectEqual(1, refs.len) catch |e| {
            print("Source:\n\n{s}\n\n", .{source});
            return e;
        };

        const flags = sem.symbols.references.items(.flags)[refs[0].int()];
        t.expectEqual(expected_flags, flags) catch |e| {
            print("Expected: {any}\nActual:   {any}\n\n", .{ expected_flags, flags });
            print("Source:\n\n{s}\n\n", .{source});
            return e;
        };
    }
}
test "Reference flags - `x` - simple references" {
    try testRefsOnX(&[_]TestCase{
        .{
            \\const x = 1;
            \\const y = x;
            ,
            .{ .read = true },
        },
        .{
            \\const y = x;
            \\const x = 1;
            ,
            .{ .read = true },
        },
        .{
            \\fn foo() void {
            \\  var x = 1;
            \\  x = 2;
            \\}
            ,
            .{ .write = true },
        },
        .{
            \\fn foo() void {
            \\  var x = 1;
            \\  x += 2;
            \\}
            ,
            .{ .read = true, .write = true },
        },
    });
}

test "Reference flags - `x` - control flow" {
    try testRefsOnX(&[_]TestCase{
        // if
        .{
            \\const x = 1;
            \\const y = blk: {
            \\  if (x > 0) break :blk 1 else break :blk 2;
            \\};
            ,
            .{ .read = true },
        },
        .{
            \\var x = 1;
            \\var y = 2;
            \\const z = blk: {
            \\  if (y > 0) break else y = x;
            \\};
            ,
            .{ .read = true },
        },
        .{
            \\const std = @import("std");
            \\fn foo() void {
            \\  var x = 1;
            \\  const y = 2;
            \\  if (x > y) {
            \\    std.debug.print("x is greater than y\n", .{});
            \\  }
            \\}
            ,
            .{ .read = true },
        },
        // break in blocks
        .{
            \\const x = 1;
            \\const y = blk: {
            \\  break :blk x;
            \\};
            ,
            .{ .read = true },
        },
        // while
        .{
            \\fn foo() void {
            \\  var x = true;
            \\  while (x) {
            \\    break;
            \\  }
            \\}
            ,
            .{ .read = true },
        },
        .{
            \\fn foo() void {
            \\  const a: []u32 = &[_]u32{1, 2, 3};
            \\  var x = 0;
            \\  var curr = a[0];
            \\  while (true) : (x += 1) {
            \\    // don't care
            \\  }
            \\}
            ,
            .{ .read = true, .write = true },
        },
        // switch
        .{
            \\fn foo(x: u32) void {
            \\  switch(x) {
            \\    0 => @panic("x cannot be 0"),
            \\    else => {},
            \\  }
            \\}
            ,
            .{ .read = true },
        },
        .{
            \\fn foo(x: u32, y: u32) u32 {
            \\  switch(y) {
            \\    0 => return x,
            \\    else => return y,
            \\  }
            \\}
            ,
            .{ .read = true },
        },
    });
}

test "Reference flags - `x` - try/catch" {
    try testRefsOnX(&[_]TestCase{
        .{
            \\fn x() !u32 { return 1; }
            \\fn y() u32 {
            \\  return x catch unreachable;
            \\}
            ,
            .{ .read = true },
        },
        .{
            \\fn x() !u32 { return 1; }
            \\fn y() !u32 {
            \\  const z = try x();
            \\  return z;
            \\}
            ,
            .{ .call = true },
        },
        .{
            \\const x = 1;
            \\fn y() !u32 { return 1; }
            \\fn z() u32 {
            \\  return y catch return x;
            \\}
            ,
            .{ .read = true },
        },
    });
}

test "Reference flags - `x` - function calls and arguments" {
    try testRefsOnX(&[_]TestCase{
        .{
            "fn x() void {}\n fn y() void { x(); }",
            .{ .call = true },
        },
        .{
            "const x: u32; const y = @TypeOf(x);",
            .{ .read = true },
        },
        .{
            \\const std = @import("std");
            \\fn main() u32 {
            \\  const arr = std.heap.page_allocator.alloc(u32, 8) catch |x| @panic(@errorName(x));
            \\}
            ,
            .{ .read = true },
        },
        .{
            \\const std = @import("std");
            \\fn main() u32 {
            \\  const y: ?u32 = null;
            \\  if (y) |x| {
            \\    std.debug.print("y is non-null: {d}\n", .{x});
            \\  }
            \\}
            ,
            .{ .read = true },
        },
    });
}

test "Reference flags - `x` - type annotations" {
    try testRefsOnX(&[_]TestCase{
        .{
            "const x = u32; const y: x = 1;",
            .{ .type = true },
        },
        .{
            "const x = u32; const y: []x = &[_]u8{1, 2, 3};",
            .{ .type = true },
        },
        .{
            "const x = u32; const y: []const x = &[_]u8{1, 2, 3};",
            .{ .type = true },
        },
        .{
            "const x = u32; const y: *const x = &[_]u8{1, 2, 3};",
            .{ .type = true },
        },
        // FIXME: ref has incorrect flags
        // .{
        //     \\const x = u32;
        //     \\fn y(a: x) void {
        //     \\  @panic("not implemented");
        //     \\}
        //     ,
        //     .{ .type = true },
        // },
        .{
            \\const x = u32;
            \\fn y() x {
            \\  return 1;
            \\}
            ,
            .{ .type = true },
        },
        .{
            \\const x = u32;
            \\fn Foo(T: type) type {
            \\  return struct { foo: T };
            \\}
            \\const y: Foo(x) = .{ .foo = 1 };
            ,
            .{ .type = true, .read = true },
        },
        .{
            \\fn x(T: type) type {
            \\  return struct { foo: T };
            \\}
            \\fn Foo(T: type) type {
            \\  return struct { bar: T };
            \\}
            \\const y: Foo(x(u32)) = .{ .foo = .{ .bar = 1 } };
            ,
            .{ .type = true, .call = true, },
        },
    });
}

test "Reference flags - `x` - indexes and slices" {
    try testRefsOnX(&[_]TestCase {
        .{
            \\fn foo() void {
            \\  const x = [_]u32{1, 2, 3};
            \\  _ = x[1];
            \\}
            ,
            .{ .read = true },
        },
        .{
            \\fn foo() void {
            \\  const x = [_]u32{1, 2, 3};
            \\  _ = x[0..1];
            \\}
            ,
            .{ .read = true },
        },
        .{
            \\fn foo() void {
            \\  const x = 1;
            \\  const y = [_]u32{1, 2, 3};
            \\  _ = y[x];
            \\}
            ,
            .{ .read = true },
        },
        .{
            \\fn foo() void {
            \\  const x = 1;
            \\  const y = [_]u32{1, 2, 3};
            \\  _ = y[x..];
            \\}
            ,
            .{ .read = true },
        },
    });
}

test "symbols referenced before their declaration" {
    const sources = [_][:0]const u8{
        \\const y = x;
        \\const x = @import("x.zig");
        ,
        \\fn foo() void {
        \\  const y = x + 1;
        \\}
        \\const x = @import("x.zig");
        ,
        \\const y = blk: {
        \\  break :blk x;
        \\};
        \\const x = @import("x.zig");
        ,
        \\fn foo() void {
        \\  {
        \\    const y = x;
        \\    _ = y;
        \\  }
        \\  const x = 1;
        \\}
        ,
        \\fn foo() void {
        \\  const y = x;
        \\  _ = y;
        \\}
        \\const x = 1;
        ,
    };

    for (sources) |source| {
        var sem = try build(source);
        defer sem.deinit();
        // try debugSemantic(&sem);
        const x: Symbol.Id = brk: {
            if (sem.symbols.getSymbolNamed("x")) |_x| {
                break :brk _x;
            } else {
                panic("Symbol 'x' not found in source:\n\n{s}\n\n", .{source});
            }
        };
        const refs = sem.symbols.getReferences(x);
        t.expectEqual(1, refs.len) catch |e| {
            print("Source:\n\n{s}\n\n", .{source});
            return e;
        };
    }
}
