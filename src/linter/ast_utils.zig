const Context = @import("./lint_context.zig");
const semantic = @import("../semantic.zig");
const Semantic = semantic.Semantic;
const Ast = semantic.Ast;
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
    const nodes = ctx.ast().nodes;
    const tag: Node.Tag = nodes.items(.tag)[id];

    return switch (tag) {
        .identifier => ctx.semantic.tokenSlice(nodes.items(.main_token)[id]),
        .field_access => ctx.semantic.tokenSlice(nodes.items(.data)[id].rhs),
        .call, .call_comma, .call_one, .call_one_comma => getRightmostIdentifier(ctx, nodes.items(.data)[id].lhs),
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
    const nodes = ctx.ast().nodes;
    const tags: []const Node.Tag = nodes.items(.tag);
    const datas: []const Node.Data = nodes.items(.data);

    var curr = id;
    while (true) {
        switch (tags[curr]) {
            .identifier => return curr,
            // lhs(...)
            .call,
            .call_comma,
            .call_one,
            .call_one_comma,
            => {
                if (ignore_call) return null else curr = datas[curr].lhs;
            },
            .field_access, // lhs.a
            .unwrap_optional, // lhs.?
            => curr = datas[curr].lhs,
            else => return null,
        }
    }
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
    const tags: []const Node.Tag = ast.nodes.items(.tag);
    const tok_tags: []const Token.Tag = ast.tokens.items(.tag);
    return switch (tags[node]) {
        .root => NULL_NODE,
        .error_union, .merge_error_sets, .error_set_decl => node,
        .if_simple => getErrorUnion(ast, ast.nodes.items(.data)[node].rhs),
        .@"if" => blk: {
            const ifnode = ast.ifFull(node);
            // there's a bug in fn return types for functions with return types
            // like `!if (cond) ...`. `ast.return_type` is `@"if"` instead of
            // the error union.
            const main = ast.nodes.items(.main_token)[node];
            if (main > 1 and tok_tags[main - 1] == .bang) break :blk node;
            break :blk unwrapNode(getErrorUnion(ast, ifnode.ast.then_expr)) orelse getErrorUnion(ast, ifnode.ast.else_expr);
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
    const nodes = ctx.ast().nodes;
    const tags: []const Node.Tag = nodes.items(.tag);
    var curr = node;
    while (true) {
        switch (tags[curr]) {
            Node.Tag.ptr_type,
            Node.Tag.ptr_type_aligned,
            Node.Tag.ptr_type_sentinel,
            Node.Tag.ptr_type_bit_range,
            => return true,
            .optional_type => {
                // ?lhs
                curr = nodes.items(.data)[curr].lhs;
            },
            .error_union => {
                // lhs!rhs
                curr = nodes.items(.data)[curr].rhs;
            },
            else => return false,
        }
    }
}

/// Returns `null` if `node` is the null node. Identity function otherwise.
pub inline fn unwrapNode(node: Node.Index) ?Node.Index {
    return if (node == NULL_NODE) null else node;
}
