const Context = @import("./lint_context.zig");
const Semantic = @import("../Semantic.zig");
const Ast = Semantic.Ast;
const Node = Ast.Node;
const Token = Semantic.Token;

const NULL_NODE = Semantic.NULL_NODE;

/// Get the right-most identifier in a field access chain.
///
/// This is the opposite of `getLeftmostIdentifier`.
///
/// - `foo` -> `foo`
/// - `foo.bar` -> `bar`
/// - `foo()` -> `foo`
/// - `foo.bar()` -> `bar`
pub fn getRightmostIdentifier(ctx: *Context, id: Node.Index) ?[]const u8 {
    const ast = ctx.ast();
    const tag = ast.nodeTag(id);

    return switch (tag) {
        .identifier => ctx.semantic.tokenSlice(ast.nodeMainToken(id)),
        .field_access => ctx.semantic.tokenSlice(ast.nodeData(id).node_and_token[1]),
        .call, .call_comma => getRightmostIdentifier(ctx, ast.nodeData(id).node_and_extra[0]),
        .call_one, .call_one_comma => getRightmostIdentifier(ctx, ast.nodeData(id).node_and_opt_node[0]),
        else => null,
    };
}

/// Get the left-most identifier in a field access chain.
///
/// This is the opposite of `getRightmostIdentifier`.
///
/// ```zig
/// foo.bar.baz     // "foo"
/// foo.bar().baz.? // "foo"
/// ```
pub fn getLeftmostIdentifier(ctx: *Context, id: Node.Index, comptime ignore_call: bool) ?Node.Index {
    const ast = ctx.ast();

    var curr = id;
    while (true) {
        switch (ast.nodeTag(curr)) {
            .identifier => return curr,
            .call, .call_comma => {
                if (ignore_call) return null else curr = ast.nodeData(curr).node_and_extra[0];
            },
            .call_one, .call_one_comma => {
                if (ignore_call) return null else curr = ast.nodeData(curr).node_and_opt_node[0];
            },
            .field_access, .unwrap_optional => curr = ast.nodeData(curr).node_and_token[0],
            else => return null,
        }
    }
}

pub fn isInTest(ctx: *const Context, node: Node.Index) bool {
    const ast = ctx.ast();
    var parents = ctx.links().iterParentIds(node);

    while (parents.next()) |parent| {
        switch (ast.nodeTag(parent)) {
            .test_decl => return true,
            else => continue,
        }
    }
    return false;
}

pub fn isBlock(ast: *const Ast, node: Node.Index) bool {
    return switch (ast.nodeTag(node)) {
        .block, .block_semicolon, .block_two, .block_two_semicolon => true,
        else => false,
    };
}

pub inline fn isStructInit(tag: Node.Tag) bool {
    return switch (tag) {
        .struct_init,
        .struct_init_comma,
        .struct_init_dot,
        .struct_init_dot_comma,
        .struct_init_dot_two,
        .struct_init_dot_two_comma,
        .struct_init_one,
        .struct_init_one_comma,
        => true,
        else => false,
    };
}

pub inline fn isArrayInit(tag: Node.Tag) bool {
    return switch (tag) {
        .array_init,
        .array_init_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        .array_init_one,
        .array_init_one_comma,
        .array_init_two,
        .array_init_two_comma,
        => true,
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
    const tok_tags: []const Token.Tag = ast.tokens.items(.tag);
    return switch (ast.nodeTag(node)) {
        .root => NULL_NODE,
        .error_union, .merge_error_sets, .error_set_decl => node,
        .if_simple => getErrorUnion(ast, ast.nodeData(node).node_and_node[1]),
        .@"if" => blk: {
            const ifnode = ast.ifFull(node);
            const main = ast.nodeMainToken(node);
            if (main > 1 and tok_tags[main - 1] == .bang) break :blk node;
            break :blk unwrapNode(getErrorUnion(ast, ifnode.ast.then_expr)) orelse
                if (ifnode.ast.else_expr.unwrap()) |else_expr| getErrorUnion(ast, else_expr) else NULL_NODE;
        },
        else => blk: {
            const prev_tok = ast.firstToken(node) -| 1;
            break :blk if (tok_tags[prev_tok] == .bang) node else NULL_NODE;
        },
    };
}

/// Check if a type node's inner type is a pointer type.
///
/// Examples where this returns true:
/// ```
///   *T
///   []T
///   ?*T
///   Allocator.Error!*T
/// ```
pub fn isPointerType(ctx: *const Context, node: Node.Index) bool {
    const ast = ctx.ast();

    var curr = node;
    while (true) {
        switch (ast.nodeTag(curr)) {
            Node.Tag.ptr_type,
            Node.Tag.ptr_type_aligned,
            Node.Tag.ptr_type_sentinel,
            Node.Tag.ptr_type_bit_range,
            => return true,
            .optional_type => {
                curr = ast.nodeData(curr).node;
            },
            .error_union => {
                curr = ast.nodeData(curr).node_and_node[1];
            },
            else => return false,
        }
    }
}

/// Get the type inside a series of pointer/optional/error union/etc types.
/// - `*T` -> `T`
/// - `?T` -> `T`
/// - `Error!?T` -> `T`
///
pub fn getInnerType(ast: *const Ast, node: Node.Index) Node.Index {
    var curr = node;
    while (true) {
        switch (ast.nodeTag(curr)) {
            .ptr_type, .ptr_type_bit_range => curr = ast.nodeData(curr).extra_and_node[1],
            .ptr_type_aligned, .ptr_type_sentinel => curr = ast.nodeData(curr).opt_node_and_node[1],
            .optional_type => curr = ast.nodeData(curr).node,
            .error_union => curr = ast.nodeData(curr).node_and_node[1],
            else => break,
        }
    }
    return curr;
}

/// Returns `null` if `node` is the null node. Identity function otherwise.
pub inline fn unwrapNode(node: Node.Index) ?Node.Index {
    return if (node == NULL_NODE) null else node;
}
