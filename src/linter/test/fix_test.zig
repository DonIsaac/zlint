const std = @import("std");
const util = @import("util");
const fix = @import("../fix.zig");

const Cow = util.Cow(false);
const Span = @import("../../span.zig").Span;

const t = std.testing;
const expect = t.expect;
const expectEqual = t.expectEqual;
const expectEqualStrings = t.expectEqualStrings;

const Diagnostic = @import("../lint_context.zig").Diagnostic;
const Error = @import("../../Error.zig");

const fake_err = Error.newStatic("oops");
inline fn toDiagnostic(comptime fixes: anytype) []const Diagnostic {
    // yes this returns a slice to a stack-allocated array. Yes its fine, because
    // this function is inlined.
    var diagnostics: [fixes.len]Diagnostic = undefined;
    inline for (fixes, 0..) |f, i| {
        var d = &diagnostics[i];
        d.fix = f;
        d.err = fake_err;
    }

    return diagnostics[0..fixes.len];
}

test "inserting at start of file" {
    var fixer = fix.Fixer{ .allocator = t.allocator };
    const src = "const x = 1;";

    {
        var res = try fixer.applyFixes(src, toDiagnostic([_]fix.Fix{
            .{
                .span = .{ .start = 0, .end = 0 },
                .replacement = Cow.static("const y = 2;"),
            },
        }));
        defer res.deinit(t.allocator);
        try expect(res.did_fix);
        try expectEqualStrings(
            "const y = 2;const x = 1;",
            res.source.items,
        );
    }

    {
        var res = try fixer.applyFixes(src, toDiagnostic([_]fix.Fix{
            .{
                .span = .{ .start = 0, .end = 0 },
                .replacement = Cow.static("const y = 2;\n"),
            },
            .{
                .span = .{ .start = 0, .end = 0 },
                .replacement = Cow.static("const z = 3;\n"),
            },
        }));
        defer res.deinit(t.allocator);
        try expect(res.did_fix);
        try expectEqualStrings(
            "const y = 2;\nconst z = 3;\nconst x = 1;",
            res.source.items,
        );
    }
}

test "deleting full lines" {
    var fixer = fix.Fixer{ .allocator = t.allocator };

    const source = "const x = 1;";

    var res = try fixer.applyFixes(source, toDiagnostic([_]fix.Fix{
        fix.Fix{
            .span = Span.new(0, source.len),
            .replacement = Cow.static(""),
        },
    }));
    defer res.deinit(t.allocator);

    try expect(res.did_fix);
    try expectEqualStrings("", res.source.items);
}

test "deleting a section" {
    var fixer = fix.Fixer{ .allocator = t.allocator };
    const src = "const x = 1; const y = 2; const z = 3;";

    {
        var res = try fixer.applyFixes(src, toDiagnostic([_]fix.Fix{
            .{
                .span = .{ .start = 0, .end = src.len },
                .replacement = Cow.static(""),
            },
        }));
        defer res.deinit(t.allocator);
        try expect(res.did_fix);
        try expectEqualStrings("", res.source.items);
    }

    {
        var res = try fixer.applyFixes(src, toDiagnostic([_]fix.Fix{
            .{
                .span = .{ .start = 0, .end = 13 },
                .replacement = Cow.static(""),
            },
        }));
        defer res.deinit(t.allocator);
        try expect(res.did_fix);
        try expectEqualStrings("const y = 2; const z = 3;", res.source.items);
    }

    {
        var res = try fixer.applyFixes(src, toDiagnostic([_]fix.Fix{
            .{
                .span = .{ .start = 13, .end = 26 },
                .replacement = Cow.static(""),
            },
        }));
        defer res.deinit(t.allocator);
        try expect(res.did_fix);
        try expectEqualStrings("const x = 1; const z = 3;", res.source.items);
    }

    {
        var res = try fixer.applyFixes(src, toDiagnostic([_]fix.Fix{
            .{
                .span = .{ .start = 25, .end = src.len },
                .replacement = Cow.static(""),
            },
        }));
        defer res.deinit(t.allocator);
        try expect(res.did_fix);
        try expectEqualStrings("const x = 1; const y = 2;", res.source.items);
    }
}

test "replacing a section" {
    var fixer = fix.Fixer{ .allocator = t.allocator };
    // var builder = fix.Fix.Builder{ .allocator = t.allocator };
    const src = "const x = 1; const y = 2; const z = 3;";

    {
        var res = try fixer.applyFixes(src, toDiagnostic([_]fix.Fix{
            // comptime builder.replace(Span.new(0, 12), Cow.static("const a = 4;")),
            .{
                .span = Span.new(0, 12),
                .replacement = Cow.static("const a = 4;"),
            }}));
        defer res.deinit(t.allocator);
        try expect(res.did_fix);
        try expectEqualStrings("const a = 4; const y = 2; const z = 3;", res.source.items);
    }

    {
        var res = try fixer.applyFixes(src, toDiagnostic([_]fix.Fix{
            .{
                .span = .{ .start = 13, .end = 25 },
                .replacement = Cow.static("const b = 5;"),
            },
        }));
        defer res.deinit(t.allocator);
        try expect(res.did_fix);
        try expectEqualStrings("const x = 1; const b = 5; const z = 3;", res.source.items);
    }

    {
        var res = try fixer.applyFixes(src, toDiagnostic([_]fix.Fix{
            .{
                .span = .{ .start = 26, .end = src.len },
                .replacement = Cow.static("const c = 6;"),
            },
        }));
        defer res.deinit(t.allocator);
        try expect(res.did_fix);
        try expectEqualStrings("const x = 1; const y = 2; const c = 6;", res.source.items);
    }
}

test "noop fixes" {
    var fixer = fix.Fixer{ .allocator = t.allocator };
    const source = "const x = 1;";
    const builder = fix.Fix.Builder{ .allocator = t.allocator, .ctx = undefined };
    const f = builder.noop();
    try expect(f.isNoop());

    var res = try fixer.applyFixes(source, toDiagnostic([_]fix.Fix{builder.noop()}));
    defer res.deinit(t.allocator);
    try expect(!res.did_fix);
    try expectEqual(0, res.source.items.len);
}

test "overlapping/nested fixes" {
    var fixer = fix.Fixer{ .allocator = t.allocator };
    const source =
        \\const Foo = struct {
        \\  a: u32,
        \\};
    ;
    // `a: u32` -> `b: usize`
    const into_b_usize = comptime fix.Fix{
        .span = Span.new(23, 29),
        .replacement = Cow.static("b: usize"),
    };
    // `a: u32` -> `a: bool`
    const as_bool = comptime fix.Fix{
        .span = Span.new(25, 29),
        .replacement = Cow.static("bool"),
    };
    var res = try fixer.applyFixes(source, toDiagnostic([_]fix.Fix{ into_b_usize, as_bool }));
    defer res.deinit(t.allocator);

    try expect(res.did_fix);
    try expectEqualStrings(
        \\const Foo = struct {
        \\  b: usize,
        \\};
    ,
        res.source.items,
    );
}
