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
//! :::warning
//!
//! Checks for function parameters and return types are not yet implemented.
//!
//! :::
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
const Semantic = @import("../../Semantic.zig");
const _rule = @import("../rule.zig");
const _span = @import("../../span.zig");

const Ast = Semantic.Ast;
const Node = Ast.Node;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const NodeWrapper = _rule.NodeWrapper;
const Fix = @import("../fix.zig").Fix;
const Span = _span.Span;

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
    var e = ctx.diagnostic(
        "Prefer using type annotations over @as().",
        .{ctx.spanT(as_tok)},
    );
    e.help = Cow.static("Use a type annotation instead.");
    return e;
}

fn lolTheresAlreadyATypeAnnotationDiagnostic(ctx: *LinterContext, as_tok: Ast.TokenIndex) Error {
    var e = ctx.diagnostic(
        "Unnecessary use of @as().",
        .{ctx.spanT(as_tok)},
    );
    e.help = Cow.static("Remove the @as() call.");
    return e;
}

// Runs on each node in the AST. Useful for syntax-based rules.
pub fn runOnNode(_: *const AvoidAs, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const ast = ctx.ast();
    const node = wrapper.node;
    if (node.tag != .builtin_call_two and node.tag != .builtin_call_comma) {
        return;
    }

    const builtin_name = ctx.semantic.tokenSlice(node.main_token);
    if (!std.mem.eql(u8, builtin_name, "@as")) {
        return;
    }

    const parent = ctx.links().getParent(wrapper.idx) orelse return;

    // .builtin_call_two data is .opt_node_and_opt_node: [0]=first arg, [1]=second arg
    const as_args = node.data.opt_node_and_opt_node;

    switch (ast.nodeTag(parent)) {
        // var a: lhs = rhs
        .simple_var_decl => {
            // .simple_var_decl data is .opt_node_and_opt_node: [0]=type, [1]=init
            const var_data = ast.nodeData(parent).opt_node_and_opt_node;
            const ty_annotation = var_data[0];
            const diagnostic = if (ty_annotation == .none)
                preferTypeAnnotationDiagnostic(ctx, node.main_token)
            else
                lolTheresAlreadyATypeAnnotationDiagnostic(ctx, node.main_token);

            ctx.reportWithFix(
                VarFixer{ .var_decl = parent, .var_decl_data = var_data, .as_args = as_args },
                diagnostic,
                VarFixer.replaceWithTypeAnnotation,
            );
        },
        // a: lhs = rhs
        .container_field_init => ctx.reportWithFix(
            wrapper.idx,
            lolTheresAlreadyATypeAnnotationDiagnostic(ctx, node.main_token),
            &removeAs,
        ),

        else => {},
    }
}

fn removeAs(as_node: Node.Index, builder: Fix.Builder) !Fix {
    // .builtin_call_two data is .opt_node_and_opt_node: [0]=first arg, [1]=second arg
    const expr_node = builder.ctx.ast().nodeData(as_node).opt_node_and_opt_node[1].unwrap() orelse
        return builder.noop();
    const as_span = builder.spanCovering(.node, @intFromEnum(as_node));
    return builder.replace(
        as_span,
        Cow.initBorrowed(builder.snippet(.node, @intFromEnum(expr_node))),
    );
}

const OptNodePair = struct { Node.OptionalIndex, Node.OptionalIndex };

const VarFixer = struct {
    /// this is a simple_var_decl node
    var_decl: Ast.Node.Index,
    /// .opt_node_and_opt_node: [0]=type, [1]=init
    var_decl_data: OptNodePair,
    /// `@as(lhs, rhs)` — .opt_node_and_opt_node: [0]=type arg, [1]=value arg
    as_args: OptNodePair,

    fn replaceWithTypeAnnotation(this: VarFixer, builder: Fix.Builder) !Fix {
        const as_type_arg = this.as_args[0].unwrap();
        const as_value_arg = this.as_args[1].unwrap();
        // invalid, @as() has no args: `const x = @as();`
        if (as_type_arg == null or as_value_arg == null) {
            @branchHint(.unlikely);
            return builder.noop();
        }

        const ast = builder.ctx.ast();
        const toks = ast.tokens;
        const tok_tags: []const Semantic.Token.Tag = toks.items(.tag);
        const tok_locs: []const Semantic.Token.Loc = builder.ctx.tokens().items(.loc);

        const ty_annotation = this.var_decl_data[0];
        if (ty_annotation == .none) {
            const start_tok = ast.firstToken(this.var_decl);
            // `const` or `var`
            var tok = ast.nodeMainToken(this.var_decl);
            const var_prelude = Span.new(@intCast(tok_locs[start_tok].start), @intCast(tok_locs[tok].end));
            tok += 1; // next tok is the identifier
            util.debugAssert(tok_tags[tok] == .identifier, "Expected identifier, got {}", .{tok_tags[tok]});

            const prelude = var_prelude.snippet(builder.ctx.source.text());
            const ident = builder.ctx.semantic.tokenSlice(tok);
            const ty_text = builder.snippet(.node, @intFromEnum(as_type_arg.?));
            const expr_text = builder.snippet(.node, @intFromEnum(as_value_arg.?));
            return builder.replace(
                builder.spanCovering(.node, @intFromEnum(this.var_decl)),
                try Cow.fmt(
                    builder.allocator,
                    "{s} {s}: {s} = {s}",
                    .{
                        prelude,
                        ident,
                        ty_text,
                        expr_text,
                    },
                ),
            );
        } else {
            const init_node = this.var_decl_data[1].unwrap() orelse return builder.noop();
            const expr = builder.snippet(.node, @intFromEnum(as_value_arg.?));
            return builder.replace(
                builder.spanCovering(.node, @intFromEnum(init_node)),
                Cow.initBorrowed(expr),
            );
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

    const pass = &[_][:0]const u8{
        "const x = 1;",
        "const x: u32 = 1;",
        "const Foo = struct { x: u32 = 1 };",
    };

    const fail = &[_][:0]const u8{
        "const x = @as(u32, 1);",
        "const x: u32 = @as(u32, 1);",
        "const Foo = struct { x: u32 = @as(u32, 1) };",
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
        .{
            .src = "const x: u32 = @as(u32, 1);",
            .expected = "const x: u32 = 1;",
        },
        .{
            .src = "var x: u32 = @as(u32, 1);",
            .expected = "var x: u32 = 1;",
        },
        .{
            .src = "pub const x = @as(u32, 1);",
            .expected = "pub const x: u32 = 1;",
        },
        .{
            .src = "pub extern const x = @as(u32, 1);",
            .expected = "pub extern const x: u32 = 1;",
        },
        .{
            .src =
            \\fn foo() void {
            \\  comptime var x = @as(u32, 1);
            \\  _ = &x;
            \\}
            ,
            .expected =
            \\fn foo() void {
            \\  comptime var x: u32 = 1;
            \\  _ = &x;
            \\}
            ,
        },
        .{
            .src =
            \\const x = @as(u32, switch (some_comptime_enum) {
            \\  .foo => 1,
            \\  .bar => 2,
            \\  else => 3,
            \\});
            ,
            .expected =
            \\const x: u32 = switch (some_comptime_enum) {
            \\  .foo => 1,
            \\  .bar => 2,
            \\  else => 3,
            \\};
            ,
        },
        .{
            .src = "const Foo = struct { x: u32 = @as(u32, 1) };",
            .expected = "const Foo = struct { x: u32 = 1 };",
        },
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .withFix(fix)
        .run();
}
