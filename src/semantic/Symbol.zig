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
/// The token that declared this symbol. This is usually an `.identifier`.
///
/// `null` for anonymous symbols (i.e. no `name`).
///
/// TODO: this is redundant information to `name`, but `name` requires this + the
/// source text to extract. We could remove `name` at the cost of usability.
token: ast.MaybeTokenId,
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
decl: Node.Index,
visibility: Visibility,
flags: Flags,
references: std.ArrayListUnmanaged(Reference.Id) = .{},

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
pub const Id = NominalId(u32);
pub const MAX_ID = Id.MAX;

const SymbolIdList = std.ArrayListUnmanaged(Symbol.Id);

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

const FLAGS_REPR = u16;
pub const Flags = packed struct(FLAGS_REPR) {
    /// A container-level or local variable.
    ///
    /// If it's declared with a `const` or `var` keyword, this is true. Note
    /// that this includes static and threadlocal variables.
    ///
    /// ## References
    /// - [Container Level Variables](https://ziglang.org/documentation/master/#Container-Level-Variables)
    /// - [Local Variables](https://ziglang.org/documentation/master/#Local-Variables)
    s_variable: bool = false,
    /// A symbol bound by a control flow statement. e.g. `x` in `if (foo) |x| {}`
    ///
    /// Note that no identifier node is parsed for payload symbols, so symbols
    /// of this type will have their `declaration_node` set to the control flow
    /// block itself.
    ///
    /// `while`, `for`, `if`, `else`, and `catch` may all bind payloads.  Like
    /// function parameters, these are implicitly `const` and always have
    /// `s_const` set.
    s_payload: bool = false,
    /// Comptime symbol.
    ///
    /// Not `true` for inferred comptime parameters. That is, this is only
    /// `true` when the `comptime` modifier is present.
    s_comptime: bool = false,
    s_extern: bool = false,
    s_export: bool = false,
    /// Whether this symbol is a constant.
    ///
    /// Includes explicitly-defined constants (e.g. that use the `const`
    /// keyword) and implicit constants (e.g. function parameters).
    s_const: bool = false,
    /// Indicates a container field.
    ///
    /// ```zig
    /// const Foo = struct {
    ///   bar: Repr, // <- this is a container field
    /// }
    /// ```
    s_member: bool = false,
    /// A function declaration. Never a builtin. Could be a method.
    s_fn: bool = false,
    /// A function parameter.
    ///
    /// NOTE: Function parameter symbols use their type annotation as their
    /// declaration node. Zig does not appear to create an identifier node for parameters.
    s_fn_param: bool = false,
    s_catch_param: bool = false,
    s_error: bool = false,
    s_struct: bool = false,
    s_enum: bool = false,
    s_union: bool = false,
    _: u2 = 0,

    pub const Flag = std.meta.FieldEnum(Flags);
    pub const s_container: Flags = .{ .s_struct = true, .s_enum = true, .s_union = true, .s_error = true };

    pub inline fn merge(self: Flags, other: Flags) Flags {
        const a: FLAGS_REPR = @bitCast(self);
        const b: FLAGS_REPR = @bitCast(other);
        return @bitCast(a | b);
    }

    pub inline fn set(self: *Flags, flags: Flags, comptime enable: bool) void {
        const a: FLAGS_REPR = @bitCast(self.*);
        const b: FLAGS_REPR = @bitCast(flags);

        if (enable) {
            self.* = @bitCast(a | b);
        } else {
            self.* = @bitCast(a & ~b);
        }
    }

    /// Returns `true` if any flags in `other` are also enabled in `self`.
    pub fn intersects(self: Flags, other: Flags) bool {
        const a: FLAGS_REPR = @bitCast(self);
        const b: FLAGS_REPR = @bitCast(other);
        return a & b != 0;
    }
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
    references: std.MultiArrayList(Reference) = .{},
    unresolved_references: std.ArrayListUnmanaged(Reference.Id) = .{},

    /// Get a symbol from the table.
    pub inline fn get(self: *const SymbolTable, id: Symbol.Id) *const Symbol {
        return &self.symbols.get(id.into(usize));
    }

    pub fn addSymbol(
        self: *SymbolTable,
        alloc: Allocator,
        declaration_node: Node.Index,
        name: ?string,
        debug_name: ?string,
        token: ?ast.TokenIndex,
        scope_id: Scope.Id,
        visibility: Symbol.Visibility,
        flags: Symbol.Flags,
    ) Allocator.Error!Symbol.Id {
        assert(self.symbols.len < Symbol.MAX_ID);

        // const id: Symbol.Id = @intCast(self.symbols.len).into();
        const id = Id.from(self.symbols.len);
        const symbol = Symbol{
            .name = name orelse "",
            .debug_name = debug_name orelse "",
            .token = ast.MaybeTokenId.new(token),
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

    pub fn addReference(
        self: *SymbolTable,
        alloc: Allocator,
        reference: Reference,
    ) Allocator.Error!Reference.Id {
        const ref_id = Reference.Id.from(self.references.len);
        try self.references.append(alloc, reference);
        if (reference.symbol.unwrap()) |symbol_id| {
            try self.symbols.items(.references)[symbol_id.into(usize)].append(alloc, ref_id);
        }

        return ref_id;
    }

    pub fn getReference(
        self: *const SymbolTable,
        reference_id: Reference.Id,
    ) Reference {
        return self.references.get(reference_id.into(usize));
    }

    pub fn getReferences(
        self: *const SymbolTable,
        symbol_id: Symbol.Id,
    ) []const Reference.Id {
        return self.symbols.items(.references)[symbol_id.int()].items;
    }
    pub fn getReferencesMut(
        self: *SymbolTable,
        symbol_id: Symbol.Id,
    ) *std.ArrayListUnmanaged(Reference.Id) {
        return &self.symbols.items(.references)[symbol_id.int()];
    }

    pub inline fn getMembers(self: *const SymbolTable, container: Symbol.Id) *const SymbolIdList {
        return &self.symbols.items(.members)[container.int()];
    }

    pub inline fn getMembersMut(self: *SymbolTable, container: Symbol.Id) *SymbolIdList {
        return &self.symbols.items(.members)[container.int()];
    }

    pub fn addMember(self: *SymbolTable, alloc: Allocator, member: Symbol.Id, container: Symbol.Id) Allocator.Error!void {
        try self.getMembersMut(container).append(alloc, member);
    }

    pub inline fn getExports(self: *const SymbolTable, container: Symbol.Id) *const SymbolIdList {
        return &self.symbols.items(.exports)[container.int()];
    }

    pub inline fn getExportsMut(self: *SymbolTable, container: Symbol.Id) *SymbolIdList {
        return &self.symbols.items(.exports)[container.int()];
    }

    pub inline fn addExport(self: *SymbolTable, alloc: Allocator, member: Symbol.Id, container: Symbol.Id) Allocator.Error!void {
        try self.getExportsMut(container).append(alloc, member);
    }

    /// Look for a symbol bound to the given identifier. Mostly used for
    /// testing.
    ///
    /// Returns the first found
    /// symbol. Since symbols are bound in the order they're declared, this will
    /// be the first declaration.
    pub fn getSymbolNamed(self: *const SymbolTable, name: []const u8) ?Symbol.Id {
        const names = self.symbols.items(.name);

        for (0..names.len) |symbol_id| {
            if (std.mem.eql(u8, names[symbol_id], name)) {
                return Symbol.Id.from(symbol_id);
            }
        }

        return null;
    }

    pub inline fn iter(self: *const SymbolTable) Iterator {
        return Iterator{ .table = self };
    }

    /// Iterate over a symbol's references.
    pub inline fn iterReferences(self: *const SymbolTable, id: Symbol.Id) ReferenceIterator {
        const refs = self.symbols.items(.references)[id.int()].items;
        return ReferenceIterator{ .table = self, .refs = refs };
    }

    pub fn deinit(self: *SymbolTable, alloc: Allocator) void {
        {
            var i: Id.Repr = 0;
            const len: Id.Repr = @intCast(self.symbols.len);
            while (i < len) {
                const id = Id.from(i);
                self.getMembersMut(id).deinit(alloc);
                self.getExportsMut(id).deinit(alloc);
                self.getReferencesMut(id).deinit(alloc);
                i += 1;
            }
        }
        self.symbols.deinit(alloc);
        self.references.deinit(alloc);
        self.unresolved_references.deinit(alloc);
    }
};

pub const Iterator = struct {
    curr: Id.Repr = 0,
    table: *const SymbolTable,

    pub fn next(self: *Iterator) ?Symbol.Id {
        if (self.curr >= self.table.symbols.len) {
            return null;
        }
        const id = self.curr;
        self.curr += 1;
        return Id.from(id);
    }
};

pub const ReferenceIterator = struct {
    curr: usize = 0,
    table: *const SymbolTable,
    refs: []Reference.Id,

    pub inline fn len(self: ReferenceIterator) usize {
        return self.refs.len;
    }

    pub fn next(self: *ReferenceIterator) ?Reference {
        if (self.curr >= self.refs.len) return null;

        defer self.curr += 1;
        const ref_id = self.refs[self.curr];
        return self.table.getReference(ref_id);
    }
};

const Symbol = @This();

const std = @import("std");
const util = @import("util");
const ast = @import("ast.zig");

const Allocator = std.mem.Allocator;
const Type = std.builtin.Type;
const NominalId = util.NominalId;

const Node = ast.Node;
const Scope = @import("Scope.zig");
const Reference = @import("Reference.zig");

const assert = std.debug.assert;
const string = @import("util").string;

test "SymbolTable.iter()" {
    const a = std.testing.allocator;
    const expectEqual = std.testing.expectEqual;

    var table = SymbolTable{};
    defer table.deinit(a);

    _ = try table.addSymbol(a, 1, "a", null, null, Scope.Id.new(0), .public, .{});
    _ = try table.addSymbol(a, 1, "b", null, null, Scope.Id.new(1), .public, .{});
    try expectEqual(2, table.symbols.len);

    var iter = table.iter();
    var i: usize = 0;
    while (iter.next()) |symbol| {
        _ = symbol;
        i += 1;
    }
    try expectEqual(2, i);
}
