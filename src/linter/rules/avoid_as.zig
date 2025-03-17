//! ## What This Rule Does
//!
//! Disallows using `@as()` when types can be otherwise inferred.
//!
//! Zig has powerful [Result Location Semantics](https://ziglang.org/documentation/master/#Result-Location-Semantics) for inferring what type
//! something should be. This happens in function parameters, return types,
//! and type annotations. `@as()` is a last resort when no other contextual
//! information is available. In any other case, other type inference mechanisms
//! should be used.
//!
//! > [!NOTE]
//! > Checks for function parameters and return types are not yet implemented.
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! const x = @as(u32, 1);
//!
//! fn foo(x: u32) u64 {
//!   return @as(u64, x); // type is inferred from return type
//! }
//! foo(@as(u32, 1)); // type is inferred from function signature
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! const x: u32 = 1;
//!
//! fn foo(x: u32) void {
//!   // ...
//! }
//! foo(1);
//! ```

const std = @import("std");
const util = @import("util");
const _source = @import("../../source.zig");
const semantic = @import("../../semantic.zig");
const Semantic = semantic.Semantic;
const _rule = @import("../rule.zig");
const _span = @import("../../span.zig");

const Ast = std.zig.Ast;
const Node = Ast.Node;
const Symbol = semantic.Symbol;
const Loc = std.zig.Loc;
const Span = _span.Span;
const LabeledSpan = _span.LabeledSpan;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const NodeWrapper = _rule.NodeWrapper;

const Error = @import("../../Error.zig");
const Cow = util.Cow(false);

// Rule metadata
const AvoidAs = @This();
pub const meta: Rule.Meta = .{
    .name = "avoid-as",
    .category = .pedantic,
    .default = .warning,
};

fn preferTypeAnnotationDiagnostic(ctx: *LinterContext, as_tok: Ast.TokenIndex) Error {
    const span = ctx.semantic.tokenSpan(as_tok);
    var e = ctx.diagnostic(
        "Prefer using type annotations over @as().",
        .{LabeledSpan.from(span)},
    );
    e.help = Cow.static("Add a type annotation to the variable declaration.");
    return e;
}

// Runs on each node in the AST. Useful for syntax-based rules.
pub fn runOnNode(_: *const AvoidAs, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const node = wrapper.node;
    if (node.tag != .builtin_call_two and node.tag != .builtin_call_comma) {
        return;
    }

    const builtin_name = ctx.semantic.tokenSlice(node.main_token);
    if (!std.mem.eql(u8, builtin_name, "@as")) {
        return;
    }

    const tags: []const Node.Tag = ctx.ast().nodes.items(.tag);
    const datas: []const Node.Data = ctx.ast().nodes.items(.data);
    const parent = ctx.links().getParent(wrapper.idx) orelse return;

    switch (tags[parent]) {
        .simple_var_decl => {
            const data = datas[parent];
            const ty_annotation = data.lhs;
            if (ty_annotation == Semantic.NULL_NODE) {
                @branchHint(.likely);
                ctx.report(preferTypeAnnotationDiagnostic(ctx, node.main_token));
            }
        },

        else => {},
    }
}

// Used by the Linter to register the rule so it can be run.
pub fn rule(self: *AvoidAs) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test AvoidAs {
    const t = std.testing;

    var avoid_as = AvoidAs{};
    var runner = RuleTester.init(t.allocator, avoid_as.rule());
    defer runner.deinit();

    // Code your rule should pass on
    const pass = &[_][:0]const u8{
        // TODO: add test cases
        "const x = 1;",
        "const x: u32 = 1;",
    };

    // Code your rule should fail on
    const fail = &[_][:0]const u8{
        // TODO: add test cases
        "const x = @as(u32, 1);",
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
