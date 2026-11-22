const std = @import("std");
const LinterContext = @import("../lint_context.zig");
const Fix = @import("../fix.zig").Fix;
const Semantic = @import("../../Semantic.zig");
const _span = @import("../../span.zig");
const Source = @import("../../source.zig").Source;
const Rule = @import("../rule.zig").Rule;
const AvoidAs = @import("../rules/avoid_as.zig");

const t = std.testing;
const print = std.debug.print;

fn createCtx(src: [:0]const u8, sema_out: *Semantic, source_out: *Source) !LinterContext {
    const src2 = try t.allocator.dupeSentinel(u8, src, 0);
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
    return LinterContext.init(t.allocator, t.io, sema_out, source_out);
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

    ctx.fix = Fix.Meta.safe_fix;
    var impl: AvoidAs = .{};
    var rule = Rule.init(&impl);
    rule.meta.fix = Fix.Meta.dangerous_fix;
    ctx.updateForRule(&.{ .rule = rule, .severity = .err });

    const DangerousFixer = struct {
        span: _span.Span,

        fn remove(self: @This(), b: Fix.Builder) anyerror!Fix {
            return b.delete(self.span);
        }
    };

    const fix_ctx = DangerousFixer{ .span = .empty };
    ctx.reportWithFix(
        fix_ctx,
        ctx.diagnostic("ahhh", .{_span.LabeledSpan.from(fix_ctx.span)}),
        &DangerousFixer.remove,
    );

    try t.expectEqual(1, ctx.diagnostics.items.len);
    try t.expectEqual(null, ctx.diagnostics.items[0].fix);
    try t.expectEqualStrings("ahhh", ctx.diagnostics.items[0].err.message.borrow());
}

test "Dangerous fixes are saved when dangerous fixes are allowed" {
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

    ctx.fix = Fix.Meta.dangerous_fix;
    var impl: AvoidAs = .{};
    var rule = Rule.init(&impl);
    rule.meta.fix = Fix.Meta.dangerous_fix;
    ctx.updateForRule(&.{ .rule = rule, .severity = .err });

    const Fixer = struct {
        span: _span.Span,

        fn remove(self: @This(), b: Fix.Builder) anyerror!Fix {
            return b.delete(self.span);
        }
    };

    const fix_ctx = Fixer{ .span = .empty };
    ctx.reportWithFix(
        fix_ctx,
        ctx.diagnostic("ahhh", .{_span.LabeledSpan.from(fix_ctx.span)}),
        &Fixer.remove,
    );

    try t.expectEqual(1, ctx.diagnostics.items.len);
    try t.expect(ctx.diagnostics.items[0].fix != null);
    try t.expect(ctx.diagnostics.items[0].fix.?.meta.dangerous);
}

test "updateForRule tracks the current rule's needs_cfg flag" {
    var sema: Semantic = undefined;
    var source: Source = undefined;
    var ctx = try createCtx("const x = 1;", &sema, &source);
    defer {
        ctx.deinit();
        sema.deinit();
        source.deinit();
    }

    var impl: AvoidAs = .{};
    var rule = Rule.init(&impl);
    try t.expectEqual(null, ctx.curr_rule);

    rule.meta.needs_cfg = true;
    ctx.updateForRule(&.{ .rule = rule, .severity = .err });
    try t.expect(ctx.curr_rule.?.rule.meta.needs_cfg);

    rule.meta.needs_cfg = false;
    ctx.updateForRule(&.{ .rule = rule, .severity = .err });
    try t.expect(!ctx.curr_rule.?.rule.meta.needs_cfg);
}

test "Line directives suppress diagnostics whose primary label starts on their line" {
    const Suppressions = @import("../disable_directives.zig").Suppressions;
    const LabeledSpan = _span.LabeledSpan;
    const src =
        \\const a = 1;
        \\// zlint-disable-next-line avoid-as
        \\const b = 2;
    ;
    var sema: Semantic = undefined;
    var source: Source = undefined;
    var ctx = try createCtx(src, &sema, &source);
    defer {
        var diagnostics = ctx.takeDiagnostics();
        for (diagnostics.items) |*diagnostic| diagnostic.deinit(t.allocator);
        diagnostics.deinit();
        ctx.deinit();
        sema.deinit();
        source.deinit();
    }
    var suppressions: Suppressions = try .init(t.allocator, &sema);
    defer suppressions.deinit(t.allocator);
    ctx.suppressions = &suppressions;

    const line1: _span.Span = .new(0, 5);
    const b: u32 = @intCast(std.mem.indexOf(u8, src, "const b").?);
    const line3: _span.Span = .new(b, b + 5);

    // no rule is running yet
    ctx.report(ctx.diagnostic("no rule", .{LabeledSpan.unlabeled(line3)}));
    try t.expectEqual(1, ctx.diagnostics.items.len);

    var impl: AvoidAs = .{};
    const rule = Rule.init(&impl);
    ctx.updateForRule(&.{ .rule = rule, .severity = .err });
    ctx.fix = .safe_fix;

    // suppressed
    ctx.report(ctx.diagnostic("only label", .{LabeledSpan.unlabeled(line3)}));
    ctx.report(ctx.diagnostic("primary label", .{ LabeledSpan.unlabeled(line1), LabeledSpan{ .span = line3, .primary = true } }));
    const Unreachable = struct {
        fn fixer(_: void, _: Fix.Builder) anyerror!Fix {
            unreachable; // suppressed diagnostics are not fixed
        }
    };
    ctx.reportWithFix({}, ctx.diagnostic("fixed", .{LabeledSpan.unlabeled(line3)}), &Unreachable.fixer);
    try t.expectEqual(1, ctx.diagnostics.items.len);

    // not suppressed
    ctx.report(ctx.diagnostic("primary elsewhere", .{ LabeledSpan{ .span = line1, .primary = true }, LabeledSpan.unlabeled(line3) }));
    // without a primary label, the earliest one is shown, so it's the anchor
    ctx.report(ctx.diagnostic("earliest label elsewhere", .{ LabeledSpan.unlabeled(line3), LabeledSpan.unlabeled(line1) }));
    ctx.report(.newStatic("unlabeled"));
    try t.expectEqual(4, ctx.diagnostics.items.len);

    // other rules are not suppressed
    var other = rule;
    other.id = Rule.getIdFor("unsafe-undefined").?;
    ctx.updateForRule(&.{ .rule = other, .severity = .err });
    ctx.report(ctx.diagnostic("other rule", .{LabeledSpan.unlabeled(line3)}));
    try t.expectEqual(5, ctx.diagnostics.items.len);
}
