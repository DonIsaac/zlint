const std = @import("std");
const test_util = @import("util.zig");

const Reference = @import("../Reference.zig");

const t = std.testing;

// Tuple destructuring may assign through non-identifier lvalues (e.g. field access).
// The semantic walker must traverse these like a plain `=` LHS instead of failing analysis.
test "assign destructure: field access lvalues" {
    const src =
        \\const S = struct {
        \\    a: u32,
        \\    b: u32,
        \\};
        \\fn foo(s: *S) void {
        \\    s.a, s.b = .{ 1, 2 };
        \\}
    ;

    var semantic = try test_util.build(src);
    defer semantic.deinit();
    try t.expectEqual(0, semantic.symbols.unresolved_references.items.len);
}

// `getPtr(q).a` is a field access whose receiver is a call; receiver/args must be reads, not writes.
test "assign destructure: call + field access lvalues" {
    const src =
        \\const S = struct { a: u32, b: u32 };
        \\fn getPtr(p: *S) *S {
        \\    return p;
        \\}
        \\fn foo(q: *S) void {
        \\    getPtr(q).a, getPtr(q).b = .{ 1, 2 };
        \\}
    ;

    var semantic = try test_util.build(src);
    defer semantic.deinit();
    const symbols = semantic.symbols;
    try t.expectEqual(0, symbols.unresolved_references.items.len);

    try t.expect(symbols.getSymbolNamed("q") != null);
    const q_sym = symbols.getSymbolNamed("q").?;
    var refs = symbols.iterReferences(q_sym);
    try t.expectEqual(2, refs.len());
    while (refs.next()) |ref| {
        try t.expectEqual(Reference.Flags{ .read = true }, ref.flags);
    }

    try t.expect(symbols.getSymbolNamed("getPtr") != null);
    const get_ptr_sym = symbols.getSymbolNamed("getPtr").?;
    var get_ptr_refs = symbols.iterReferences(get_ptr_sym);
    try t.expectEqual(2, get_ptr_refs.len());
    while (get_ptr_refs.next()) |ref| {
        try t.expectEqual(Reference.Flags{ .call = true }, ref.flags);
    }
}

test "assign destructure: array index operand is read, not write" {
    const src =
        \\fn foo() void {
        \\    var x: [2]u32 = .{ 1, 2 };
        \\    var i: u32 = 0;
        \\    x[i], x[1] = .{ 3, 4 };
        \\}
    ;

    var semantic = try test_util.build(src);
    defer semantic.deinit();
    const symbols = semantic.symbols;
    try t.expectEqual(0, symbols.unresolved_references.items.len);

    try t.expect(symbols.getSymbolNamed("i") != null);
    const i_sym = symbols.getSymbolNamed("i").?;
    var refs = symbols.iterReferences(i_sym);
    try t.expectEqual(1, refs.len());
    const ref = refs.next().?;
    try t.expectEqual(Reference.Flags{ .read = true }, ref.flags);
}
