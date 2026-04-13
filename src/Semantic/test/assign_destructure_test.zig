const std = @import("std");
const test_util = @import("util.zig");

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
