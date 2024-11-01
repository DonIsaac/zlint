const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Type = std.builtin.Type;

const string = @import("../str.zig").string;
const assert = std.debug.assert;

pub const Scope = struct {
    /// Unique identifier for this scope.
    id: Id,
    /// Scope hints.
    flags: Flags,
    parent: ?Id,

    /// Uniquely identifies a scope within a source file.
    pub const Id = u32;
    pub const MAX_ID = std.math.maxInt(Id);

    /// Scope flags provide hints about what kind of node is creating the
    /// scope.
    ///
    /// TODO: Should this be an enum?
    pub const Flags = packed struct {
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
    };
};

/// Stores variable scopes created by a zig program.
pub const ScopeTree = struct {
    /// Indexed by scope id.
    scopes: ScopeList = .{},
    /// Mappings from scopes to their descendants.
    children: std.ArrayListUnmanaged(ScopeIdList) = .{},

    const ScopeList = std.ArrayListUnmanaged(Scope);
    const ScopeIdList = std.ArrayListUnmanaged(Scope.Id);

    /// Create a new scope and insert it into the scope tree.
    ///
    /// ## Errors
    /// If allocation fails. Usually due to OOM.
    pub fn addScope(self: *ScopeTree, alloc: Allocator, parent: ?Scope.Id, flags: Scope.Flags) !*Scope {
        assert(self.scopes.items.len < Scope.MAX_ID);
        const id: Scope.Id = @intCast(self.scopes.items.len);

        // initialize the new scope
        const scope = try self.scopes.addOne(alloc);
        scope.* = Scope{ .id = id, .parent = parent, .flags = flags };

        // set up it's child list
        try self.children.append(alloc, .{});

        // Add it to its parent's list of child scopes
        if (parent != null) {
            assert(parent.? < self.children.items.len);
            var parentChildren: ScopeIdList = self.children.items[parent.?];
            try parentChildren.append(alloc, id);
        }

        // sanity check
        assert(self.scopes.items.len == self.children.items.len);

        return scope;
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
