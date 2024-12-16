//! ## What This Rule Does
//!
//! Disallows `return`ing a `try` expression.
//!
//! Returning an error union directly has the same exact semantics as `try`ing
//! it and then returning the result.
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! const std = @import("std");
//!
//! fn foo() !void {
//!   return error.OutOfMemory;
//! }
//!
//! fn bar() !void {
//!   return try foo();
//! }
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! const std = @import("std");
//!
//! fn foo() !void {
//!   return error.OutOfMemory;
//! }
//!
//! fn bar() !void {
//!   errdefer {
//!     std.debug.print("this still gets printed.\n", .{});
//!   }
//!
//!   return foo();
//! }
//! ```

const std = @import("std");
const _source = @import("../../source.zig");
const semantic = @import("../../semantic.zig");
const _rule = @import("../rule.zig");
const _span = @import("../../span.zig");

const Ast = std.zig.Ast;
const Node = Ast.Node;
const Symbol = semantic.Symbol;
const Loc = std.zig.Loc;
const Span = _source.Span;
const LinterContext = @import("../lint_context.zig");
const LabeledSpan = _span.LabeledSpan;
const Rule = _rule.Rule;
const NodeWrapper = _rule.NodeWrapper;

// Rule metadata
const NoReturnTry = @This();
pub const meta: Rule.Meta = .{
    .name = "no-return-try",
    .category = .pedantic,
    .default = .off,
};

// Runs on each node in the AST. Useful for syntax-based rules.
pub fn runOnNode(_: *const NoReturnTry, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const ast = ctx.ast();
    const node = wrapper.node;
    const returned_id = node.data.lhs;
    if (node.tag != .@"return" or returned_id == semantic.Semantic.NULL_NODE) return;

    const returned: Node.Tag = ast.nodes.items(.tag)[returned_id];
    if (returned != .@"try") return;

    const starts = ast.tokens.items(.start);
    const return_start = starts[node.main_token];
    const try_start = starts[ast.nodes.items(.main_token)[returned_id]];
    const span = LabeledSpan.unlabeled(
        return_start,
        try_start + 3,
    );
    const e = ctx.diagnostic("This error union can be directly returned.", .{span});
    e.help = .{ .str = "Replace `return try` with `return`" };
}

pub fn rule(self: *NoReturnTry) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test NoReturnTry {
    const t = std.testing;

    var no_return_try = NoReturnTry{};
    var runner = RuleTester.init(t.allocator, no_return_try.rule());
    defer runner.deinit();

    const pass = &[_][:0]const u8{
        \\fn foo() void { return; }
        ,
        \\fn foo() !void { return; }
        \\fn bar() !void { return foo(); }
        ,
        \\fn foo() !void { return; }
        \\fn bar() !void { try foo(); }
        ,
        // should probably try to check for this case
        \\fn foo() !void { return; }
        \\fn bar() !void { return blk: { break :blk try foo(); }; }
    };

    const fail = &[_][:0]const u8{
        \\fn foo() !void { return; }
        \\fn bar() !void { return try foo(); }
        ,
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
