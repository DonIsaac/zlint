const Context = @import("./lint_context.zig");
const semantic = @import("../semantic.zig");
const Semantic = semantic.Semantic;
const Node = semantic.Ast.Node;

/// - `foo` -> `foo`
/// - `foo.bar` -> `bar`
/// - `foo()` -> `foo`
/// - `foo.bar()` -> `bar`
pub fn getRightmostIdentifier(ctx: *Context, id: Node.Index) ?[]const u8 {
    const nodes = ctx.ast().nodes;
    const tag: Node.Tag = nodes.items(.tag)[id];

    return switch (tag) {
        .identifier => ctx.semantic.tokenSlice(nodes.items(.main_token)[id]),
        .field_access => ctx.semantic.tokenSlice(nodes.items(.data)[id].rhs),
        .call, .call_comma, .call_one, .call_one_comma => getRightmostIdentifier(ctx, nodes.items(.data)[id].lhs),
        else => null,
    };
}

pub fn isInTest(ctx: *const Context, node: Node.Index) bool {
    const tags: []const Node.Tag = ctx.ast().nodes.items(.tag);
    var parents = ctx.links().iterParentIds(node);

    while (parents.next()) |parent| {
        // NOTE: container and fn decls may be nested within a test.
        switch (tags[parent]) {
            .test_decl => return true,
            else => continue,
        }
    }
    return false;
}
