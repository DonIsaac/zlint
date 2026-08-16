//! Compares two AST subtrees for equality.
const AstComparator = @This();

// todo: store token list to avoid re-parsing when comparing toks.
ast: *const Ast,

pub fn eql(ast: *const Ast, a: Node.Index, b: Node.Index) bool {
    if (a == b) {
        @branchHint(.unlikely);
        return true;
    }
    const tag: Node.Tag = ast.nodeTag(a);
    const other: Node.Tag = ast.nodeTag(b);
    if (!tagsCompatible(tag, other)) return false;
    const comparator = AstComparator{ .ast = ast };
    return comparator.eqlInner(a, b);
}

fn eqlInner(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    const x = self.ast.nodeTag(a);
    const y = self.ast.nodeTag(b);
    if (!tagsCompatible(x, y)) return false;

    return switch (@as(Node.Tag, x)) {
        .if_simple => self.eqlIfSimple(a, b),
        .@"if" => self.eqlIf(a, b),
        .call_one, .call_one_comma, .call_comma, .call => self.eqlCall(a, b),
        .builtin_call_two,
        .builtin_call_two_comma,
        .builtin_call,
        .builtin_call_comma,
        => self.eqlBuiltinCall(a, b),
        .array_init_one,
        .array_init_one_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .array_init,
        .array_init_comma,
        => self.eqlArrayInit(a, b),
        .slice_open, .slice, .slice_sentinel => self.eqlSlice(a, b),
        .array_type, .array_type_sentinel => self.eqlArrayType(a, b),
        .field_access => self.eqlFieldAccess(a, b),
        .block, .block_semicolon => self.eqlBlock(a, b),
        .block_two, .block_two_semicolon => self.eqlBlockTwo(a, b),
        .deref,
        .@"suspend",
        .@"resume",
        .@"comptime",
        .@"nosuspend",
        .@"try",
        .bool_not,
        .optional_type,
        .negation,
        .negation_wrap,
        .bit_not,
        .address_of,
        => self.eqlNode(a, b),
        .@"return" => self.eqlOptNode(a, b),
        .unwrap_optional, .grouped_expression => self.eqlNodeAndToken(a, b),
        .@"defer" => self.eqlNode(a, b),
        .@"errdefer" => self.eqlOptTokenAndNode(a, b),
        .@"break", .@"continue" => self.eqlOptTokenAndOptNode(a, b),
        .for_range => self.eqlNodeAndOptNode(a, b),
        .@"catch" => self.eqlCatch(a, b),
        .sub,
        .div,
        .mod,
        .less_than,
        .greater_than,
        .less_or_equal,
        .greater_or_equal,
        .assign_mul,
        .assign_div,
        .assign_mod,
        .assign_add,
        .assign_sub,
        .assign_shl,
        .assign_shl_sat,
        .assign_shr,
        .assign_bit_and,
        .assign_bit_xor,
        .assign_bit_or,
        .assign_mul_wrap,
        .assign_add_wrap,
        .assign_sub_wrap,
        .assign_mul_sat,
        .assign_add_sat,
        .assign_sub_sat,
        .assign,
        .merge_error_sets,
        .array_mult,
        .mul_wrap,
        .mul_sat,
        .array_cat,
        .add_wrap,
        .sub_wrap,
        .add_sat,
        .sub_sat,
        .shl,
        .shl_sat,
        .shr,
        .bit_xor,
        .@"orelse",
        .bool_and,
        .bool_or,
        .array_access,
        .switch_range,
        .error_union,
        => self.binExprEql(a, b),
        .add,
        .mul,
        .bit_and,
        .bit_or,
        .equal_equal,
        .bang_equal,
        => self.binExprEqlReflexive(a, b),
        .number_literal,
        .string_literal,
        .enum_literal,
        .char_literal,
        .identifier,
        => self.mainTokensEql(a, b),
        .global_var_decl, .local_var_decl, .aligned_var_decl, .simple_var_decl => self.eqlVarDecl(a, b),
        .multiline_string_literal, .error_set_decl => self.eqlTokenRange(a, b),
        .error_value => self.eqlErrorValue(a, b),
        .anyframe_type => self.eqlTokenAndNode(a, b),
        .anyframe_literal => true,
        .unreachable_literal,
        .root, // null node
        => true,
        else => false,
    };
}

