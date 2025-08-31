//! ## What This Rule Does
//! Checks for duplicate cases in switch statements.
//!
//! This rule identifies when switch statements have case branches that could
//! be merged together without affecting program behavior.
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! fn foo() void {
//!   const x = switch (1) {
//!     1 => 1,
//!     1 => 1,  // Duplicate case expression
//!   };
//! }
//!
//! fn bar(y: u32) void {
//!   const x = switch (y) {
//!     1 => y + 1,
//!     1 => 1 + y,  // Duplicate case
//!     2 => y * 2,
//!   };
//! }
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! fn foo() void {
//!   const x = switch (1) {
//!     1 => 1,
//!     2 => 2,
//!   };
//! }
//!
//! fn bar(y: u32) void {
//!   const x = switch (y) {
//!     1 => y + 1,
//!     2 => y * 2,
//!     3 => y - 1,
//!   };
//! }
//! ```

const std = @import("std");
const util = @import("util");
const ast_utils = @import("../ast_utils.zig");
const _source = @import("../../source.zig");
const _rule = @import("../rule.zig");
const _span = @import("../../span.zig");

const Loc = std.zig.Loc;
const Span = _span.Span;
const LabeledSpan = _span.LabeledSpan;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const NodeWrapper = _rule.NodeWrapper;

const Semantic = @import("../../Semantic.zig");
const Ast = Semantic.Ast;
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const Symbol = Semantic.Symbol;
const Scope = Semantic.Scope;

const Error = @import("../../Error.zig");
const Cow = util.Cow(false);
const AstComparator = @import("../../visit/AstComparator.zig");

// Rule metadata
const DuplicateCase = @This();
pub const meta: Rule.Meta = .{
    .name = "duplicate-case",
    // TODO: set the category to an appropriate value
    .category = .correctness,
};

fn duplicateCaseDiagnostic(ctx: *LinterContext, first: Node.Index, second: Node.Index) Error {
    return ctx.diagnostic(
        "Switch statement has duplicate cases",
        .{ ctx.spanN(first), ctx.spanN(second) },
    );
}

pub fn runOnNode(_: *const DuplicateCase, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const ast = ctx.ast();
    const switchStmt = ast.fullSwitch(wrapper.idx) orelse return;
    const cases = switchStmt.ast.cases;

    // check each case statement against each other
    for (cases, 0..) |case, i| {
        for ((i + 1)..cases.len) |j| {
            const other = cases[j];
            const a = ast.fullSwitchCase(case) orelse unreachable;
            const b = ast.fullSwitchCase(other) orelse unreachable;
            if (AstComparator.eql(ast, a.ast.target_expr, b.ast.target_expr)) {
                ctx.report(duplicateCaseDiagnostic(ctx, case, other));
            }
        }
    }
}

// Used by the Linter to register the rule so it can be run.
pub fn rule(self: *DuplicateCase) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test DuplicateCase {
    const t = std.testing;

    var duplicate_case = DuplicateCase{};
    var runner = RuleTester.init(t.allocator, duplicate_case.rule());
    defer runner.deinit();

    // Code your rule should pass on
    const pass = &[_][:0]const u8{
        // TODO: add test cases
        \\fn foo() void {
        \\  const x = switch (1) {
        \\    1 => 1,
        \\    2 => 2,
        \\  };
        \\}
        ,
        \\fn foo(y: u32) void {
        \\  const x = switch (1) {
        \\    1 => y - 1,
        \\    1 => 1 - y,
        \\  };
        \\}
    };

    // Code your rule should fail on
    const fail = &[_][:0]const u8{
        // TODO: add test cases
        \\fn foo() void {
        \\  const x = switch (1) {
        \\    1 => 1,
        \\    1 => 1,
        \\  };
        \\}
        ,
        \\fn foo(y: u32) void {
        \\  const x = switch (1) {
        \\    1 => y + 1,
        \\    1 => 1 + y,
        \\  };
        \\}
    };

    // _ = pass;
    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
