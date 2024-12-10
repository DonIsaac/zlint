//! ## What This Rule Does
//! Disallows `catch`ing and swallowing errors.
//! 
//! More specifically, this rule bans empty `catch` statements. As of now, 
//! `catch`es that do nothing with the caught error, but do _something_ are not 
//! considered violations.
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! const x = foo() catch {};
//! const x = foo() catch {
//!   // comments within empty catch blocks have no effect.
//! };
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! const x = foo() catch @panic("foo failed.");
//! const x = foo() catch {
//!   std.debug.print("Foo failed.\n", .{});
//! };
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
const Span = _span.Span;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const LabeledSpan = _span.LabeledSpan;
const NodeWrapper = _rule.NodeWrapper;
const NULL_NODE = semantic.Semantic.NULL_NODE;

// Rule metadata
const SuppressedErrors = @This();
pub const meta: Rule.Meta = .{
    .name = "suppressed-errors",
    .category = .suspicious,
    .default = .warning,
};

// Runs on each node in the AST. Useful for syntax-based rules.
pub fn runOnNode(_: *const SuppressedErrors, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const node = wrapper.node;
    if (node.tag != .@"catch") return;

    // const slice = ctx.ast().nodes.slice
    const nodes = ctx.ast().nodes;
    const tags = nodes.items(.tag);
    const catch_body = node.data.rhs;
    // .block is only ever constructed for blocks with > 2 statements.
    switch (tags[catch_body]) {
        .block_two, .block_two_semicolon => {},
        else => return,
    }

    const stmts: Node.Data = nodes.items(.data)[catch_body];
    if (stmts.lhs == NULL_NODE and stmts.rhs == NULL_NODE) {
        const body_span = ctx.ast().nodeToSpan(catch_body);
        const catch_keyword_start: u32 = ctx.ast().tokens.items(.start)[node.main_token];
        const e = ctx.diagnostic("`catch` statement suppresses errors", .{
            LabeledSpan.unlabeled(catch_keyword_start, body_span.end),
        });
        e.help = .{ .str = "Handle this error or propagate it to the caller with `try`." };
    }
}

// Used by the Linter to register the rule so it can be run.
pub fn rule(self: *SuppressedErrors) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test SuppressedErrors {
    const t = std.testing;

    var suppressed_errors = SuppressedErrors{};
    var runner = RuleTester.init(t.allocator, suppressed_errors.rule());
    defer runner.deinit();

    // Code your rule should pass on
    const pass = &[_][:0]const u8{
        // TODO: add test cases
        // "const x = 1",
        \\fn foo() void {
        \\  try bar();
        \\}
        ,
        \\fn foo() void {
        \\  bar() catch unreachable;
        \\}
        ,
        \\fn foo() void {
        \\  bar() catch { std.debug.print("Something bad happened", .{}); };
        \\}
        ,
    };

    // Code your rule should fail on
    const fail = &[_][:0]const u8{
        \\fn foo() void {
        \\  bar() catch {};
        \\}
        ,
        \\fn foo() void {
        \\  bar() catch |_| {};
        \\}
        ,
        \\fn foo() void {
        \\  bar() catch {
        \\    // ignore
        \\  };
        \\}
        ,
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