fn tagsCompatible(a: Node.Tag, b: Node.Tag) bool {
    if (a == b) return true;

    return switch (a) {
        .call_one,
        .call_one_comma,
        .call,
        .call_comma,
        => switch (b) {
            .call_one, .call_one_comma, .call, .call_comma => true,
            else => false,
        },
        .builtin_call_two,
        .builtin_call_two_comma,
        .builtin_call,
        .builtin_call_comma,
        => switch (b) {
            .builtin_call_two,
            .builtin_call_two_comma,
            .builtin_call,
            .builtin_call_comma,
            => true,
            else => false,
        },
        .array_init_one,
        .array_init_one_comma,
        .array_init_dot_two,
        .array_init_dot_two_comma,
        .array_init_dot,
        .array_init_dot_comma,
        .array_init,
        .array_init_comma,
        => switch (b) {
            .array_init_one,
            .array_init_one_comma,
            .array_init_dot_two,
            .array_init_dot_two_comma,
            .array_init_dot,
            .array_init_dot_comma,
            .array_init,
            .array_init_comma,
            => true,
            else => false,
        },
        .slice_open, .slice, .slice_sentinel => switch (b) {
            .slice_open, .slice, .slice_sentinel => true,
            else => false,
        },
        .array_type, .array_type_sentinel => switch (b) {
            .array_type, .array_type_sentinel => true,
            else => false,
        },
        .global_var_decl,
        .local_var_decl,
        .aligned_var_decl,
        .simple_var_decl,
        => switch (b) {
            .global_var_decl,
            .local_var_decl,
            .aligned_var_decl,
            .simple_var_decl,
            => true,
            else => false,
        },
        else => false,
    };
}

/// check if two `.field_access` expressions (`foo.bar`) are equal
fn eqlFieldAccess(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    const left_obj, const left_field = self.ast.nodeData(a).node_and_token;
    const right_obj, const right_field = self.ast.nodeData(b).node_and_token;

    const leftMember = self.ast.tokenSlice(left_field);
    const rightMember = self.ast.tokenSlice(right_field);
    if (!mem.eql(u8, leftMember, rightMember)) {
        return false;
    }

    return self.eqlInner(left_obj, right_obj);
}

fn eqlBlock(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    const aStmts = self.ast.extraDataSlice(self.ast.nodeData(a).extra_range, Node.Index);
    const bStmts = self.ast.extraDataSlice(self.ast.nodeData(b).extra_range, Node.Index);
    return self.areAllEql(aStmts, bStmts);
}

fn eqlBlockTwo(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    var buf_a: [2]Node.Index = undefined;
    var buf_b: [2]Node.Index = undefined;
    const aStmts = self.ast.blockStatements(&buf_a, a) orelse return false;
    const bStmts = self.ast.blockStatements(&buf_b, b) orelse return false;
    return self.areAllEql(aStmts, bStmts);
}

fn eqlCall(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    var buf_a: [1]Node.Index = undefined;
    var buf_b: [1]Node.Index = undefined;
    const left = self.ast.fullCall(&buf_a, a) orelse unreachable;
    const right = self.ast.fullCall(&buf_b, b) orelse unreachable;

    return self.eqlInner(left.ast.fn_expr, right.ast.fn_expr) and
        self.areAllEql(left.ast.params, right.ast.params);
}

fn eqlBuiltinCall(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    if (!self.mainTokensEql(a, b)) return false;

    var a_buf: [2]Node.Index = undefined;
    var b_buf: [2]Node.Index = undefined;
    const a_params = self.ast.builtinCallParams(&a_buf, a) orelse unreachable;
    const b_params = self.ast.builtinCallParams(&b_buf, b) orelse unreachable;
    return self.areAllEql(a_params, b_params);
}

fn eqlArrayInit(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    var a_buf: [2]Node.Index = undefined;
    var b_buf: [2]Node.Index = undefined;
    const left = (self.ast.fullArrayInit(&a_buf, a) orelse unreachable).ast;
    const right = (self.ast.fullArrayInit(&b_buf, b) orelse unreachable).ast;

    return self.maybeNodesEql(left.type_expr, right.type_expr) and
        self.areAllEql(left.elements, right.elements);
}

