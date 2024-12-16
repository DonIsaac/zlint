//! ## What This Rule Does
//! Disallows `catch` blocks that immediately return the caught error.
//!
//! Catch blocks that do nothing but return their error can and should be
//! replaced with a `try` statement. This rule allows for `catch`es that
//! have side effects such as printing the error or switching over it.
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! fn foo() !void {
//!   riskyOp() catch |e| return e;
//!   riskyOp() catch |e| { return e; };
//! }
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! const std = @import("std");
//!
//! fn foo() !void{
//!   try riskyOp();
//! }
//!
//! // re-throwing with side effects is fine
//! fn bar() !void {
//!   riskyOp() catch |e| {
//!     std.debug.print("Error: {any}\n", .{e});
//!     return e;
//!   };
//! }
//!
//! // throwing a new error is fine
//! fn baz() !void {
//!   riskyOp() catch |e| return error.OutOfMemory;
//! }
//! ```

const std = @import("std");
const util = @import("util");
const _source = @import("../../source.zig");
const semantic = @import("../../semantic.zig");
const _rule = @import("../rule.zig");

const Ast = std.zig.Ast;
const Node = Ast.Node;
const Token = std.zig.Token;
const TokenIndex = Ast.TokenIndex;
const Symbol = semantic.Symbol;
const Loc = std.zig.Loc;
const Span = _source.Span;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const NodeWrapper = _rule.NodeWrapper;

// Rule metadata
const NoCatchReturn = @This();
pub const meta: Rule.Meta = .{
    .name = "no-catch-return",
    // TODO: set the category to an appropriate value
    .category = .pedantic,
    .default = .warning,
};

// Runs on each node in the AST. Useful for syntax-based rules.
pub fn runOnNode(_: *const NoCatchReturn, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const tags: []const Node.Tag = ctx.ast().nodes.items(.tag);
    const tok_tags: []const Token.Tag = ctx.ast().tokens.items(.tag);
    const datas: []const Node.Data = ctx.ast().nodes.items(.data);
    const NULL_NODE = semantic.Semantic.NULL_NODE;
    const node = wrapper.node;

    if (node.tag != .@"catch") return;

    // look for a return statement. We loop to handle single-statement blocks.
    if (node.data.rhs == NULL_NODE) return;
    var return_node: Node.Index = node.data.rhs;
    while (true) {
        switch (tags[return_node]) {
            .@"return" => break,
            .block_two, .block_two_semicolon => {
                const data = datas[return_node];
                // we're looking for only a single statement in the block.
                if (data.lhs == NULL_NODE or data.rhs != NULL_NODE) return;
                return_node = data.lhs;
                continue;
            },
            // guaranteed to have more than one statement
            .block, .block_semicolon => return,
            else => return,
        }
    }

    // only check catches that bind an error payload, e.g. `catch |e|`
    var ident_tok: TokenIndex = node.main_token + 1;
    if (tok_tags[ident_tok] != .pipe) return else ident_tok += 1;
    if (tok_tags[ident_tok] == .asterisk) ident_tok += 1;
    if (tok_tags[ident_tok] != .identifier) return;

    const return_param = datas[return_node].lhs;
    if (return_param == NULL_NODE or tags[return_param] != .identifier) return;

    // todo: add symbols to node links
    const error_param = ctx.semantic.tokenSlice(ident_tok);
    const returned_ident = ctx.ast().getNodeSource(return_param);
    if (std.mem.eql(u8, error_param, returned_ident)) {
        // ctx.error(span, "returning the same error as caught");
        var err = ctx.diagnostic(
            "Caught error is immediately returned",
            .{ctx.spanN(return_node)},
        );
        err.help = .{ .str = "Use a `try` statement to return unhandled errors.", .static = true };
    }
}

// Used by the Linter to register the rule so it can be run.
pub fn rule(self: *NoCatchReturn) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test NoCatchReturn {
    const t = std.testing;

    var no_catch_return = NoCatchReturn{};
    var runner = RuleTester.init(t.allocator, no_catch_return.rule());
    defer runner.deinit();

    // Code your rule should pass on
    const pass = &[_][:0]const u8{
        // TODO: add test cases
        "fn bar() !u32 { return 1; }\nfn foo() !u32 { try bar(); return 1; }",
        \\const std = @import("std");
        \\fn bar() !u32 { return 1; }
        \\fn foo() !u32 {
        \\  const x = bar catch |e| {
        \\    std.debug.print("Error: {any}\n", .{e});
        \\    return e;
        \\  };
        \\  return x;
        \\}
        \\const std = @import("std");
        \\fn bar() !void {}
        \\fn foo() !void {
        \\  bar() catch |e| return error.OutOfMemory;
        \\}
    };

    // Code your rule should fail on
    const fail = &[_][:0]const u8{
        \\fn bar() !void { }
        \\fn foo() !void {
        \\  bar() catch |e| return e;
        \\}
        ,
        \\fn bar() !void { }
        \\fn foo() !void {
        \\  bar() catch |e| {
        \\    return e;
        \\  };
        \\}
        ,
        \\fn bar() !void { }
        \\fn foo() !void {
        \\  bar() catch |e| {
        \\    // comments won't save you
        \\    return e;
        \\  };
        \\}
        ,
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
