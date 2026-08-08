const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// Create a nominal identifier type with the same memory layout as `TRepr` (an
/// unsigned integer type).
///
/// The returned identifier type, `Id`, also has an `Optional` type that can be
/// used to compactly represent `?Id`. The only caveat is, since `Optional` uses
/// the largest possible value to represent `null`, `Id` must all be one less than
/// `TRepr`'s maximum value.
pub fn NominalId(TRepr: type) type {
    const info = @typeInfo(TRepr);
    comptime {
        const err = "NominalId representation must be an unsigned integer";
        switch (info) {
            .int => if (info.int.signedness == .signed) @compileError(err),
            else => @compileError(err),
        }
    }
    const max_repr = std.math.maxInt(TRepr);

    return enum(TRepr) {
        root = 0,
        _,

        const Id = @This();
        pub const Repr = TRepr;
        pub const max: Id = .from(max_repr);

        pub inline fn new(value: Repr) Id {
            return @enumFromInt(value);
        }

        /// Get this id in its integer representation.
        ///
        /// This is the same as `Id.into(Repr)`.
        pub inline fn int(self: Id) Repr {
            return @intFromEnum(self);
        }

        /// Check if two Ids are equal.
        pub inline fn eql(self: Id, other: Id) bool {
            return self.int() == other.int();
        }

        /// Cast a value into an Id.
        ///
        /// When `value` has the same type as `Repr`, this is effectively the
        /// same as `new(value)`.
        pub inline fn from(value: anytype) Id {
            const T = @TypeOf(value);
            return switch (T) {
                Repr, comptime_int => return @enumFromInt(value),
                Id => return value,
                Optional => @enumFromInt(@intFromEnum(value)),
                // allow other int types
                else => {
                    const intoInfo = @typeInfo(T);
                    switch (intoInfo) {
                        .int => {
                            if (comptime intoInfo.int.bits > info.int.bits) {
                                assert(value <= max_repr);
                            }
                            if (comptime intoInfo.int.signedness == .signed) {
                                assert(value >= 0);
                            }
                            return @enumFromInt(@as(Repr, @intCast(value)));
                        },
                        else => @compileError("Cannot create Id from type " ++ @typeName(T) ++ ". Only Maybe and " ++ @typeName(Repr) ++ " are supported."),
                    }
                },
            };
        }

        /// Cast this id into another type.
        ///
        /// - `into()` supports zero-overhead casts into the representation type,
        ///   itself, and integer types with more bits
        /// - You may also cast into `Id.Maybe`, but a bounds check is made,
        ///   panicking if the value is `MAX`.
        /// - Casting into other integer types is allowed, bounds checks are
        ///   made for types with fewer bits.
        pub inline fn into(self: Id, T: type) T {
            switch (T) {
                Repr => return @intFromEnum(self),
                Id => return self,
                Optional => {
                    std.debug.assert(self != max);
                    return @enumFromInt(@intFromEnum(self));
                },
                // try to turn this into another int type
                else => {
                    const intoInfo = @typeInfo(T);
                    switch (intoInfo) {
                        .int => {
                            if (comptime intoInfo.int.bits < info.int.bits) {
                                assert(self <= std.math.maxInt(T));
                            }
                            return @intFromEnum(self);
                        },
                        else => @compileError("Cannot create Id from type " ++ @typeName(T) ++ ". Only Maybe and " ++ @typeName(Repr) ++ " are supported."),
                    }
                },
            }
        }

        pub fn format(self: Id, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            return writer.printInt(@intFromEnum(self), 10, .lower, .{});
        }

        /// Try to turn this id into its corresponding optional type. Returns
        /// `null` if the id is `MAX` (which is used to represent `Optional.none`).
        pub inline fn optional(self: Id) ?Optional {
            return if (self == .max)
                null
            else
                @enumFromInt(@intFromEnum(self));
        }

        /// A compact representation of `?Id` using the Id's maximum value as `null`.
        pub const Optional = enum(Repr) {
            none = max_repr,
            _,

            /// The largest value that is not `none`.
            pub const max: Optional = @enumFromInt(max_repr - 1);

            pub inline fn new(value: ?Repr) Optional {
                return if (value == null or value.? == max_repr) Optional.none else @enumFromInt(value.?);
            }

            /// Get this id in its integer representation.
            ///
            /// This is the same as `Optional.into(Repr)`.
            pub inline fn int(self: Optional) Repr {
                return @intFromEnum(self);
            }

            /// Check if two ids are equal.
            pub inline fn eq(self: Id, other: Id) bool {
                return self.int() == other.int();
            }

            /// Try to cast an optional id ito its concrete id type.
            pub inline fn unwrap(self: Optional) ?Id {
                return if (self == .none)
                    null
                else
                    @enumFromInt(@intFromEnum(self));
            }

            pub inline fn from(id: ?Id) Optional {
                return if (id) |i|
                    @enumFromInt(@intFromEnum(i))
                else
                    Optional.none;
            }

            pub inline fn tryFrom(value: anytype) ?Optional {
                return Id.from(value).optional();
            }
        };
    };
}

test NominalId {
    const Id = NominalId(u32);
    try std.testing.expectEqual(std.math.maxInt(u32), Id.max.int());
    try std.testing.expectEqual(std.math.maxInt(u32) - 1, Id.Optional.max.int());
    try std.testing.expectEqual(Id.Optional.none, Id.Optional.new(std.math.maxInt(u32)));
    try std.testing.expectEqual(Id.root, Id.Optional.new(0).unwrap());
}

pub fn IndexVecUnmanaged(Id: type, T: type) type {
    const List = std.ArrayListUnmanaged(T);

    return struct {
        items: List = .{},
        const Self = @This();

        pub inline fn insert(self: *Self, value: T) Allocator.Error!Id {
            const id = Id.new(self.items.len);
            try self.items.append(value);
            return id;
        }

        pub inline fn get(self: *const Self, id: Id) *const T {
            return &self.items.items[id.int()];
        }

        pub inline fn getMut(self: *Self, id: Id) *T {
            return &self.items.items[id.int()];
        }

        pub inline fn len(self: *const Self) usize {
            return self.items.items.len;
        }

        pub inline fn deinit(self: *Self, alloc: Allocator) void {
            self.items.deinit(alloc);
        }
    };
}