fn eqlSlice(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    const left = (self.ast.fullSlice(a) orelse unreachable).ast;
    const right = (self.ast.fullSlice(b) orelse unreachable).ast;

    return self.eqlInner(left.sliced, right.sliced) and
        self.eqlInner(left.start, right.start) and
        self.maybeNodesEql(left.end, right.end) and
        self.maybeNodesEql(left.sentinel, right.sentinel);
}

fn eqlArrayType(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    const left = (self.ast.fullArrayType(a) orelse unreachable).ast;
    const right = (self.ast.fullArrayType(b) orelse unreachable).ast;

    return self.eqlInner(left.elem_count, right.elem_count) and
        self.maybeNodesEql(left.sentinel, right.sentinel) and
        self.eqlInner(left.elem_type, right.elem_type);
}

fn eqlIfSimple(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    const ifnode = self.ast.ifSimple(a);
    const other = self.ast.ifSimple(b);
    return self.maybePayloadTokensEql(ifnode.payload_token, other.payload_token) and
        self.eqlInner(ifnode.ast.cond_expr, other.ast.cond_expr) and
        self.eqlInner(ifnode.ast.then_expr, other.ast.then_expr) and
        self.maybeNodesEql(ifnode.ast.else_expr, other.ast.else_expr);
}

fn eqlIf(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    const left = self.ast.ifFull(a);
    const right = self.ast.ifFull(b);

    if (!self.maybePayloadTokensEql(left.payload_token, right.payload_token)) return false;
    if (!self.maybeTokensEql(left.error_token, right.error_token)) return false;

    if ((left.else_token == 0) !=
        (right.else_token == 0))
    {
        return false;
    }

    return self.eqlInner(left.ast.cond_expr, right.ast.cond_expr) and
        self.eqlInner(left.ast.then_expr, right.ast.then_expr) and
        self.maybeNodesEql(left.ast.else_expr, right.ast.else_expr);
}

fn eqlVarDecl(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    const left = self.ast.fullVarDecl(a) orelse return false;
    const right = self.ast.fullVarDecl(b) orelse return false;

    if (!self.tokensEql(left.ast.mut_token, right.ast.mut_token)) return false;
    if (!self.tokensEql(left.ast.mut_token + 1, right.ast.mut_token + 1)) return false;

    if (!self.maybeTokensEql(left.visib_token, right.visib_token)) return false;
    if (!self.maybeTokensEql(left.extern_export_token, right.extern_export_token)) return false;
    if (!self.maybeTokensEql(left.lib_name, right.lib_name)) return false;
    if (!self.maybeTokensEql(left.threadlocal_token, right.threadlocal_token)) return false;
    if (!self.maybeTokensEql(left.comptime_token, right.comptime_token)) return false;

    if (!self.maybeNodesEql(left.ast.type_node, right.ast.type_node)) return false;
    if (!self.maybeNodesEql(left.ast.align_node, right.ast.align_node)) return false;
    if (!self.maybeNodesEql(left.ast.section_node, right.ast.section_node)) return false;
    if (!self.maybeNodesEql(left.ast.addrspace_node, right.ast.addrspace_node)) return false;

    if (!self.maybeNodesEql(left.ast.init_node, right.ast.init_node)) return false;

    return true;
}

/// Compare two binary operator nodes by checking lhs and rhs.
fn binExprEql(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    const left_lhs, const left_rhs = self.ast.nodeData(a).node_and_node;
    const right_lhs, const right_rhs = self.ast.nodeData(b).node_and_node;
    return self.eqlInner(left_lhs, right_lhs) and
        self.eqlInner(left_rhs, right_rhs);
}

/// Compare two binary operator nodes where `a` and `b` are reflexive
/// (commutative). Returns true when either ordering matches.
fn binExprEqlReflexive(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    const a_lhs, const a_rhs = self.ast.nodeData(a).node_and_node;
    const b_lhs, const b_rhs = self.ast.nodeData(b).node_and_node;
    if (self.eqlInner(a_lhs, b_lhs)) {
        return self.eqlInner(a_rhs, b_rhs);
    }
    if (self.eqlInner(a_lhs, b_rhs)) {
        return self.eqlInner(a_rhs, b_lhs);
    }
    return false;
}

fn eqlCatch(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    if (!self.maybeTokensEql(self.catchPayloadToken(a), self.catchPayloadToken(b))) return false;
    return self.binExprEql(a, b);
}

