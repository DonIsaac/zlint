const std = @import("std");
const test_util = @import("util.zig");

const _source = @import("../../source.zig");
const Semantic = @import("../../Semantic.zig");

const t = std.testing;

test "@import(\"std\")" {
    const src =
        \\const std = @import("std");
    ;
    var sema = try test_util.build(src);
    defer sema.deinit();
    try t.expectEqual(1, sema.modules.imports.items.len);
    const import = sema.modules.imports.items[0];
    try t.expectEqualStrings("std", import.specifier);
    try t.expectEqual(.module, import.kind);
    try t.expect(import.node != Semantic.NULL_NODE);
}

test "@import(\"foo.zig\")" {
    const src =
        \\const std = @import("foo.zig");
    ;
    var sema = try test_util.build(src);
    defer sema.deinit();
    try t.expectEqual(1, sema.modules.imports.items.len);
    const import = sema.modules.imports.items[0];
    try t.expectEqualStrings("foo.zig", import.specifier);
    try t.expectEqual(.file, import.kind);
    try t.expect(import.node != Semantic.NULL_NODE);
}

// ---------------------------------------------------------------------------
// Import extension detection handles extensions of any length
// ---------------------------------------------------------------------------

test "@import: .zon extension -> file kind" {
    const src =
        \\const cfg = @import("build.zig.zon");
    ;
    var sem = try test_util.build(src);
    defer sem.deinit();
    try t.expectEqual(@as(usize, 1), sem.modules.imports.items.len);
    try t.expectEqual(Semantic.ModuleRecord.ImportEntry.Kind.file, sem.modules.imports.items[0].kind);
}

test "@import: .c extension -> file kind (previously misclassified)" {
    const src =
        \\const c = @import("foo.c");
    ;
    var sem = try test_util.build(src);
    defer sem.deinit();
    try t.expectEqual(@as(usize, 1), sem.modules.imports.items.len);
    try t.expectEqual(Semantic.ModuleRecord.ImportEntry.Kind.file, sem.modules.imports.items[0].kind);
}

test "@import: .h extension -> file kind (previously misclassified)" {
    const src =
        \\const h = @import("foo.h");
    ;
    var sem = try test_util.build(src);
    defer sem.deinit();
    try t.expectEqual(@as(usize, 1), sem.modules.imports.items.len);
    try t.expectEqual(Semantic.ModuleRecord.ImportEntry.Kind.file, sem.modules.imports.items[0].kind);
}

test "@import: module name with no extension -> module kind" {
    const src =
        \\const std = @import("std");
        \\const builtin = @import("builtin");
    ;
    var sem = try test_util.build(src);
    defer sem.deinit();
    try t.expectEqual(@as(usize, 2), sem.modules.imports.items.len);
    for (sem.modules.imports.items) |imp| {
        try t.expectEqual(Semantic.ModuleRecord.ImportEntry.Kind.module, imp.kind);
    }
}

test "@import: trailing dot is not a file extension" {
    // Path-like specifier that ends in a dot - should not crash and should
    // not be classified as a file.
    const src =
        \\const weird = @import("weird.");
    ;
    var sem = try test_util.build(src);
    defer sem.deinit();
    try t.expectEqual(@as(usize, 1), sem.modules.imports.items.len);
    try t.expectEqual(Semantic.ModuleRecord.ImportEntry.Kind.module, sem.modules.imports.items[0].kind);
}

test "@import: leading dot only is not a file extension" {
    const src =
        \\const dot = @import(".hidden");
    ;
    var sem = try test_util.build(src);
    defer sem.deinit();
    try t.expectEqual(@as(usize, 1), sem.modules.imports.items.len);
    try t.expectEqual(Semantic.ModuleRecord.ImportEntry.Kind.module, sem.modules.imports.items[0].kind);
}

// ---------------------------------------------------------------------------
// recordImport no longer appends bogus entries after reporting an error for a
// non-string specifier.
// ---------------------------------------------------------------------------

test "@import non-string specifier does not add import entry" {
    const src =
        \\const spec = "std";
        \\const std = @import(spec);
    ;
    var result = try test_util.buildWithErrors(src);
    defer result.deinit();
    // Builder reports the error.
    try t.expect(result.hasErrors());
    // No import entry was recorded.
    try t.expectEqual(@as(usize, 0), result.value.modules.imports.items.len);
}

// ---------------------------------------------------------------------------
// withSource is safe when called multiple times (no ArcStr leak)
// ---------------------------------------------------------------------------

test "withSource: multiple calls do not leak ArcStr" {
    const a_src = try t.allocator.dupeZ(u8, "const x = 0;");
    const a_path = try t.allocator.dupe(u8, "a.zig");
    var a = try _source.Source.fromString(t.allocator, a_src, a_path);
    defer a.deinit();

    const b_src = try t.allocator.dupeZ(u8, "const y = 0;");
    const b_path = try t.allocator.dupe(u8, "b.zig");
    var b = try _source.Source.fromString(t.allocator, b_src, b_path);
    defer b.deinit();

    var builder = Semantic.Builder.init(t.allocator);
    defer builder.deinit();

    builder.withSource(&a);
    builder.withSource(&b);

    // Actually build something so the Semantic is well-formed for deinit.
    var result = try builder.build(b.text());
    defer result.deinit();
}

// ---------------------------------------------------------------------------
// addAstError handles parse errors cleanly (regression guard against a
// double-free caught by the testing allocator).
// ---------------------------------------------------------------------------

test "addAstError handles parse error without double-free" {
    const src = "const x =";
    var result = try test_util.buildWithErrors(src);
    defer result.deinit();
    try t.expect(result.hasErrors());
}

test "addAstError handles multiple parse errors without leaking" {
    const src =
        \\const x =
        \\const y =
        \\fn foo(
    ;
    var result = try test_util.buildWithErrors(src);
    defer result.deinit();
    try t.expect(result.hasErrors());
}
