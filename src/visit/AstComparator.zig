//! Compares two AST subtrees for equality.
const AstComparator = @This();

ast: *const Ast,

pub fn eql(ast: *const Ast, a: Node.Index, b: Node.Index) bool {
    if (a == b) {
        @branchHint(.unlikely);
        return true;
    }
    const tag: Node.Tag = ast.nodes.items(.tag)[a];
    const other: Node.Tag = ast.nodes.items(.tag)[b];
    if (tag != other) return false;
    const comparator = AstComparator{ .ast = ast };
    return comparator.eqlInner(a, b);
}

fn eqlInner(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    const tags = self.nodeTags();
    const x = tags[a];
    const y = tags[b];
    if (x != y) return false;

    return switch (@as(Node.Tag, x)) {
        .if_simple => eqlIfSimple(self, a, b),
        .call_one, .call_one_comma, .call_comma, .call => eqlCall(self, a, b),
        .sub, .div, .mod, .block_two, .block_two_semicolon => binExprEql(self, a, b),
        .add, .mul, .bit_and, .bit_or => binExprEqlReflexive(self, a, b),
        .block, .block_semicolon => eqlBlock(self, a, b),
        .negation, .negation_wrap, .bit_not, .address_of => innerEql(self, a, b, .lhs),
        .number_literal,
        .string_literal,
        .enum_literal,
        .char_literal,
        .identifier,
        => mainTokensEql(self, a, b),
        .unreachable_literal,
        .root, // null node
        => true,
        else => false,
    };
}

fn eqlBlock(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    const data = self.nodeData();
    const aStmts = self.ast.extra_data[data[a].lhs..data[a].rhs];
    const bStmts = self.ast.extra_data[data[b].lhs..data[b].rhs];
    return self.areAllEql(aStmts, bStmts);
}

fn eqlCall(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    var buf: [1]Node.Index = undefined;
    const left = self.ast.fullCall(&buf, a) orelse unreachable;
    const right = self.ast.fullCall(&buf, b) orelse unreachable;

    return self.eqlInner(left.ast.fn_expr, right.ast.fn_expr) and
        self.areAllEql(left.ast.params, right.ast.params);
    // self.eqlInner(left.ast.params, right.ast.params);
}

fn eqlIfSimple(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    const ifnode = self.ast.ifSimple(a);
    const other = self.ast.ifSimple(b);
    return self.eqlInner(ifnode.ast.cond_expr, other.ast.cond_expr) and
        self.eqlInner(ifnode.ast.then_expr, other.ast.then_expr) and
        self.eqlInner(ifnode.ast.else_expr, other.ast.else_expr);
}

/// Compare two nodes by checking that their left/right subtrees are equal.
///
/// `a.lhs == b.lhs and a.rhs == b.rhs`
fn binExprEql(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    const datas = self.nodeData();
    return self.eqlInner(datas[a].lhs, datas[b].lhs) and
        self.eqlInner(datas[a].rhs, datas[b].rhs);
}

/// Compare two nodes with left/right subtrees, where `a` and `b` are reflexive.
///
/// This fn returns true when
/// - `a.left == b.left` and `a.right == b.right`
/// - `a.left == b.right` and `a.right == b.left`
fn binExprEqlReflexive(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    const datas = self.nodeData();
    if (self.eqlInner(datas[a].lhs, datas[b].lhs)) {
        return self.eqlInner(datas[a].rhs, datas[b].rhs);
    }
    if (self.eqlInner(datas[a].lhs, datas[b].rhs)) {
        return self.eqlInner(datas[a].rhs, datas[b].lhs);
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
    const toks = self.mainTokens();
    const left = self.ast.tokenSlice(toks[a]);
    const right = self.ast.tokenSlice(toks[b]);
    return mem.eql(u8, left, right);
}

fn innerEql(self: *const AstComparator, a: Node.Index, b: Node.Index, comptime loc: enum { lhs, rhs }) bool {
    const datas = self.nodeData();
    return switch (loc) {
        .lhs => self.eqlInner(datas[a].lhs, datas[b].lhs),
        .rhs => self.eqlInner(datas[a].rhs, datas[b].rhs),
    };
}

inline fn nodeTags(self: *const AstComparator) []const Node.Tag {
    return self.ast.nodes.items(.tag);
}
inline fn nodeData(self: *const AstComparator) []const Node.Data {
    return self.ast.nodes.items(.data);
}
inline fn mainTokens(self: *const AstComparator) []const Ast.TokenIndex {
    return self.ast.nodes.items(.main_token);
}

const std = @import("std");
const mem = std.mem;
const Ast = @import("../Semantic.zig").Ast;
const Node = Ast.Node;
const NodeList = Ast.NodeList;
