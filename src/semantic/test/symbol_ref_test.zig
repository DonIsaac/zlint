const std = @import("std");
const mem = std.mem;
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

    // FIXME: should be 2 (maybe 3?) but is 4
    try t.expectEqual(4, scopes.len());
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

test "simple references where `x` is referenced a single time" {
    const sources = [_][:0]const u8{
        \\const x = 1;
        \\const y = x;
        ,
        \\const x = 1;
        \\const y = blk: {
        \\  if (x > 0) break :blk 1 else break :blk 2;
        \\};
        ,
        \\const std = @import("std");
        \\fn foo() void {
        \\  var x = 1;
        \\  const y = 2;
        \\  if (x > y) {
        \\    std.debug.print("x is greater than y\n", .{});
        \\  }
        \\}
        ,
        \\fn foo(x: u32) u32 {
        \\  return x;
        \\}
        ,
        // FIXME: these are all failing
        // \\const std = @import("std");
        // \\fn main() u32 {
        // \\  const arr = std.heap.page_allocator.alloc(u32, 8) catch |x| @panic(@errorName(x));
        // \\}
        // ,
        \\const std = @import("std");
        \\fn main() u32 {
        \\  const y: ?u32 = null;
        \\  if (y) |x| {
        \\    std.debug.print("y is non-null: {d}\n", .{x});
        \\  }
        \\}
    };

    for (sources) |source| {
        var sem = try build(source);
        defer sem.deinit();
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
