const Scope = @This();

/// Unique identifier for this scope.
id: Id,
/// Scope hints.
flags: Flags,
parent: Id.Optional,
node: NodeIndex,

/// Uniquely identifies a scope within a source file.
pub const Id = NominalId(u32);
pub const MAX_ID = Id.MAX;

const FLAGS_REPR = u16;
/// Scope flags provide hints about what kind of node is creating the
/// scope.
///
/// TODO: Should this be an enum?
pub const Flags = packed struct(FLAGS_REPR) {
    /// Top-level "module" scope
    s_top: bool = false,
    /// Created by a function declaration.
    s_function: bool = false,
    /// Created by a struct declaration.
    s_struct: bool = false,
    /// Created by an enum declaration.
    s_enum: bool = false,
    /// Created by an enum declaration.
    s_union: bool = false,
    /// Created by an error declaration.
    s_error: bool = false,
    /// Created by a block statement, loop, if statement, etc.
    s_block: bool = false,
    s_comptime: bool = false,
    s_catch: bool = false,
    /// Created by a `test` block.
    s_test: bool = false,
    // Padding
    _: u6 = 0,

    pub const s_container = Flags{ .s_struct = true, .s_enum = true, .s_union = true, .s_error = true };

    pub usingnamespace util.Bitflags(Flags);

    /// Returns `true` if this scope can have fields (e.g. a struct).
    pub inline fn isContainer(self: Flags) bool {
        return self.s_struct or self.s_enum or self.s_union or self.s_error;
    }
};

/// Stores variable scopes created by a zig program.
pub const Tree = struct {
    /// Indexed by scope id.
    scopes: std.MultiArrayList(Scope) = .{},
    /// Mappings from scopes to their descendants.
    children: std.ArrayListUnmanaged(ScopeIdList) = .{},

    bindings: std.ArrayListUnmanaged(SymbolIdList) = .{},

    const ScopeIdList = std.ArrayListUnmanaged(Scope.Id);
    const SymbolIdList = std.ArrayListUnmanaged(Symbol.Id);

    /// Returns the number of declared scopes in a program.
    ///
    /// Shorthand for `scope_tree.scopes.len`.
    pub inline fn len(self: *const Scope.Tree) u32 {
        @setRuntimeSafety(!util.IS_DEBUG);
        assert(self.scopes.len < Id.MAX);

        return @intCast(self.scopes.len);
    }

    /// Get all properties of a scope by ID.
    ///
    /// Avoid this when possible. Prefer using property slices for better cache
    /// locality.
    pub fn getScope(self: *const Scope.Tree, id: Scope.Id) Scope {
        return self.scopes.get(id.into(usize));
    }

    /// Create a new scope and insert it into the scope tree.
    ///
    /// ## Errors
    /// If allocation fails. Usually due to OOM.
    pub fn addScope(
        self: *Scope.Tree,
        alloc: Allocator,
        parent: ?Scope.Id,
        node: NodeIndex,
        flags: Scope.Flags,
    ) !Scope.Id {
        assert(self.scopes.len < Scope.MAX_ID);
        const id: Scope.Id = Id.from(self.scopes.len);

        // initialize the new scope
        try self.scopes.append(alloc, Scope{
            .id = id,
            .node = node,
            .parent = Id.Optional.from(parent),
            .flags = flags,
        });

        // set up it's child list
        try self.children.append(alloc, .{});
        try self.bindings.append(alloc, .{});

        // Add it to its parent's list of child scopes
        if (parent != null) {
            const p = parent.?.int();
            assert(p < self.children.items.len);
            var parentChildren: *ScopeIdList = &self.children.items[p];
            try parentChildren.append(alloc, id);
        }

        // sanity check
        assert(self.scopes.len == self.children.items.len);

        return id;
    }

    pub fn addBinding(self: *Scope.Tree, alloc: Allocator, scope_id: Scope.Id, symbol_id: Symbol.Id) Allocator.Error!void {
        return self.bindings.items[scope_id.int()].append(alloc, symbol_id);
    }

    pub fn getBindings(self: *const Scope.Tree, scope_id: Scope.Id) []const Symbol.Id {
        return self.bindings.items[scope_id.int()].items;
    }

    /// Iterate over parent scopes, starting at `scope_id`. `scope_id` is the first
    /// item yielded.
    pub fn iterParents(self: *const Scope.Tree, scope_id: Scope.Id) ScopeParentIterator {
        return .{
            .curr = scope_id.into(Id.Optional),
            .parents = self.scopes.items(.parent),
        };
    }

    /// Returns `true` if `parent_id` contains `child_id` as a descendant.
    pub fn isParentOf(self: *const Scope.Tree, parent_id: Scope.Id, child_id: Scope.Id) bool {
        var it = self.iterParents(child_id);
        while (it.next()) |scope| {
            if (scope == parent_id) return true;
        }
        return false;
    }

    pub fn deinit(self: *Scope.Tree, alloc: Allocator) void {
        self.scopes.deinit(alloc);

        for (0..self.children.items.len) |i| {
            var children = self.children.items[i];
            children.deinit(alloc);
        }
        self.children.deinit(alloc);

        for (0..self.bindings.items.len) |i| {
            self.bindings.items[i].deinit(alloc);
        }
        self.bindings.deinit(alloc);
    }
};

