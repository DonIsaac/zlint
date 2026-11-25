const std = @import("std");
const Context = @import("./lint_context.zig");
const Semantic = @import("../Semantic.zig");
const Ast = Semantic.Ast;
const Node = Ast.Node;
const Scope = Semantic.Scope;
const Token = Semantic.Token;
const Source = @import("../source.zig").Source;

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
    return getErrorUnion(ast, node) != .root;
}

pub fn getErrorUnion(ast: *const Ast, node: Node.Index) Node.Index {
    const tok_tags: []const Token.Tag = ast.tokens.items(.tag);
    return switch (ast.nodeTag(node)) {
        .root => .root,
        .error_union, .merge_error_sets, .error_set_decl => node,
        .if_simple => getErrorUnion(ast, ast.nodeData(node).node_and_node[1]),
        .@"if" => blk: {
            const ifnode = ast.ifFull(node);
            const main = ast.nodeMainToken(node);
            if (main > 1 and tok_tags[main - 1] == .bang) break :blk node;
            break :blk unwrapNode(getErrorUnion(ast, ifnode.ast.then_expr)) orelse
                if (ifnode.ast.else_expr.unwrap()) |else_expr| getErrorUnion(ast, else_expr) else .root;
        },
        else => blk: {
            const prev_tok = ast.firstToken(node) -| 1;
            break :blk if (tok_tags[prev_tok] == .bang) node else .root;
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

/// Follow a bare `.identifier` one hop to the initializer of the `const`/`var`
/// declaration it is bound to.
///
/// ```zig
/// const Result = E!void;
/// //             ^^^^^^ returned for a reference to `Result`
/// ```
///
/// Returns `null` when `node` isn't an identifier, doesn't resolve to a
/// symbol, resolves to something that isn't a variable declaration (a `fn`,
/// a parameter, a container field, ...), or the declaration has no
/// initializer.
pub fn resolveConstAlias(ctx: *Context, node: Node.Index) ?Node.Index {
    const ast = ctx.ast();
    if (ast.nodeTag(node) != .identifier) return null;

    // NOTE: use direct indexing, not `links().getScope()`. `getScope` maps the
    // file's root scope to `null`, which would make container-level aliases
    // unresolvable. `homeless_try.runOnNode` indexes directly for the same
    // reason.
    const scope: Scope.Id = ctx.links().scopes.items[@backingInt(node)];
    const name = ctx.semantic.tokenSlice(ast.nodeMainToken(node));
    // `.decls` excludes container fields (`Symbol.Flags.s_member`).
    const symbol_id = ctx.semantic.resolveBinding(scope, name, .decls) orelse return null;

    const decl_node: Node.Index = ctx.symbols().symbols.items(.decl)[symbol_id.int()];
    // `fullVarDecl` returns null for fn decls, params, container fields, etc.
    const var_decl = ast.fullVarDecl(decl_node) orelse return null;
    return var_decl.ast.init_node.unwrap();
}

/// Find what `Foo` or `mod.Foo` is set to, e.g. `E!void` for `const Foo =
/// E!void;`. Returns `null` if it isn't declared in this file or more than
/// `max_depth` aliases have been followed.
pub fn resolveDeclInit(
    comptime max_depth: u8,
    ctx: *Context,
    node: Node.Index,
    depth: u8,
) ?Node.Index {
    if (depth >= max_depth) return null;
    return switch (ctx.ast().nodeTag(node)) {
        .identifier => resolveConstAlias(ctx, node),
        .field_access => resolveMemberInit(max_depth, ctx, node, depth),
        // e.g. `Result(u32)`. We'd have to run it to know what it returns.
        else => null,
    };
}

/// Follow aliases from `Foo` or `mod.Foo` to a struct, enum, union or
/// opaque. The returned `members` may point into `buf`, so keep `buf` alive
/// while you use them.
pub fn resolveContainer(
    comptime max_depth: u8,
    ctx: *Context,
    buf: *[2]Node.Index,
    node: Node.Index,
    depth: u8,
) ?Ast.full.ContainerDecl {
    if (ctx.ast().fullContainerDecl(buf, node)) |container| return container;
    const decl_init = resolveDeclInit(max_depth, ctx, node, depth) orelse return null;
    return resolveContainer(max_depth, ctx, buf, decl_init, depth + 1);
}

/// Returns `null` if `node` is the null node. Identity function otherwise.
pub inline fn unwrapNode(node: Node.Index) ?Node.Index {
    return if (node == .root) null else node;
}

/// For `mod.Foo`, find what `Foo` is set to inside `mod`. Returns null if
/// `mod` isn't a struct, enum, union or opaque in this file, or has no `Foo`.
fn resolveMemberInit(
    comptime max_depth: u8,
    ctx: *Context,
    field_access: Node.Index,
    depth: u8,
) ?Node.Index {
    std.debug.assert(depth < max_depth);
    const ast = ctx.ast();
    const lhs, const name_token = ast.nodeData(field_access).node_and_token;
    var buf: [2]Node.Index = undefined;
    const container = resolveContainer(max_depth, ctx, &buf, lhs, depth + 1) orelse return null;
    const name = ctx.semantic.tokenSlice(name_token);

    // Read the declarations from the AST. The symbol's exports also list
    // locals from inside its functions, which would give wrong matches.
    for (container.ast.members) |member| {
        const var_decl = ast.fullVarDecl(member) orelse continue;
        // Zig doesn't allow two declarations with the same name.
        if (std.mem.eql(u8, ctx.semantic.tokenSlice(var_decl.ast.mut_token + 1), name)) {
            return var_decl.ast.init_node.unwrap();
        }
    }
    return null;
}

const t = std.testing;
const semantic_utils = @import("../Semantic/test/util.zig");

/// Lint context over `src`, for testing the helpers above. Must not be moved
/// after `init`, since `ctx` points at `semantic` and `source`.
const TestContext = struct {
    source: Source,
    semantic: Semantic,
    ctx: Context,

    fn init(self: *TestContext, src: [:0]const u8) !void {
        self.source = try Source.fromString(t.allocator, try t.allocator.dupeSentinel(u8, src, 0), null);
        errdefer self.source.deinit();
        self.semantic = try semantic_utils.build(src);
        self.ctx = Context.init(t.allocator, t.io, &self.semantic, &self.source);
    }

    fn deinit(self: *TestContext) void {
        self.ctx.deinit();
        self.semantic.deinit();
        self.source.deinit();
        self.* = undefined;
    }

    /// The value of the top-level `const target = ...;`.
    fn target(self: *TestContext) !Node.Index {
        const ast = self.ctx.ast();
        for (ast.rootDecls()) |decl| {
            const var_decl = ast.fullVarDecl(decl) orelse continue;
            if (std.mem.eql(u8, ast.tokenSlice(var_decl.ast.mut_token + 1), "target")) {
                return var_decl.ast.init_node.unwrap().?;
            }
        }
        return error.NoTarget;
    }
};

test resolveDeclInit {
    const Case = struct { src: [:0]const u8, expected: ?[]const u8 };
    const cases = [_]Case{
        .{ .src = "const A = u32; const target = A;", .expected = "u32" },
        .{ .src = "const mod = struct { pub const R = error{A}!void; }; const target = mod.R;", .expected = "error{A}!void" },
        .{
            .src =
            \\const outer = struct { pub const inner = struct { pub const R = u8; }; };
            \\const alias = outer.inner;
            \\const target = alias.R;
            ,
            .expected = "u8",
        },
        // `R` inside `f` is a local, not a declaration of `mod`
        .{
            .src =
            \\const mod = struct {
            \\  fn f() void { const R = u8; _ = R; }
            \\  pub const R = u16;
            \\};
            \\const target = mod.R;
            ,
            .expected = "u16",
        },
        .{ .src = "const E = enum { a, pub const R = u8; }; const target = E.R;", .expected = "u8" },
        .{ .src = "const target = struct { const R = u8; }.R;", .expected = "u8" },
        .{ .src = "const mod = struct {}; const target = mod.R;", .expected = null },
        .{ .src = "const mod = struct { fn R() void {} }; const target = mod.R;", .expected = null },
        .{ .src = "const mod = struct { R: u8 }; const target = mod.R;", .expected = null },
        .{ .src = "const mod = @import(\"mod.zig\"); const target = mod.R;", .expected = null },
        .{ .src = "fn R(comptime T: type) type { return T; } const target = R(u8);", .expected = null },
        .{ .src = "const target = Undeclared;", .expected = null },
        // cycles stop
        .{ .src = "const A = A.B; const target = A.B;", .expected = null },
        .{ .src = "const A = B.C; const B = struct { const C = A; }; const target = A.D;", .expected = null },
    };

    for (cases) |case| {
        var tc: TestContext = undefined;
        try tc.init(case.src);
        defer tc.deinit();

        const actual = resolveDeclInit(8, &tc.ctx, try tc.target(), 0);
        const actual_src = if (actual) |node| tc.ctx.ast().getNodeSource(node) else null;
        t.expectEqualDeep(case.expected, actual_src) catch |e| {
            std.debug.print("source: {s}\n", .{case.src});
            return e;
        };
    }
}

test "resolveDeclInit stops after max_depth steps" {
    var tc: TestContext = undefined;
    try tc.init(
        \\const S = struct { const R = u8; };
        \\const A1 = S;
        \\const A2 = A1;
        \\const target = A2.R;
    );
    defer tc.deinit();
    const target = try tc.target();

    // 4 steps: look up `.R`, then `A2` -> `A1` -> `S` -> `struct { ... }`
    try t.expectEqualStrings("u8", tc.ctx.ast().getNodeSource(resolveDeclInit(4, &tc.ctx, target, 0).?));
    try t.expectEqual(null, resolveDeclInit(3, &tc.ctx, target, 0));
    try t.expectEqual(null, resolveDeclInit(4, &tc.ctx, target, 1));
}

test resolveContainer {
    const Case = struct { src: [:0]const u8, keyword: ?[]const u8, members: usize = 0 };
    const cases = [_]Case{
        // one or two members are stored in `buf`
        .{ .src = "const S = struct { const R = u8; }; const target = S;", .keyword = "struct", .members = 1 },
        .{ .src = "const S = struct { a: u8, b: u8, c: u8 }; const A = S; const target = A;", .keyword = "struct", .members = 3 },
        .{ .src = "const E = enum { a, b }; const target = E;", .keyword = "enum", .members = 2 },
        .{ .src = "const U = union(enum) { a: u8 }; const target = U;", .keyword = "union", .members = 1 },
        .{ .src = "const O = opaque {}; const target = O;", .keyword = "opaque" },
        .{ .src = "const mod = struct { pub const S = struct {}; }; const target = mod.S;", .keyword = "struct" },
        .{ .src = "const Self = @This(); const target = Self;", .keyword = null },
        .{ .src = "const target = u8;", .keyword = null },
    };

    for (cases) |case| {
        var tc: TestContext = undefined;
        try tc.init(case.src);
        defer tc.deinit();

        var buf: [2]Node.Index = undefined;
        const container = resolveContainer(8, &tc.ctx, &buf, try tc.target(), 0);
        const keyword = if (container) |c| tc.ctx.ast().tokenSlice(c.ast.main_token) else null;
        t.expectEqualDeep(case.keyword, keyword) catch |e| {
            std.debug.print("source: {s}\n", .{case.src});
            return e;
        };
        if (container) |c| try t.expectEqual(case.members, c.ast.members.len);
    }
}
