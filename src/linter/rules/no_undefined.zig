const std = @import("std");
const util = @import("util");
const mem = std.mem;
const source = @import("../../source.zig");

const Ast = std.zig.Ast;
const Node = Ast.Node;
const Loc = std.zig.Loc;
const Span = source.Span;
const LinterContext = @import("../lint_context.zig");
const Rule = @import("../rule.zig").Rule;
const NodeWrapper = @import("../rule.zig").NodeWrapper;

const NoUndefined = @This();
pub const meta: Rule.Meta = .{
    .name = "no-undefined",
    .category = .restriction,
};

pub fn runOnNode(_: *const NoUndefined, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const node = wrapper.node;
    const ast = ctx.ast();

    if (node.tag != .identifier) return;
    const name = ast.getNodeSource(wrapper.idx);
    if (!std.mem.eql(u8, name, "undefined")) return;

    // `undefined` is ok if a `SAFETY: <reason>` comment is present before it.
    if (ctx.commentsBefore(node.main_token)) |comment| {
        var lines = mem.splitScalar(u8, comment, '\n');
        while (lines.next()) |line| {
            const l = util.trimWhitespace(mem.trimLeft(u8, util.trimWhitespace(line), "//"));
            if (mem.startsWith(u8, l, "SAFETY:")) return;
        }
    }

    ctx.diagnostic("Do not use undefined.", .{ctx.spanT(node.main_token)});
}

pub fn rule(self: *NoUndefined) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test NoUndefined {
    const t = std.testing;

    var no_undefined = NoUndefined{};
    var runner = RuleTester.init(t.allocator, no_undefined.rule());
    defer runner.deinit();

    const pass = &[_][:0]const u8{
        "const x: ?u32 = null;",
        \\// SAFETY: this is safe because foo bar
        \\var x: []u8 = undefined;
    };
    const fail = &[_][:0]const u8{
        "const x = undefined;",
        \\// This is not a safety comment
        \\const x = undefined;
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