fn catchPayloadToken(self: *const AstComparator, node: Node.Index) ?TokenIndex {
    const catch_token = self.ast.nodeMainToken(node);
    return if (self.ast.tokenTag(catch_token + 1) == .pipe)
        catch_token + 2
    else
        null;
}

fn areAllEql(self: *const AstComparator, a: []const Node.Index, b: []const Node.Index) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |i| {
        if (!self.eqlInner(a[i], b[i])) return false;
    }
    return true;
}

/// compares nodes that only have main tokens via string equality on their
/// token's slices
fn mainTokensEql(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    return self.tokensEql(self.ast.nodeMainToken(a), self.ast.nodeMainToken(b));
}

fn maybeTokensEql(self: *const AstComparator, a: ?TokenIndex, b: ?TokenIndex) bool {
    if ((a == null) != (b == null)) return false;
    return if (a) |x| self.tokensEql(x, b.?) else true;
}

fn maybePayloadTokensEql(self: *const AstComparator, a: ?TokenIndex, b: ?TokenIndex) bool {
    if ((a == null) != (b == null)) return false;
    const left = a orelse return true;
    const right = b.?;

    const left_is_pointer = self.ast.tokenTag(left) == .asterisk;
    const right_is_pointer = self.ast.tokenTag(right) == .asterisk;
    if (left_is_pointer != right_is_pointer) return false;

    const left_name = left + @intFromBool(left_is_pointer);
    const right_name = right + @intFromBool(right_is_pointer);
    return self.tokensEql(left_name, right_name);
}

fn maybeNodesEql(self: *const AstComparator, a: Node.OptionalIndex, b: Node.OptionalIndex) bool {
    const ua = a.unwrap();
    const ub = b.unwrap();
    if ((ua == null) != (ub == null)) return false;
    return if (ua) |x| self.eqlInner(x, ub.?) else true;
}

fn tokensEql(self: *const AstComparator, a: Ast.TokenIndex, b: Ast.TokenIndex) bool {
    // TODO: source tokens from TokenList.Slice to avoid re-parsing
    const left = self.ast.tokenSlice(a);
    const right = self.ast.tokenSlice(b);
    return mem.eql(u8, left, right);
}

fn eqlTokenRange(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    const a_start, const a_end = self.ast.nodeData(a).token_and_token;
    const b_start, const b_end = self.ast.nodeData(b).token_and_token;
    return self.tokenRangesEql(a_start, a_end, b_start, b_end);
}

fn tokenRangesEql(
    self: *const AstComparator,
    a_start: TokenIndex,
    a_end: TokenIndex,
    b_start: TokenIndex,
    b_end: TokenIndex,
) bool {
    const a_len = a_end - a_start;
    if (a_len != b_end - b_start) return false;

    for (0..a_len + 1) |offset| {
        if (!self.tokensEql(
            a_start + @as(TokenIndex, @intCast(offset)),
            b_start + @as(TokenIndex, @intCast(offset)),
        )) return false;
    }
    return true;
}

fn eqlErrorValue(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    return self.tokensEql(self.ast.nodeMainToken(a) + 2, self.ast.nodeMainToken(b) + 2);
}

/// Compare two nodes that store a single `.node` data variant.
fn eqlNode(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    return self.eqlInner(self.ast.nodeData(a).node, self.ast.nodeData(b).node);
}

/// Compare two nodes that store an `.opt_node` data variant.
fn eqlOptNode(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    const a_inner = self.ast.nodeData(a).opt_node.unwrap();
    const b_inner = self.ast.nodeData(b).opt_node.unwrap();
    if ((a_inner == null) != (b_inner == null)) return false;
    return if (a_inner) |x| self.eqlInner(x, b_inner.?) else true;
}

/// Compare two nodes that store a `.node_and_token` data variant,
/// comparing only the node part (index 0).
fn eqlNodeAndToken(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    const a_node, _ = self.ast.nodeData(a).node_and_token;
    const b_node, _ = self.ast.nodeData(b).node_and_token;
    return self.eqlInner(a_node, b_node);
}

fn eqlTokenAndNode(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    _, const a_node = self.ast.nodeData(a).token_and_node;
    _, const b_node = self.ast.nodeData(b).token_and_node;
    return self.eqlInner(a_node, b_node);
}

fn eqlNodeAndOptNode(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    const a_node, const a_opt_node = self.ast.nodeData(a).node_and_opt_node;
    const b_node, const b_opt_node = self.ast.nodeData(b).node_and_opt_node;
    return self.eqlInner(a_node, b_node) and self.maybeNodesEql(a_opt_node, b_opt_node);
}

