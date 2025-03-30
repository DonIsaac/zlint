const std = @import("std");
const LinterContext = @import("../lint_context.zig");
const Fix = @import("../fix.zig").Fix;
const Semantic = @import("../../semantic.zig").Semantic;
const _span = @import("../../span.zig");
const Source = @import("../../source.zig").Source;

const t = std.testing;
const print = std.debug.print;

fn createCtx(src: [:0]const u8, sema_out: *Semantic, source_out: *Source) !LinterContext {
    const src2 = try t.allocator.dupeZ(u8, src);
    var source = try Source.fromString(t.allocator, src2, null);
    errdefer source.deinit();
    source_out.* = source;

    var builder = Semantic.Builder.init(t.allocator);
    builder.withSource(&source);
    defer builder.deinit();

    var res = try builder.build(src);
    defer res.deinitErrors();
    if (res.hasErrors()) {
        defer res.value.deinit();
        print("Semantic analysis failed with {d} errors. Source:\n\n{s}\n", .{ res.errors.items.len, src });
        return error.TestFailed;
    }
    sema_out.* = res.value;
    return LinterContext.init(t.allocator, sema_out, source_out);
}

test "Dangerous fixes do not get saved when only safe fixes are allowed" {
    var sema: Semantic = undefined;
    var source: Source = undefined;
    var ctx = try createCtx("fn foo() void { return 1; }", &sema, &source);
    defer {
        var diagnostics = ctx.takeDiagnostics();
        for (diagnostics.items) |*diagnostic| {
            diagnostic.deinit(t.allocator);
        }
        diagnostics.deinit();
        ctx.deinit();
    }
    defer sema.deinit();
    defer source.deinit();

    const DangerousFixer = struct {
        span: _span.Span,

        fn remove(self: @This(), b: Fix.Builder) anyerror!Fix {
            var fix = b.delete(self.span);
            fix.meta.dangerous = true;
            return fix;
        }
    };

    const fix_ctx = DangerousFixer{ .span = _span.Span.EMPTY };
    ctx.reportWithFix(
        fix_ctx,
        ctx.diagnostic("ahhh", .{_span.LabeledSpan.from(fix_ctx.span)}),
        &DangerousFixer.remove,
    );

    try t.expectEqual(1, ctx.diagnostics.items.len);
    try t.expectEqual(null, ctx.diagnostics.items[0].fix);
    try t.expectEqualStrings("ahhh", ctx.diagnostics.items[0].err.message.borrow());
}