const ScopeParentIterator = struct {
    curr: Scope.Id.Optional,
    // tree: *const Scope.Tree,
    parents: []const Id.Optional,

    pub fn next(self: *ScopeParentIterator) ?Scope.Id {
        // const parents = self.tree.scopes.items(.parent);
        const curr = self.curr.unwrap();
        if (curr) |c| {
            self.curr = self.parents[c.int()];
        }
        return curr;
    }
};

const std = @import("std");
const util = @import("util");
const _ast = @import("ast.zig");

const Allocator = std.mem.Allocator;
const NodeIndex = _ast.NodeIndex;
const Symbol = @import("Symbol.zig");
const NominalId = util.NominalId;

const assert = std.debug.assert;

const t = std.testing;

test Flags {
    const block = Flags{ .s_block = true };
    const top = Flags{ .s_top = true };
    const empty = Flags{};
    try t.expectEqual(Flags{ .s_block = true, .s_top = true }, block.merge(top));

    try t.expectEqual(block, block.merge(empty));
    try t.expectEqual(block, block.merge(block));
    try t.expectEqual(block, block.merge(.{ .s_block = false }));
}

test "Scope.Tree.addScope" {
    const alloc = t.allocator;
    const expectEqual = t.expectEqual;

    var tree = Scope.Tree{};
    defer tree.deinit(alloc);

    const root_id = try tree.addScope(alloc, null, 0, .{ .s_top = true });
    const root = tree.getScope(root_id);
    try expectEqual(1, tree.scopes.len);
    try expectEqual(0, root_id.int());
    try expectEqual(0, root.id.int());
    try expectEqual(Scope.Flags{ .s_top = true }, root.flags);
    try expectEqual(root, tree.scopes.get(0));

    const child_id = try tree.addScope(alloc, root.id, 0, .{});
    const child = tree.getScope(child_id);
    try expectEqual(1, child.id.int());
    try expectEqual(Scope.Flags{}, child.flags);
    try expectEqual(root.id, child.parent.unwrap().?);
    try expectEqual(child, tree.scopes.get(1));

    try expectEqual(2, tree.scopes.len);
    try expectEqual(2, tree.children.items.len);
    try expectEqual(1, tree.children.items[0].items.len);
    try expectEqual(1, tree.children.items[0].items[0].int());
}

test "Flags.merge" {
    const expected = Flags{ .s_block = true, .s_enum = true };
    const a = Flags{ .s_block = true };

    var result = a.merge(.{ .s_enum = true });
    try t.expect(expected.eql(result));

    result = a.merge(.{ .s_enum = true, .s_comptime = true });
    try t.expect(!expected.eql(result));
}