fn eqlOptTokenAndNode(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    const a_token, const a_node = self.ast.nodeData(a).opt_token_and_node;
    const b_token, const b_node = self.ast.nodeData(b).opt_token_and_node;
    return self.maybeTokensEql(a_token.unwrap(), b_token.unwrap()) and
        self.eqlInner(a_node, b_node);
}

fn eqlOptTokenAndOptNode(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    const a_token, const a_node = self.ast.nodeData(a).opt_token_and_opt_node;
    const b_token, const b_node = self.ast.nodeData(b).opt_token_and_opt_node;
    return self.maybeTokensEql(a_token.unwrap(), b_token.unwrap()) and
        self.maybeNodesEql(a_node, b_node);
}

const std = @import("std");
const mem = std.mem;
const Ast = @import("../Semantic.zig").Ast;
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;

fn expectRootInitializersEql(source: [:0]const u8, expected: bool) !void {
    const t = std.testing;

    var ast = try Ast.parse(t.allocator, source, .zig);
    defer ast.deinit(t.allocator);

    if (ast.errors.len != 0) std.debug.print("Failed to parse comparator test source:\n{s}\n", .{source});
    try t.expectEqual(@as(usize, 0), ast.errors.len);
    const declarations = ast.rootDecls();
    try t.expectEqual(@as(usize, 2), declarations.len);

    const left = ast.fullVarDecl(declarations[0]).?.ast.init_node.unwrap().?;
    const right = ast.fullVarDecl(declarations[1]).?.ast.init_node.unwrap().?;
    try t.expectEqual(expected, AstComparator.eql(&ast, left, right));
    try t.expectEqual(expected, AstComparator.eql(&ast, right, left));
    try t.expect(AstComparator.eql(&ast, left, left));
}

fn expectRootDeclarationsEql(source: [:0]const u8, expected: bool) !void {
    const t = std.testing;

    var ast = try Ast.parse(t.allocator, source, .zig);
    defer ast.deinit(t.allocator);

    if (ast.errors.len != 0) std.debug.print("Failed to parse comparator test source:\n{s}\n", .{source});
    try t.expectEqual(@as(usize, 0), ast.errors.len);
    const declarations = ast.rootDecls();
    try t.expectEqual(@as(usize, 2), declarations.len);
    try t.expectEqual(expected, AstComparator.eql(&ast, declarations[0], declarations[1]));
    try t.expectEqual(expected, AstComparator.eql(&ast, declarations[1], declarations[0]));
}

fn expectTaggedNodesEql(source: [:0]const u8, tag: Node.Tag, expected: bool) !void {
    const t = std.testing;

    var ast = try Ast.parse(t.allocator, source, .zig);
    defer ast.deinit(t.allocator);

    try t.expectEqual(@as(usize, 0), ast.errors.len);
    var nodes: [2]Node.Index = undefined;
    var len: usize = 0;
    for (0..ast.nodes.len) |i| {
        const node: Node.Index = @enumFromInt(i);
        if (ast.nodeTag(node) != tag) continue;
        try t.expect(len < nodes.len);
        nodes[len] = node;
        len += 1;
    }
    try t.expectEqual(nodes.len, len);
    try t.expectEqual(expected, AstComparator.eql(&ast, nodes[0], nodes[1]));
    try t.expectEqual(expected, AstComparator.eql(&ast, nodes[1], nodes[0]));
}

