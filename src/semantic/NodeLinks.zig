//! Links AST nodes to other semantic data

/// Map of AST nodes to their parents. Index is the child node id.
///
/// Confusingly, the root node id is also used as the "null" node id, so the
/// root node technically uses itself as its parent (`parents[0] == 0`). Prefer
/// `getParent` if you need to disambiguate between the root node and the null
/// node.
///
/// Do not insert into this list directly; use `setParent` instead. This method
/// upholds link invariants.
///
/// ### Invariants:
/// - No node is its own parent
/// - No node is the parent of the root node (0 in this case means `null`).
parents: std.ArrayListUnmanaged(NodeIndex) = .{},
/// Map AST nodes to the scope they are in. Index is the node id.
///
/// This is _not_ a mapping for scopes that nodes create.
scopes: std.ArrayListUnmanaged(Scope.Id) = .{},
/// Maps tokens (usually `.identifier`s) to the references they create. Since
/// references are sparse in an AST, a hashmap is used to avoid wasting memory.
references: std.AutoHashMapUnmanaged(Ast.TokenIndex, Reference.Id) = .{},

pub fn init(alloc: Allocator, ast: *const Ast) Allocator.Error!NodeLinks {
    var links: NodeLinks = .{};

    try links.parents.ensureTotalCapacityPrecise(alloc, ast.nodes.len);
    links.parents.appendNTimesAssumeCapacity(NULL_NODE, @intCast(ast.nodes.len));
    try links.scopes.ensureTotalCapacityPrecise(alloc, ast.nodes.len);
    links.scopes.appendNTimesAssumeCapacity(ROOT_SCOPE_ID, ast.nodes.len);

    try links.references.ensureTotalCapacity(alloc, 16);

    return links;
}

pub fn deinit(self: *NodeLinks, alloc: Allocator) void {
    inline for (.{ "parents", "scopes", "references" }) |name| {
        @field(self, name).deinit(alloc);
    }
}

pub inline fn setScope(self: *NodeLinks, node_id: NodeIndex, scope_id: Scope.Id) void {
    assert(
        node_id < self.scopes.items.len,
        "Node id out of bounds (id {d} >= {d})",
        .{ node_id, self.scopes.items.len },
    );

    self.scopes.items[node_id] = scope_id;
}

pub inline fn setParent(self: *NodeLinks, child_id: NodeIndex, parent_id: NodeIndex) void {
    assert(child_id != parent_id, "AST nodes cannot be children of themselves", .{});
    assert(child_id != NULL_NODE, "Re-assigning the root node's parent is illegal behavior", .{});
    assert(
        parent_id < self.parents.items.len,
        "Parent node id out of bounds (id {d} >= {d})",
        .{ parent_id, self.parents.items.len },
    );

    self.parents.items[child_id] = parent_id;
}

pub inline fn getParent(self: *const NodeLinks, node_id: NodeIndex) ?NodeIndex {
    if (node_id == ROOT_NODE_ID) {
        return null;
    }
    return self.parents.items[node_id];
}

/// Iterate over a node's parents. The first element is the node itself, and
/// the last will be the root node.
pub fn iterParentIds(self: *const NodeLinks, node_id: NodeIndex) ParentIdsIterator {
    return ParentIdsIterator{ .links = self, .curr_id = node_id };
}

const ParentIdsIterator = struct {
    links: *const NodeLinks,
    curr_id: ?NodeIndex,

    pub fn next(self: *ParentIdsIterator) ?NodeIndex {
        const curr_id = self.curr_id orelse return null;
        // NOTE: using getParent instead of direct _parents access to ensure
        // root node is yielded.
        defer self.curr_id = self.links.getParent(curr_id);
        return self.curr_id;
    }
};

const NodeLinks = @This();

const std = @import("std");
const _ast = @import("ast.zig");
const util = @import("util");

const Ast = _ast.Ast;
const NodeIndex = _ast.NodeIndex;
const Semantic = @import("./Semantic.zig");
const ROOT_NODE_ID = Semantic.ROOT_NODE_ID;
const NULL_NODE = Semantic.NULL_NODE;
const ROOT_SCOPE_ID = Semantic.ROOT_SCOPE_ID;
const Scope = Semantic.Scope;
const Reference = Semantic.Reference;

const Allocator = std.mem.Allocator;
const assert = util.assert;
