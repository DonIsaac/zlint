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
const Fix = @import("../fix.zig").Fix;

const Error = @import("../../Error.zig");
const Cow = util.Cow(false);

// Rule metadata
const AvoidAs = @This();
pub const meta: Rule.Meta = .{
    .name = "avoid-as",
    .category = .pedantic,
    .default = .warning,
    .fix = .safe_fix,
};

fn preferTypeAnnotationDiagnostic(ctx: *LinterContext, as_tok: Ast.TokenIndex) Error {
    const span = ctx.semantic.tokenSpan(as_tok);
    var e = ctx.diagnostic(
        "Prefer using type annotations over @as().",
        .{LabeledSpan.from(span)},
    );
    e.help = Cow.static("Use a type annotation instead.");
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
                ctx.reportWithFix(
                    VarFixer{ .var_decl = parent, .var_decl_data = data, .as_args = node.data },
                    preferTypeAnnotationDiagnostic(ctx, node.main_token),
                    VarFixer.replaceWithTypeAnnotation,
                );
            }
        },

        else => {},
    }
}

const VarFixer = struct {
    /// this is a simple_var_decl node
    var_decl: Ast.Node.Index,
    var_decl_data: Node.Data,
    /// `@as(lhs, rhs)`
    as_args: Ast.Node.Data,

    fn replaceWithTypeAnnotation(this: VarFixer, builder: Fix.Builder) !Fix {
        // invalid, @as() has no args: `const x = @as();`
        if (this.as_args.lhs == Semantic.NULL_NODE or this.as_args.rhs == Semantic.NULL_NODE) {
            @branchHint(.unlikely);
            return builder.noop();
        }

        const nodes = builder.ctx.ast().nodes;
        const toks = builder.ctx.ast().tokens;
        const tok_tags: []const Semantic.Token.Tag = toks.items(.tag);

        const ty_annotation = this.var_decl_data.lhs;
        if (ty_annotation == Semantic.NULL_NODE) {
            // `const` or `var`
            var tok = nodes.items(.main_token)[this.var_decl];
            const is_const = tok_tags[tok] == .keyword_const;
            tok += 1; // next tok is the identifier
            util.debugAssert(tok_tags[tok] == .identifier, "Expected identifier, got {}", .{tok_tags[tok]});

            const ident = builder.ctx.semantic.tokenSlice(tok);
            const ty_text = builder.snippet(.node, this.as_args.lhs);
            const expr_text = builder.snippet(.node, this.as_args.rhs);
            return builder.replace(
                builder.spanCovering(.node, this.var_decl),
                try Cow.fmt(
                    builder.allocator,
                    "{s} {s}: {s} = {s}",
                    .{
                        if (is_const) "const" else "var",
                        ident,
                        ty_text,
                        expr_text,
                    },
                ),
            );
        } else {
            return builder.noop(); // TODO: just remove the @as() call.
        }
    }
};

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

    const fix = &[_]RuleTester.FixCase{
        .{
            .src = "const x = @as(u32, 1);",
            .expected = "const x: u32 = 1;",
        },
        .{
            .src = "var x = @as(u32, 1);",
            .expected = "var x: u32 = 1;",
        },
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .withFix(fix)
        .run();
}
