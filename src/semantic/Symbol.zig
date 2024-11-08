//! A declared variable/function/whatever.
//!
//! Type: `pub struct Symbol<'a>`

/// Identifier bound to this symbol.
///
///
/// Not all symbols have a bound name. In this case, `name` is an empty string, since
/// no valid bound identifier can ever be that value.
///
/// Symbols only borrow their names. These string slices reference data in
/// source text, which owns the allocation.
///
/// `&'a str`
name: string,
/// Only populated for symbols not bound to an identifier. Otherwise, this is an
/// empty string.
debug_name: string,
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

/// Symbols on "instance objects" (e.g. field properties and instance
/// methods).
///
/// Do not write to this list directly.
members: SymbolIdList = .{},
/// Symbols directly accessible on the symbol itself (e.g. static methods,
/// constants, enum members).
///
/// Do not write to this list directly.
exports: SymbolIdList = .{},

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

    /// A function declaration. Never a builtin. Could be a method.
    s_fn: bool = false,
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
    symbols: std.MultiArrayList(Symbol) = .{},

    pub inline fn get(self: *const SymbolTable, id: Symbol.Id) *const Symbol {
        return &self.symbols.get(id);
    }

    // zig fmt: off
    pub fn addSymbol(
        self: *SymbolTable,
        alloc: Allocator,
        declaration_node: Ast.Node.Index,
        name: ?string,
        debug_name: ?string,
        scope_id: Scope.Id,
        visibility: Symbol.Visibility,
        flags: Symbol.Flags,
    ) !Symbol.Id {

        assert(self.symbols.len < Symbol.MAX_ID);

        const id: Symbol.Id = @intCast(self.symbols.len);
        const symbol =  Symbol{
            .name = name orelse "",
            .debug_name = debug_name orelse "",
            // .ty = ty,
            .id = id,
            .scope = scope_id,
            .visibility = visibility,
            .flags = flags,
            .decl = declaration_node,
        };

        try self.symbols.append(alloc, symbol);

        return id;
    }
    // zig fmt: on

    pub inline fn getMembers(self: *const SymbolTable, container: Symbol.Id) *const SymbolIdList {
        return &self.symbols.items(.members)[container];
    }

    pub inline fn getMembersMut(self: *SymbolTable, container: Symbol.Id) *SymbolIdList {
        return &self.symbols.items(.members)[container];
    }

    pub fn addMember(self: *SymbolTable, alloc: Allocator, member: Symbol.Id, container: Symbol.Id) !void {
        try self.getMembersMut(container).append(alloc, member);
    }

    pub inline fn getExports(self: *const SymbolTable, container: Symbol.Id) *const SymbolIdList {
        return &self.symbols.items(.exports)[container];
    }

    pub inline fn getExportsMut(self: *SymbolTable, container: Symbol.Id) *SymbolIdList {
        return &self.symbols.items(.exports)[container];
    }

    pub inline fn addExport(self: *SymbolTable, alloc: Allocator, member: Symbol.Id, container: Symbol.Id) !void {
        try self.getExportsMut(container).append(alloc, member);
    }

    pub inline fn iter(self: *const SymbolTable) Iterator {
        return Iterator{ .table = self };
    }

    pub fn deinit(self: *SymbolTable, alloc: Allocator) void {
        {
            var i: Id = 0;
            const len: Id = @intCast(self.symbols.len);
            while (i < len) {
                self.getMembersMut(i).deinit(alloc);
                self.getExportsMut(i).deinit(alloc);
                i += 1;
            }
        }
        self.symbols.deinit(alloc);
    }
};

pub const Iterator = struct {
    curr: Symbol.Id = 0,
    table: *const SymbolTable,

    pub fn next(self: *Iterator) ?Symbol.Id {
        if (self.curr >= self.table.symbols.len) {
            return null;
        }
        const id = self.curr;
        self.curr += 1;
        return id;
    }
};

const Symbol = @This();

const std = @import("std");

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Scope = @import("Scope.zig");
const Type = std.builtin.Type;

const assert = std.debug.assert;
const string = @import("util").string;

const SymbolIdList = std.ArrayListUnmanaged(Symbol.Id);

test "SymbolTable.iter()" {
    const a = std.testing.allocator;
    const expectEqual = std.testing.expectEqual;

    var table = SymbolTable{};
    defer table.deinit(a);

    _ = try table.addSymbol(a, 1, "a", null, 0, .public, .{});
    _ = try table.addSymbol(a, 1, "b", null, 1, .public, .{});
    try expectEqual(2, table.symbols.len);

    var iter = table.iter();
    var i: usize = 0;
    while (iter.next()) |symbol| {
        _ = symbol;
        i += 1;
    }
    try expectEqual(2, i);
}
