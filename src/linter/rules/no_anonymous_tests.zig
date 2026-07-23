//! ## What This Rule Does
//! Flags anonymous `test { ... }` blocks — test declarations that have no name
//! string.
//!
//! Zig's `--test-filter` (and the `.filters` build API) is a compile-time,
//! name-substring filter. An anonymous test block has no name for the filter to
//! match against, so it is *always* compiled in and *always* runs — even under
//! a filter that matches nothing. This makes `--test-filter` look broken: a
//! narrow inner-loop filter still drags in every anonymous block, running
//! unrelated (and often slow) test binaries.
//!
//! The common test-aggregation idiom is exactly this shape:
//!
//! ```zig
//! test { _ = @import("foo.zig"); }           // aggregation wiring
//! test { std.testing.refAllDecls(@This()); } // coverage wiring
//! ```
//!
//! These are the worst offenders: they carry no assertions of their own, yet
//! they leak through every filter.
//!
//! ### How to fix it
//! - **Pure wiring** (a block whose statements are only `_ = ...;` discards or
//!   `refAllDecls(...)` calls): move it to a file-scope `comptime { ... }`
//!   block. A `comptime` block still forces the referenced declarations to be
//!   analyzed, so their *named* tests are still collected and stay filterable —
//!   but the block is no longer itself a test. This rewrite is mechanical
//!   (`test` → `comptime`) and is offered as an auto-fix.
//! - **A genuine anonymous test**: give it a name so it can be filtered.
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! test {
//!     _ = @import("foo.zig");
//! }
//!
//! test {
//!     try std.testing.expect(compute() == 42);
//! }
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! test "compute returns the answer" {
//!     try std.testing.expect(compute() == 42);
//! }
//!
//! comptime {
//!     _ = @import("foo.zig");
//! }
//! ```

const std = @import("std");
const util = @import("util");
const ast_utils = @import("../ast_utils.zig");
const _rule = @import("../rule.zig");
const _span = @import("../../span.zig");

const Span = _span.Span;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const NodeWrapper = _rule.NodeWrapper;
const Fix = @import("../fix.zig").Fix;

const Semantic = @import("../../Semantic.zig");
const Ast = Semantic.Ast;
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;

const Error = @import("../../Error.zig");
const Cow = util.Cow(false);

// Rule metadata
const NoAnonymousTests = @This();
pub const meta: Rule.Meta = .{
    .name = "no-anonymous-tests",
    .category = .suspicious,
    .default = .off, // TODO: promote to .warning once validated on real codebases
    .fix = .safe_fix,
};

const MESSAGE = "Anonymous test blocks always run, even under `--test-filter`.";

fn wiringDiagnostic(ctx: *LinterContext, test_tok: TokenIndex) Error {
    var e = ctx.diagnostic(
        MESSAGE,
        .{ctx.labelT(test_tok, "this test has no name to match against", .{})},
    );
    e.help = Cow.static(
        "This block only wires up other tests. Convert it to a file-scope " ++
            "`comptime` block: analysis is still forced (so the referenced tests " ++
            "are collected), but it is no longer itself a test.",
    );
    return e;
}

fn genuineTestDiagnostic(ctx: *LinterContext, test_tok: TokenIndex) Error {
    var e = ctx.diagnostic(
        MESSAGE,
        .{ctx.labelT(test_tok, "this test has no name to match against", .{})},
    );
    e.help = Cow.static(
        "Give the test a name (e.g. `test \"does the thing\" { ... }`) so it can " ++
            "be selected or skipped by `--test-filter`.",
    );
    return e;
}

// Runs on each node in the AST. Useful for syntax-based rules.
pub fn runOnNode(_: *const NoAnonymousTests, wrapper: NodeWrapper, ctx: *LinterContext) void {
    if (wrapper.node.tag != .test_decl) return;

    const ast = ctx.ast();
    // `.test_decl` data is `.opt_token_and_node`: [0] is the optional name
    // token (`.none` when the test is anonymous), [1] is the body block.
    const data = ast.nodeData(wrapper.idx).opt_token_and_node;
    if (data[0].unwrap() != null) return; // named test — nothing to flag

    // The `test` keyword itself; the target of the diagnostic and the fix.
    const test_tok = ast.nodeMainToken(wrapper.idx);

    if (isPureWiring(ctx, data[1])) {
        ctx.reportWithFix(test_tok, wiringDiagnostic(ctx, test_tok), &replaceTestWithComptime);
    } else {
        ctx.report(genuineTestDiagnostic(ctx, test_tok));
    }
}

/// A block is "pure wiring" when it has at least one statement and every
/// statement is either a discard (`_ = ...;`) or a `refAllDecls`-family call.
/// Such a block contains no assertions, so rewriting `test` to `comptime`
/// preserves behavior (the referenced tests stay collected) without silently
/// dropping a real test.
fn isPureWiring(ctx: *LinterContext, body: Node.Index) bool {
    const ast = ctx.ast();
    var buf: [2]Node.Index = undefined;
    const statements = ast.blockStatements(&buf, body) orelse return false;
    if (statements.len == 0) return false;
    for (statements) |stmt| {
        if (!isWiringStatement(ctx, stmt)) return false;
    }
    return true;
}

fn isWiringStatement(ctx: *LinterContext, stmt: Node.Index) bool {
    const ast = ctx.ast();
    switch (ast.nodeTag(stmt)) {
        // `_ = <expr>;`
        .assign => {
            const lhs = ast.nodeData(stmt).node_and_node[0];
            return isDiscard(ctx, lhs);
        },
        // `...refAllDecls(...);` / `...refAllDeclsRecursive(...);`
        .call, .call_comma, .call_one, .call_one_comma => {
            const callee = ast_utils.getRightmostIdentifier(ctx, stmt) orelse return false;
            return std.mem.eql(u8, callee, "refAllDecls") or
                std.mem.eql(u8, callee, "refAllDeclsRecursive");
        },
        else => return false,
    }
}

fn isDiscard(ctx: *LinterContext, node: Node.Index) bool {
    const ast = ctx.ast();
    if (ast.nodeTag(node) != .identifier) return false;
    return std.mem.eql(u8, ctx.semantic.tokenSlice(ast.nodeMainToken(node)), "_");
}

/// Rewrites the `test` keyword to `comptime`, leaving the block body untouched.
fn replaceTestWithComptime(test_tok: TokenIndex, builder: Fix.Builder) !Fix {
    return builder.replace(
        builder.spanCovering(.token, test_tok),
        Cow.static("comptime"),
    );
}

// Used by the Linter to register the rule so it can be run.
pub fn rule(self: *NoAnonymousTests) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test NoAnonymousTests {
    const t = std.testing;

    var no_anonymous_tests = NoAnonymousTests{};
    var runner = RuleTester.init(t.allocator, no_anonymous_tests.rule());
    defer runner.deinit();

    const pass = &[_][:0]const u8{
        // named tests are filterable
        \\const std = @import("std");
        \\test "compute returns the answer" {
        \\    try std.testing.expect(true);
        \\}
        ,
        // identifier-named test (references a decl)
        \\fn compute() bool { return true; }
        \\test compute {}
        ,
        // wiring done the right way, at file scope
        \\comptime {
        \\    _ = @import("std");
        \\}
        ,
    };

    const fail = &[_][:0]const u8{
        // pure aggregation wiring
        \\test {
        \\    _ = @import("foo.zig");
        \\}
        ,
        // refAllDecls coverage wiring
        \\const std = @import("std");
        \\test {
        \\    std.testing.refAllDecls(@This());
        \\}
        ,
        // a genuine anonymous test with a real assertion
        \\const std = @import("std");
        \\test {
        \\    try std.testing.expect(true);
        \\}
        ,
        // empty anonymous test
        \\test {}
        ,
    };

    const fix = &[_]RuleTester.FixCase{
        // single import discard
        .{
            .src =
            \\test {
            \\    _ = @import("foo.zig");
            \\}
            ,
            .expected =
            \\comptime {
            \\    _ = @import("foo.zig");
            \\}
            ,
        },
        // refAllDecls wiring
        .{
            .src =
            \\const std = @import("std");
            \\test {
            \\    std.testing.refAllDecls(@This());
            \\}
            ,
            .expected =
            \\const std = @import("std");
            \\comptime {
            \\    std.testing.refAllDecls(@This());
            \\}
            ,
        },
        // multiple wiring statements
        .{
            .src =
            \\test {
            \\    _ = @import("a.zig");
            \\    _ = @import("b.zig");
            \\}
            ,
            .expected =
            \\comptime {
            \\    _ = @import("a.zig");
            \\    _ = @import("b.zig");
            \\}
            ,
        },
        // a genuine test is NOT auto-fixed; it stays flagged
        .{
            .src =
            \\const std = @import("std");
            \\test {
            \\    try std.testing.expect(true);
            \\}
            ,
            .expected =
            \\const std = @import("std");
            \\test {
            \\    try std.testing.expect(true);
            \\}
            ,
            .fails_lint = true,
        },
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .withFix(fix)
        .run();
}
