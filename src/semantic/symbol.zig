const std = @import("std");

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Scope = @import("scope.zig").Scope;
const Type = std.builtin.Type;

const assert = std.debug.assert;
const string = @import("../str.zig").string;

/// A declared variable/function/whatever.
///
/// Type: `pub struct Symbol<'a>`
pub const Symbol = struct {
    /// Identifier name.
    ///
    /// Symbols only borrow their names. These string slices reference data in
    /// source text, which owns the allocation.
    ///
    /// `&'a str`
    name: string,
    /// This symbol's type. Only present if statically determinable, since
    /// analysis doesn't currently do type checking.
    // ty: ?Type,
    /// Unique identifier for this symbol.
    id: Id,
    /// Scope this symbol is declared in.
    scope: Scope.Id,
    /// Index of the AST node declaring this symbol.
    ///
    /// Usually a `var`/`const` declaration, function statement, etc.
    decl: Ast.Node.Index,
    visibility: Visibility,
    flags: Flags,

    /// Uniquely identifies a symbol across a source file.
    pub const Id = u32;
    pub const MAX_ID = std.math.maxInt(Id);

    /// Visibility to external code.
    ///
    /// Does not encode convention-based visibility. This reflects the `pub` Zig
    /// keyword.
    ///
    /// TODO: handle exports?
    pub const Visibility = enum {
        public,
        private,
    };
    pub const Flags = packed struct {
        /// Comptime symbol.
        ///
        /// Not `true` for inferred comptime parameters. That is, this is only
        /// `true` when the `comptime` modifier is present.
        s_comptime: bool = false,
        /// TODO: not recorded yet
        s_const: bool = false,
        /// Indicates a container field.
        ///
        /// ```zig
        /// const Foo = struct {
        ///   bar: u32, // <- this is a container field
        /// }
        /// ```
        s_member: bool = false,
    };
};

/// Stores symbols created and referenced within a Zig program.
///
/// ## Members and Exports
/// - members are "instance properties". Zig doesn't have classes, and doesn't
///   exactly have methods, so this is a bit of a misnomer. Basically, if you
///   create a new variable or constant that is an instantiation of a struct, its
///   struct fields and "methods" are members
///
/// - Exports are symbols directly accessible on the symbol itself. A symbol's
///   exports include private functions, even though accessing them is a compile
///   error.
///
/// ```zig
/// const Foo = struct {
///   bar: i32,                       // member
///   pub const qux = 42,             // export
///   const quux = 42,                // export, not public
///   pub fn baz(self: *Foo) void {}, // member
///   pub fn bang() void {},          // export
/// };
/// ```
pub const SymbolTable = struct {
    /// Indexed by symbol id.
    ///
    /// Do not write to this list directly.
    symbols: std.ArrayListUnmanaged(Symbol) = .{},
    /// Symbols on "instance objects" (e.g. field properties and instance
    /// methods).
    ///
    /// Do not write to this list directly.
    members: std.ArrayListUnmanaged(SymbolIdList) = .{},
    /// Symbols directly accessible on the symbol itself (e.g. static methods,
    /// constants, enum members).
    ///
    /// Do not write to this list directly.
    exports: std.ArrayListUnmanaged(SymbolIdList) = .{},

    const SymbolIdList = std.ArrayListUnmanaged(Symbol.Id);

    pub inline fn get(self: *SymbolTable, id: Symbol.Id) *const Symbol {
        return &self.symbols.items[id];
    }
    pub fn addSymbol(self: *SymbolTable, alloc: Allocator, declaration_node: Ast.Node.Index, name: string, scope_id: Scope.Id, visibility: Symbol.Visibility, flags: Symbol.Flags) !*Symbol {
        assert(self.symbols.items.len < Symbol.MAX_ID);

        const id: Symbol.Id = @intCast(self.symbols.items.len);
        const symbol: *Symbol = try self.symbols.addOne(alloc);
        symbol.* = Symbol{
            // line break
            .name = name,
            // .ty = ty,
            .id = id,
            .scope = scope_id,
            .visibility = visibility,
            .flags = flags,
            .decl = declaration_node,
        };

        try self.members.append(alloc, .{});
        try self.exports.append(alloc, .{});

        // sanity check
        assert(self.symbols.items.len == self.members.items.len);
        assert(self.symbols.items.len == self.exports.items.len);

        return symbol;
    }

    pub fn addMember(self: *SymbolTable, alloc: Allocator, member: Symbol.Id, container: Symbol.Id) !void {
        var members = self.members.items[container];
        try members.append(alloc, member);
    }

    pub fn addExport(self: *SymbolTable, alloc: Allocator, member: Symbol.Id, container: Symbol.Id) !void {
        var exports = self.exports.items[container];
        try exports.append(alloc, member);
    }

    pub fn deinit(self: *SymbolTable, alloc: Allocator) void {
        self.symbols.deinit(alloc);

        {
            var i: usize = 0;
            const len = self.members.items.len;
            while (i < len) {
                var members = self.members.items[i];
                members.deinit(alloc);
                i += 1;
            }
            self.members.deinit(alloc);
        }

        {
            var i: usize = 0;
            const len = self.exports.items.len;
            while (i < len) {
                var exports = self.exports.items[i];
                exports.deinit(alloc);
                i += 1;
            }
            self.exports.deinit(alloc);
        }
    }
};
