const std = @import("std");
const mem = std.mem;
const meta = std.meta;

/// Provides bitflag methods and types for a packed struct.
///
/// ## Example
/// ```zig
/// const Bitflags = @import("util").Bitflags;
///
/// const Position = packed struct {
///   s_top: bool = false,
///   s_left: bool = false,
///   s_right: bool = false,
///   s_bottom: bool = false,
///
///   // Add the methods you need
///   const BitflagsMixin = Bitflags(Position);
///   pub const Flag = BitflagsMixin.Flag;
///   pub const empty = BitflagsMixin.empty;
///   pub const all = BitflagsMixin.all;
///   pub const isEmpty = BitflagsMixin.isEmpty;
///   pub const intersects = BitflagsMixin.intersects;
///   pub const contains = BitflagsMixin.contains;
///   pub const merge = BitflagsMixin.merge;
///   pub const set = BitflagsMixin.set;
///   pub const not = BitflagsMixin.not;
///   pub const eql = BitflagsMixin.eql;
/// };
/// ```
///
/// If you use a fixed-sized integer representation, use `_` as the last field
/// to pad the struct to the correct size.
pub fn Bitflags(Flags: type) type {
    const info = switch (@typeInfo(Flags)) {
        .@"struct" => |s| s,
        else => @compileError("Bitflags only works on packed structs."),
    };

    return struct {
        pub const Flag = meta.FieldEnum(Flags);
        pub const Repr = info.backing_integer orelse @compileError(@typeName(Flags) ++ " has no backing integer. Bitflags only works on packed structs with known layouts.");
        pub const empty: Flags = .{};
        pub const all: Flags = blk: {
            var flags = Flags{};
            for (@typeInfo(Flags).@"struct".fields) |field| {
                // skip padding. may not be present.
                if (field.type != bool) continue;
                @field(flags, field.name) = true;
            }
            break :blk flags;
        };
        const has_padding = @hasField(Flags, "_");

        /// Returns `true` if no flags are enabled.
        pub inline fn isEmpty(self: Flags) bool {
            const a: Repr = @bitCast(self);
            return a == 0;
        }

        /// Returns `true` if any flags in `other` are also enabled in `self`.
        pub fn intersects(self: Flags, other: Flags) bool {
            const a: Repr = @bitCast(self);
            const b: Repr = @bitCast(other);
            return a & b != 0;
        }

        /// Returns `true` if all flags in `other` are also enabled in `self`.
        ///
        /// ## Example
        /// ```zig
        /// const a = Flags{ .a = true };
        /// const b = Flags{ .b = true };
        /// try expect(a.contains(a));
        /// try expect(!a.contains(b));
        /// try expect(a.contains(Flags.empty));
        /// try expect(a.merge(b).contains(a));
        /// ```
        pub fn contains(self: Flags, other: Flags) bool {
            const a: Repr = @bitCast(self);
            const b: Repr = @bitCast(other);
            return (a & b) == b;
        }

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
            const a: Repr = @bitCast(self);
            const b: Repr = @bitCast(other);
            return @bitCast(a | b);
        }

        /// Enable or disable one or more flags. `self` is mutated in-place.
        /// Any value set to `true` in `flags` gets disabled.
        pub inline fn set(self: *Flags, flags: Flags, comptime enable: bool) void {
            const a: Repr = @bitCast(self.*);
            const b: Repr = @bitCast(flags);

            if (enable) {
                self.* = @bitCast(a | b);
            } else {
                self.* = @bitCast(a & ~b);
            }
        }

        /// Take the bitwise complement of `self`.
        pub inline fn not(self: Flags) Flags {
            const a: Repr = @bitCast(self);
            var complement: Flags = @bitCast(~a);
            if (comptime has_padding) {
                // clear padding bits
                @field(complement, "_") = 0;
            }
            return complement;
        }

        /// Returns `true` if two sets of flags have exactly the same flags
        /// enabled/diabled.
        pub fn eql(self: Flags, other: Flags) bool {
            const a: Repr = @bitCast(self);
            const b: Repr = @bitCast(other);
            return a == b;
        }

        pub inline fn repr(self: Flags) Repr {
            return @bitCast(self);
        }

        pub fn format(self: Flags, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll(@typeName(Flags) ++ "(");

            var first = true;
            inline for (@typeInfo(Flags).@"struct".fields) |field| {
                if (field.type != bool) continue;
                // "s_block" -> "block". less noisy.
                const name = if (field.name.len > 2 and mem.startsWith(u8, field.name, "s_")) field.name[2..] else field.name;
                // only print flags that are present.
                if (@field(self, field.name)) {
                    if (first) first = false else try writer.writeAll(" | ");
                    try writer.writeAll(name);
                }
            }

            try writer.writeByte(')');
        }

        // see: std.json.stringify.WriteStream for docs
        pub fn jsonStringify(self: *const Flags, jw: anytype) !void {
            try jw.beginArray();
            const fields = meta.fields(Flags);

            inline for (fields) |field| {
                const f = @field(self, field.name);
                if (@TypeOf(f) != bool) continue;
                var name: []const u8 = field.name;
                // "s_block" -> "block". less noisy.
                if (mem.startsWith(u8, name, "s_")) name = name[2..];
                // only print flags that are present.
                if (f) {
                    try jw.write(name);
                }
            }
            try jw.endArray();
        }
    };
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("bitflags_test.zig");
}

// zigfmt: off
test Bitflags {
    const Position = packed struct {
        s_top: bool = false,
        s_left: bool = false,
        s_right: bool = false,
        s_bottom: bool = false,

        const BitflagsMixin = Bitflags(@This());
        pub const Flag = BitflagsMixin.Flag;
        pub const jsonStringify = BitflagsMixin.jsonStringify;
    };
    try std.testing.expectEqual(4, @typeInfo(Position.Flag).@"enum".fields.len);

    const p = Position{ .s_top = true, .s_left = true };
    try std.testing.expectFmt(
        \\["top","left"]
    ,
        "{any}",
        .{std.json.fmt(p, .{})},
    );
}
// zigfmt: on
