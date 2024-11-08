/// Unique identifier for this scope.
id: Id,
/// Scope hints.
flags: Flags,
parent: ?Id,

/// Uniquely identifies a scope within a source file.
pub const Id = u32;
pub const MAX_ID = std.math.maxInt(Id);

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
    /// Created by a block statement, loop, if statement, etc.
    s_block: bool = false,
    s_comptime: bool = false,
    // Padding
    _: u9 = 0,

    /// Merge all `true`-valued flags in `self` and `other`. Neither argument is
    /// mutated.
    ///
    /// ## Example
    /// ```zig
    /// const Scope = @import("zlint").semantic.Scope;
    /// const block = Scope.Flags{ .s_block = true };
    /// const top = Scope.Flags { .s_top = true };
    /// const empty = Scope.Flags{};
    /// try std.testing.expectEqual(ScopeFlags{ .s_top = true, .s_block = true }, block.merge(top));
    /// try std.testing.expectEqual(block, block.merge(empty));
    /// try std.testing.expectEqual(block, block.merge(block));
    /// ```
    pub inline fn merge(self: Flags, other: Flags) Flags {
        const a: FLAGS_REPR = @bitCast(self);
        const b: FLAGS_REPR = @bitCast(other);
        return @bitCast(a | b);
    }
};

/// Stores variable scopes created by a zig program.
pub const ScopeTree = struct {
    /// Indexed by scope id.
    scopes: std.MultiArrayList(Scope) = .{},
    /// Mappings from scopes to their descendants.
    children: std.ArrayListUnmanaged(ScopeIdList) = .{},

    const ScopeIdList = std.ArrayListUnmanaged(Scope.Id);

    /// Create a new scope and insert it into the scope tree.
    ///
    /// ## Errors
    /// If allocation fails. Usually due to OOM.
    pub fn addScope(self: *ScopeTree, alloc: Allocator, parent: ?Scope.Id, flags: Scope.Flags) !Scope.Id {
        assert(self.scopes.len < Scope.MAX_ID);
        const id: Scope.Id = @intCast(self.scopes.len);

        // initialize the new scope
        try self.scopes.append(alloc, Scope{ .id = id, .parent = parent, .flags = flags });

        // set up it's child list
        try self.children.append(alloc, .{});

        // Add it to its parent's list of child scopes
        if (parent != null) {
            assert(parent.? < self.children.items.len);
            var parentChildren: *ScopeIdList = &self.children.items[parent.?];
            try parentChildren.append(alloc, id);
        }

        // sanity check
        assert(self.scopes.len == self.children.items.len);

        return id;
    }

    pub fn deinit(self: *ScopeTree, alloc: Allocator) void {
        self.scopes.deinit(alloc);

        {
            var i: usize = 0;
            const len = self.children.items.len;
            while (i < len) {
                var children = self.children.items[i];
                children.deinit(alloc);
                i += 1;
            }
            self.children.deinit(alloc);
        }
    }
};

const Scope = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Type = std.builtin.Type;

const string = @import("util").string;
const assert = std.debug.assert;

test Flags {
    const block = Flags{ .s_block = true };
    const top = Flags{ .s_top = true };
    const empty = Flags{};
    try std.testing.expectEqual(Flags{ .s_block = true, .s_top = true }, block.merge(top));

    try std.testing.expectEqual(block, block.merge(empty));
    try std.testing.expectEqual(block, block.merge(block));
    try std.testing.expectEqual(block, block.merge(.{ .s_block = false }));
}

test "ScopeTree.addScope" {
    const alloc = std.testing.allocator;
    const expectEqual = std.testing.expectEqual;

    var tree = ScopeTree{};
    defer tree.deinit(alloc);

    const root_id = try tree.addScope(alloc, null, .{ .s_top = true });
    const root = tree.scopes.get(root_id);
    try expectEqual(1, tree.scopes.len);
    try expectEqual(0, root_id);
    try expectEqual(0, root.id);
    try expectEqual(Scope.Flags{ .s_top = true }, root.flags);
    try expectEqual(root, tree.scopes.get(0));

    const child_id = try tree.addScope(alloc, root.id, .{});
    const child = tree.scopes.get(child_id);
    try expectEqual(1, child.id);
    try expectEqual(Scope.Flags{}, child.flags);
    try expectEqual(root.id, child.parent);
    try expectEqual(child, tree.scopes.get(1));

    try expectEqual(2, tree.scopes.len);
    try expectEqual(2, tree.children.items.len);
    try expectEqual(1, tree.children.items[0].items.len);
    try expectEqual(1, tree.children.items[0].items[0]);
}