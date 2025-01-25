const Context = @import("./lint_context.zig");
const semantic = @import("../semantic.zig");
const Semantic = semantic.Semantic;
const Node = semantic.Ast.Node;
const Token = Semantic.Token;
const TokenIndex = semantic.Ast.TokenIndex;

/// - `foo` -> `foo`
/// - `foo.bar` -> `bar`
/// - `foo()` -> `foo`
/// - `foo.bar()` -> `bar`
pub fn getRightmostIdentifier(ctx: *Context, id: Node.Index) ?TokenIndex {
    const nodes = ctx.ast().nodes;
    const tags: []const Node.Tag = nodes.items(.tag);

    return switch (tags[id]) {
        .identifier => nodes.items(.main_token)[id],
        .field_access => nodes.items(.data)[id].rhs,
        .call, .call_comma, .call_one, .call_one_comma => nodes.items(.data)[id].lhs,
        else => null,
    };
}
