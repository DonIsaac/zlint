_parents: std.ArrayListUnmanaged(NodeIndex) = .{},

pub fn init(alloc: Allocator, ast: *const Ast) !NodeLinks {
    var links: NodeLinks = .{};
    try links._parents.ensureTotalCapacityPrecise(alloc, ast.nodes.len);
    links._parents.appendNTimesAssumeCapacity(NULL_NODE, @intCast(ast.nodes.len));

    return links;
}

pub fn deinit(self: *NodeLinks, alloc: Allocator) void {
    self._parents.deinit(alloc);
}

pub inline fn setParent(self: *NodeLinks, child_id: NodeIndex, parent_id: NodeIndex) void {
    assert(child_id != parent_id, "AST nodes cannot be children of themselves", .{});
    assert(child_id != NULL_NODE, "Re-assigning the root node's parent is illegal behavior", .{});
    self._parents.items[child_id] = parent_id;
}

pub inline fn getParent(self: *NodeLinks, node_id: NodeIndex) ?NodeIndex {
    if (node_id == ROOT_NODE_ID) {
        return NULL_NODE;
    }
    return self._parents[node_id];
}

/// Iterate over a node's parents. The first element is the node itself, and
/// the last will be the root node.
pub fn iterParentIds(self: *NodeLinks, node_id: NodeIndex) ParentIdsIterator {
    return ParentIdsIterator{
        .links = self,
        .curr_id = node_id,
    };
}

const ParentIdsIterator = struct {
    links: *NodeLinks,
    curr_id: ?NodeIndex,

    pub fn next(self: *ParentIdsIterator) ?NodeIndex {
        // NOTE: using getParent instead of direct _parents access to ensure
        // root node is yielded.
        defer self.curr_id = self.links.getParent(self.curr_id);
        return self.curr_id;
    }
};
const NodeLinks = @This();

const Ast = std.zig.Ast;
const NodeIndex = Ast.Node.Index;
const ROOT_NODE_ID = @import("./Semantic.zig").ROOT_NODE_ID;
const NULL_NODE = @import("./Semantic.zig").NULL_NODE;

const std = @import("std");
const Allocator = std.mem.Allocator;
const util = @import("util");
const assert = util.assert;
