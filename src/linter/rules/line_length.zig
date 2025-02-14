const std = @import("std");
const util = @import("util");
const semantic = @import("../../semantic.zig");
const _rule = @import("../rule.zig");

const Ast = std.zig.Ast;
const Node = Ast.Node;
const Scope = semantic.Scope;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const Line = _rule.Line;
const NodeWrapper = _rule.NodeWrapper;
const Symbol = semantic.Symbol;
const Error = @import("../../Error.zig");
const Cow = util.Cow(false);

const LineLength = @This();
pub const meta: Rule.Meta = .{
    .name = "line-length",
    .category = .correctness,
    .default = .warning,
};

pub fn lineLengthDiagnostic(ctx: *LinterContext, line: Line) Error {
    return ctx.diagnosticf(
        "line length of {} is too big.",
        .{line.text.len},
        .{ctx.spanL(line)},
    );
}

pub fn runOnLine(_: *const LineLength, line: Line, ctx: *LinterContext) void {
    if (line.text.len < 120) return;
    ctx.report(lineLengthDiagnostic(ctx, line));
}

pub fn rule(self: *LineLength) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test LineLength {
    const t = std.testing;

    var line_length = LineLength{};
    var runner = RuleTester.init(t.allocator, line_length.rule());
    defer runner.deinit();

    const pass = &[_][:0]const u8{
        // TODO: add test cases
        \\const std = @import("std");
        \\fn foo() std.mem.Allocator.Error!void {
        \\  _ = try std.heap.page_allocator.alloc(u8, 8);
        \\}
    };

    const fail = &[_][:0]const u8{
        // TODO: add test cases
        \\const std = @import("std");
        \\fn foo() std.mem.Allocator.Error!void {
        \\  // ok so this is a super unnecessary line that is artificially being made long through this self-referential comment thats keeps on going until hitting a number of columns that violates the rule
        \\  _ = try std.heap.page_allocator.alloc(u8, 8);
        \\}
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
