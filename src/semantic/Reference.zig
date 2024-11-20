//! A reference on a symbol. Describes where and how a symbol is used.

pub const Reference = @This();

symbol: Symbol.Id.Optional,
scope: Scope.Id,
node: Node.Index,
identifier: []const u8,
flags: Flags,

pub const Id = NominalId(u32);

const FLAGS_REPR = u8;

/// Describes how a reference uses a symbol.
///
/// ## Chained references
/// ```zig
/// const x = foo.bar.baz()
/// ```
/// - `foo` is `member | read`
/// - `bar` is `member | call`
/// - `baz` is `call`
pub const Flags = packed struct(FLAGS_REPR) {
    /// Reference is reading a symbol's value.
    read: bool = false,
    /// Reference is modifying the value stored in a symbol.
    write: bool = false,
    /// Reference is calling the symbol as a function.
    call: bool = false,
    /// Reference is using the symbol in a type annotation or function signature.
    ///
    /// Does not include type parameters.
    type: bool = false,
    /// Reference is on a field member.
    ///
    /// Mixed together with other flags to indicate how the member is being used.
    /// Make sure this is `false` if you want to check that a symbol is, itself,
    /// being read/written/etc.
    member: bool = false,
    // Padding.
    _: u3 = 0,

    pub fn eq(self: Flags, other: Flags) bool {
        const a: FLAGS_REPR = @bitCast(self);
        const b: FLAGS_REPR = @bitCast(other);
        return a == b;
    }

    pub fn merge(self: Flags, other: Flags) Flags {
        const a: FLAGS_REPR = @bitCast(self);
        const b: FLAGS_REPR = @bitCast(other);

        return @bitCast(a | b);
    }

    pub fn contains(self: Flags, other: Flags) bool {
        const a: FLAGS_REPR = @bitCast(self);
        const b: FLAGS_REPR = @bitCast(other);
        return (a & b) == b;
    }

    pub fn intersects(self: Flags, other: Flags) bool {
        const a: FLAGS_REPR = @bitCast(self);
        const b: FLAGS_REPR = @bitCast(other);
        return (a | b) > 0;
    }

    /// `true` if the referenced symbol is having its value read.
    ///
    /// ```zig
    /// const y = foo;
    /// //        ^^^
    /// ```
    pub inline fn isSelfRead(f: Flags) bool {
        return !f.member and f.read;
    }

    /// `true` if the referenced symbol is having its value modified.
    /// ```zig
    /// const y = foo + 1;
    /// //        ^^^
    /// ```
    pub inline fn isSelfWrite(f: Flags) bool {
        return !f.member and f.write;
    }

    /// `true` if the referenced symbol is being called.
    ///
    /// ```zig
    /// const y = foo();
    /// //        ^^^^^
    /// ```
    pub inline fn isSelfCall(f: Flags) bool {
        return !f.member and f.call;
    }

    /// `true` if the referenced symbol is being used in a type annotation.
    ///
    /// ```zig
    /// const y: Foo = .{};
    /// //       ^^^
    /// ```
    pub inline fn isSelfType(f: Flags) bool {
        return !f.member and f.type;
    }

    /// `true` if this symbol is having one of its members read.
    ///
    /// ```zig
    /// const y = foo.x;
    /// //        ^^^
    /// ```
    pub inline fn isMemberRead(f: Flags) bool {
        return f.member and f.read;
    }

    /// `true` if this symbol is having one of its members modified.
    ///
    /// ```zig
    /// const y = foo.x + 1;
    /// //        ^^^
    /// ```
    pub inline fn isMemberWrite(f: Flags) bool {
        return f.member and f.write;
    }

    /// `true` if this symbol is having one of its members called as a function.
    ///
    /// ```zig
    /// const y = foo.x();
    /// //        ^^^
    /// ```
    pub inline fn isMemberCall(f: Flags) bool {
        return f.member and f.call;
    }

    /// `true` if this symbol is having one of its members used in a type annotation.
    ///
    /// ```zig
    /// const y: mod.Foo = .{};
    /// //       ^^^
    /// ```
    pub inline fn isMemberType(f: Flags) bool {
        return f.member and f.type;
    }
};

const std = @import("std");
const NominalId = @import("id.zig").NominalId;

const Node = std.zig.Ast.Node;
const Scope = @import("Scope.zig");
const Symbol = @import("Symbol.zig");

const t = std.testing;
test {
    t.refAllDecls(@This());
    t.refAllDecls(Reference);
}

test "Flags.isMemberRead" {
    try t.expect(Flags.isMemberRead(.{ .member = true, .read = true }));
    try t.expect(Flags.isMemberRead(.{ .member = true, .read = true, .write = true }));

    // zig fmt: off
    try t.expect(!Flags.isMemberRead(.{ .member = true,  .write = true  }));
    try t.expect(!Flags.isMemberRead(.{ .member = false, .read  = true  }));
    try t.expect(!Flags.isMemberRead(.{ .member = true,  .read  = false }));
    // zig fmt: on
}