_parents: std.ArrayListUnmanaged(NodeIndex) = .{},

pub fn init(alloc: Allocator, ast: *const Ast) !AstMeta {
    var meta: AstMeta = .{};
    try meta._parents.ensureTotalCapacityPrecise(alloc, ast.nodes.len);
    meta._parents.appendNTimesAssumeCapacity(NULL_NODE, @intCast(ast.nodes.len));

    return meta;
}

pub fn deinit(self: *AstMeta, alloc: Allocator) void {
    self._parents.deinit(alloc);
}

pub inline fn setParent(self: *AstMeta, child_id: NodeIndex, parent_id: NodeIndex) void {
    assert(child_id != parent_id, "AST nodes cannot be children of themselves", .{});
    assert(child_id != NULL_NODE, "Re-assigning the root node's parent is illegal behavior", .{});
    self._parents.items[child_id] = parent_id;
}

pub inline fn getParent(self: *AstMeta, node_id: NodeIndex) ?NodeIndex {
    if (node_id == ROOT_NODE_ID) {
        return NULL_NODE;
    }
    return self._parents[node_id];
}

/// Iterate over a node's parents. The first element is the node itself, and
/// the last will be the root node.
pub fn iterParentIds(self: *AstMeta, node_id: NodeIndex) ParentIdsIterator {
    return ParentIdsIterator{
        .meta = self,
        .curr_id = node_id,
    };
}

const ParentIdsIterator = struct {
    meta: *AstMeta,
    curr_id: ?NodeIndex,

    pub fn next(self: *ParentIdsIterator) ?NodeIndex {
        // NOTE: using getParent instead of direct _parents access to ensure
        // root node is yielded.
        defer self.curr_id = self.meta.getParent(self.curr_id);
        return self.curr_id;
    }
};
const AstMeta = @This();

const Ast = std.zig.Ast;
const NodeIndex = Ast.Node.Index;
const ROOT_NODE_ID = @import("./Semantic.zig").ROOT_NODE_ID;
const NULL_NODE = @import("./Semantic.zig").NULL_NODE;

const std = @import("std");
const Allocator = std.mem.Allocator;
const util = @import("util");
const assert = util.assert;
