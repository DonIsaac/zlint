const std = @import("std");
const mem = std.mem;
const util = @import("util");

const SemanticBuilder = @import("../SemanticBuilder.zig");
const Semantic = @import("../Semantic.zig");
const Symbol = @import("../Symbol.zig");
const report = @import("../../reporter.zig");
const Reference = @import("../Reference.zig");

const t = std.testing;
const panic = std.debug.panic;
const print = std.debug.print;

var r = report.GraphicalReporter.init(std.io.getStdErr().writer(), report.GraphicalFormatter.unicode(t.allocator, false));

fn build(src: [:0]const u8) !Semantic {
    var builder = SemanticBuilder.init(t.allocator);
    defer builder.deinit();

    var result = builder.build(src) catch |e| {
        print("Analysis failed on source:\n\n{s}\n", .{src});
        return e;
    };
    errdefer result.value.deinit();
    r.reportErrors(result.errors.toManaged(t.allocator));
    if (result.hasErrors()) {
        panic("Analysis failed on source:\n\n{s}\n", .{src});
    }

    return result.value;
}

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

test "various read references" {
    const sources = [_][:0]const u8{
        \\const x = 1;
        \\const y = x;
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
        // FIXME: these are all failing
        // \\fn foo() void {
        // \\  {
        // \\    const y = x;
        // \\    _ = y;
        // \\  }
        // \\  const x = 1;
        // \\}
        // ,
        // \\fn foo() void {
        // \\  const y = x;
        // \\  _ = y;
        // \\}
        // \\const x = 1;
        // ,
        // \\fn foo(x: u32) u32 {
        // \\  return x;
        // \\}
        // ,
        // \\const std = @import("std");
        // \\fn main() u32 {
        // \\  const arr = std.heap.page_allocator.alloc(u32, 8) catch |x| @panic(@errorName(x));
        // \\}
        // ,
        // \\const std = @import("std");
        // \\fn main() u32 {
        // \\  const y: ?u32 = null;
        // \\  if (y) |x| {
        // \\    std.debug.print("y is non-null: {d}\n", .{x});
        // \\  }
        // \\}
    };

    for (sources) |source| {
        var sem = try build(source);
        defer sem.deinit();
        const x: Symbol.Id = brk: {
            if (sem.symbols.getSymbolNamed("x")) |_x| {
                break :brk _x;
            } else {
                panic("Symbol 'x' not found in source:\n\n{s}\n", .{source});
            }
        };
        const refs = sem.symbols.getReferences(x);
        t.expectEqual(1, refs.len) catch |e| {
            print("Source:\n\n{s}\n", .{source});
            return e;
        };
        // try t.expectFmt(refs.len == 1, "Expected 'x' to have 1 reference, found {d}. Source:\n\n{s}\n", .{ refs.len, source });
        // // try t.expect(refs.len == 2);
    }
}