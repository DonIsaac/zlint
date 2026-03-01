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
    if (tag != other) return false;
    const comparator = AstComparator{ .ast = ast };
    return comparator.eqlInner(a, b);
}

fn eqlInner(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    const x = self.ast.nodeTag(a);
    const y = self.ast.nodeTag(b);
    if (x != y) return false;

    return switch (@as(Node.Tag, x)) {
        .if_simple => self.eqlIfSimple(a, b),
        .@"if" => self.eqlIf(a, b),
        .call_one, .call_one_comma, .call_comma, .call => self.eqlCall(a, b),
        .field_access => self.eqlFieldAccess(a, b),
        .block, .block_semicolon => self.eqlBlock(a, b),
        .block_two, .block_two_semicolon => self.eqlBlockTwo(a, b),
        .negation,
        .negation_wrap,
        .bit_not,
        .address_of,
        => self.eqlNode(a, b),
        .@"return" => self.eqlOptNode(a, b),
        .unwrap_optional => self.eqlNodeAndToken(a, b),
        .@"defer" => self.eqlNode(a, b),
        .sub,
        .div,
        .mod,
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
        .local_var_decl, .aligned_var_decl, .simple_var_decl => self.eqlVarDecl(a, b),
        .unreachable_literal,
        .root, // null node
        => true,
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

fn eqlIfSimple(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    const ifnode = self.ast.ifSimple(a);
    const other = self.ast.ifSimple(b);
    return self.eqlInner(ifnode.ast.cond_expr, other.ast.cond_expr) and
        self.eqlInner(ifnode.ast.then_expr, other.ast.then_expr) and
        self.maybeNodesEql(ifnode.ast.else_expr, other.ast.else_expr);
}

fn eqlIf(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    const ifTokFields = [_][]const u8{ "payload_token", "error_token" };
    const left = self.ast.ifFull(a);
    const right = self.ast.ifFull(b);

    inline for (ifTokFields) |fieldname| {
        if (!self.maybeTokensEql(@field(left, fieldname), @field(right, fieldname))) {
            return false;
        }
    }

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

    const left_main_token = self.ast.nodeMainToken(a);
    const right_main_token = self.ast.nodeMainToken(b);
    if (!self.tokensEql(left_main_token + 1, right_main_token + 1)) return false;

    if (!self.maybeTokensEql(left.visib_token, right.visib_token)) return false;
    if (!self.maybeTokensEql(left.comptime_token, right.comptime_token)) return false;
    if (!self.maybeTokensEql(left.extern_export_token, right.extern_export_token)) return false;

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

const std = @import("std");
const mem = std.mem;
const Ast = @import("../Semantic.zig").Ast;
const Node = Ast.Node;
const NodeList = Ast.NodeList;
const TokenIndex = Ast.TokenIndex;
