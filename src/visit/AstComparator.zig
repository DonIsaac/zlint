//! Compares two AST subtrees for equality.
const AstComparator = @This();

// todo: store token list to avoid re-parsing when comparing toks.
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
        .if_simple => self.eqlIfSimple(a, b),
        .@"if" => self.eqlIf(a, b),
        .call_one, .call_one_comma, .call_comma, .call => self.eqlCall(a, b),
        .field_access => self.eqlFieldAccess(a, b),
        .block, .block_semicolon => self.eqlBlock(a, b),
        .negation,
        .negation_wrap,
        .bit_not,
        .address_of,
        .@"return",
        .unwrap_optional,
        => self.innerEql(a, b, .lhs),
        .@"defer" => self.innerEql(a, b, .rhs),
        .sub,
        .div,
        .mod,
        .block_two,
        .block_two_semicolon,
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
    const data = self.nodeData();
    const left = data[a];
    const right = data[b];

    const leftMember = self.ast.tokenSlice(left.rhs);
    const rightMember = self.ast.tokenSlice(right.rhs);
    if (!mem.eql(u8, leftMember, rightMember)) {
        return false;
    }

    return self.eqlInner(left.lhs, right.lhs);
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
}

fn eqlIfSimple(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    const ifnode = self.ast.ifSimple(a);
    const other = self.ast.ifSimple(b);
    return self.eqlInner(ifnode.ast.cond_expr, other.ast.cond_expr) and
        self.eqlInner(ifnode.ast.then_expr, other.ast.then_expr) and
        self.eqlInner(ifnode.ast.else_expr, other.ast.else_expr);
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
        self.eqlInner(left.ast.else_expr, right.ast.else_expr);
}

fn eqlVarDecl(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    const left = self.ast.fullVarDecl(a) orelse return false;
    const right = self.ast.fullVarDecl(b) orelse return false;

    // Compare identifier names
    const left_main_token = self.ast.nodes.items(.main_token)[a];
    const right_main_token = self.ast.nodes.items(.main_token)[b];
    if (!self.tokensEql(left_main_token + 1, right_main_token + 1)) return false;

    // Compare optional tokens
    if (!self.maybeTokensEql(left.visib_token, right.visib_token)) return false;
    if (!self.maybeTokensEql(left.comptime_token, right.comptime_token)) return false;
    if (!self.maybeTokensEql(left.extern_export_token, right.extern_export_token)) return false;

    // Compare AST components
    if (!self.maybeNodesEql(left.ast.type_node, right.ast.type_node)) return false;
    if (!self.maybeNodesEql(left.ast.align_node, right.ast.align_node)) return false;
    if (!self.maybeNodesEql(left.ast.section_node, right.ast.section_node)) return false;
    if (!self.maybeNodesEql(left.ast.addrspace_node, right.ast.addrspace_node)) return false;

    // Compare init node
    if (!self.maybeNodesEql(left.ast.init_node, right.ast.init_node)) return false;

    return true;
}

/// Compare two nodes by checking that their left/right subtrees are equal.
///
/// `a.lhs == b.lhs and a.rhs == b.rhs`
fn binExprEql(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    const datas = self.nodeData();
    const left = datas[a];
    const right = datas[b];
    return self.eqlInner(left.lhs, right.lhs) and
        self.eqlInner(left.rhs, right.rhs);
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

/// compares nodes that only have main tokens via string equality on their[g]
/// token's slices
fn mainTokensEql(self: *const AstComparator, a: Node.Index, b: Node.Index) bool {
    const toks = self.mainTokens();
    return self.tokensEql(toks[a], toks[b]);
}

fn maybeTokensEql(self: *const AstComparator, a: ?TokenIndex, b: ?TokenIndex) bool {
    // one is null but the other isn't
    if ((a == null) != (b == null)) return false;
    return if (a) |x| self.tokensEql(x, b.?) else true;
}

fn maybeNodesEql(self: *const AstComparator, a: ?Node.Index, b: ?Node.Index) bool {
    // one is null but the other isn't
    if ((a == null) != (b == null)) return false;
    return if (a) |x| self.eqlInner(x, b.?) else true;
}

fn tokensEql(self: *const AstComparator, a: Ast.TokenIndex, b: Ast.TokenIndex) bool {
    // TODO: source tokens from TokenList.Slice to avoid re-parsing
    const left = self.ast.tokenSlice(a);
    const right = self.ast.tokenSlice(b);
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
const TokenIndex = Ast.TokenIndex;