test "AstComparator compares token-sensitive nodes" {
    try expectRootInitializersEql(
        \\const left = if (value) |*x| x else outer;
        \\const right = if (value) |*y| x else outer;
    , false);
    try expectRootInitializersEql(
        \\const left = if (value) |x| x else outer;
        \\const right = if (value) |*x| x else outer;
    , false);
    try expectRootDeclarationsEql(
        \\var value = 1;
        \\const value = 1;
    , false);
    try expectRootDeclarationsEql(
        \\extern "left" var value: u8;
        \\extern "right" var value: u8;
    , false);
    const different_declarations = [_][:0]const u8{
        \\pub const value = 1;
        \\const value = 1;
        ,
        \\threadlocal var value: u8 = 1;
        \\var value: u8 = 1;
        ,
        \\export var value: u8;
        \\extern var value: u8;
        ,
        \\const value: u8 = 1;
        \\const value: u16 = 1;
        ,
        \\var value align(4) = 1;
        \\var value align(8) = 1;
        ,
        \\var value linksection("left") = 1;
        \\var value linksection("right") = 1;
        ,
        \\var value addrspace(.generic) = 1;
        \\var value addrspace(.gs) = 1;
        ,
        \\const value = 1;
        \\const value = 2;
        ,
    };
    for (different_declarations) |source| try expectRootDeclarationsEql(source, false);
    try expectRootInitializersEql(
        \\const left = error.Foo;
        \\const right = error.Bar;
    , false);
    try expectRootInitializersEql(
        \\const left = value catch |left_err| fallback;
        \\const right = value catch |right_err| fallback;
    , false);
    try expectRootInitializersEql(
        \\const left = value catch |err| fallback;
        \\const right = value catch |err| fallback;
    , true);
}

test "AstComparator normalizes equivalent AST representations" {
    try expectRootInitializersEql(
        \\const left = function(value);
        \\const right = function(value,);
    , true);
    try expectRootInitializersEql(
        \\const left = @max(first, second);
        \\const right = @max(first, second,);
    , true);
    try expectRootInitializersEql(
        \\const left = [_]u8{ 1, 2 };
        \\const right = [_]u8{ 1, 2, };
    , true);
    try expectRootInitializersEql(
        \\const left = values[1..end];
        \\const right = values[1..end];
    , true);
    try expectRootInitializersEql(
        \\const left = [4:0]u8;
        \\const right = [4:0]u8;
    , true);
}

test "AstComparator compares common expression families" {
    const equal_cases = [_][:0]const u8{
        \\const left = !value;
        \\const right = !value;
        ,
        \\const left = try function();
        \\const right = try function();
        ,
        \\const left = pointer.*;
        \\const right = pointer.*;
        ,
        \\const left = ?u8;
        \\const right = ?u8;
        ,
        \\const left = first < second;
        \\const right = first < second;
        ,
        \\const left = first +% second;
        \\const right = first +% second;
        ,
        \\const left = first and second;
        \\const right = first and second;
        ,
        \\const left = values[index];
        \\const right = values[index];
        ,
        \\const left = Left!Right;
        \\const right = Left!Right;
        ,
        \\const left = error{ Foo, Bar };
        \\const right = error{ Foo, Bar };
        ,
        \\const left =
        \\\\first line
        \\\\second line
        \\;
        \\const right =
        \\\\first line
        \\\\second line
        \\;
        ,
    };
    for (equal_cases) |source| try expectRootInitializersEql(source, true);

    try expectRootInitializersEql(
        \\const left = first < second;
        \\const right = second < first;
    , false);
    try expectRootInitializersEql(
        \\const left = @max(first, second);
        \\const right = @min(first, second);
    , false);
    try expectRootInitializersEql(
        \\const left = values[1..end];
        \\const right = values[2..end];
    , false);
    try expectRootInitializersEql(
        \\const left = [_]u8{ 1, 2 };
        \\const right = [_]u8{ 2, 1 };
    , false);
    try expectRootInitializersEql(
        \\const left = error{ Foo, Bar };
        \\const right = error{ Foo, Baz };
    , false);
    try expectRootInitializersEql(
        \\const left =
        \\\\same
        \\\\left
        \\;
        \\const right =
        \\\\same
        \\\\right
        \\;
    , false);
    try expectRootInitializersEql(
        \\const left = .{ .field = value };
        \\const right = .{ .field = value };
    , false);
}

test "AstComparator compares optional token and node data" {
    try expectTaggedNodesEql(
        \\fn left() void { errdefer |err| consume(err); }
        \\fn right() void { errdefer |err| consume(err); }
    , .@"errdefer", true);
    try expectTaggedNodesEql(
        \\fn left() void { label: while (true) break :label; }
        \\fn right() void { other: while (true) break :other; }
    , .@"break", false);
    try expectTaggedNodesEql(
        \\fn left() void { label: while (true) continue :label; }
        \\fn right() void { label: while (true) continue :label; }
    , .@"continue", true);
    try expectTaggedNodesEql(
        \\fn left() void { for (0..10) |_| {} }
        \\fn right() void { for (0..10) |_| {} }
    , .for_range, true);
}
