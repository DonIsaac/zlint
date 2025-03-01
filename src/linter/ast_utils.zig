const Context = @import("./lint_context.zig");
const semantic = @import("../semantic.zig");
const Semantic = semantic.Semantic;
const Ast = semantic.Ast;
const Node = Ast.Node;
const Token = Semantic.Token;

const NULL_NODE = Semantic.NULL_NODE;

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

pub fn isBlock(tags: []const Node.Tag, node: Node.Index) bool {
    return switch (tags[node]) {
        .block, .block_semicolon, .block_two, .block_two_semicolon => true,
        else => false,
    };
}

/// Check if some type node is or has an error union.
///
/// Examples where this returns true:
/// ```zig
/// !void
/// Allocator.Error!u32
/// if (cond) !void else void
/// ```
pub fn hasErrorUnion(ast: *const Ast, node: Node.Index) bool {
    return getErrorUnion(ast, node) != NULL_NODE;
}

pub fn getErrorUnion(ast: *const Ast, node: Node.Index) Node.Index {
    const tags: []const Node.Tag = ast.nodes.items(.tag);
    return switch (tags[node]) {
        .root => NULL_NODE,
        .error_union, .merge_error_sets, .error_set_decl => node,
        .if_simple => getErrorUnion(ast, ast.nodes.items(.data)[node].rhs),
        .@"if" => blk: {
            const ifnode = ast.ifFull(node);
            break :blk unwrapNode(getErrorUnion(ast, ifnode.ast.then_expr)) orelse getErrorUnion(ast, ifnode.ast.else_expr);
        },
        else => blk: {
            const tok_tags: []const Token.Tag = ast.tokens.items(.tag);
            const prev_tok = ast.firstToken(node) -| 1;
            break :blk if (tok_tags[prev_tok] == .bang) node else NULL_NODE;
        },
    };
}

/// Returns `null` if `node` is the null node. Identity function otherwise.
pub inline fn unwrapNode(node: Node.Index) ?Node.Index {
    return if (node == NULL_NODE) null else node;
}
