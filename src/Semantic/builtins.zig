const std = @import("std");
const StaticStringSet = std.StaticStringMap(void);

/// ## References
/// - [Zig Docs - Primitive Types](https://ziglang.org/documentation/0.13.0/#Primitive-Types)
const PRIMITIVE_TYPES = StaticStringSet.initComptime([_]struct { []const u8 }{
    // integers
    .{"i8"},
    .{"i16"},
    .{"i32"},
    .{"i64"},
    .{"i128"},
    .{"isize"},
    .{"u8"}, // unsigned
    .{"u16"},
    .{"u32"},
    .{"u64"},
    .{"u128"},
    .{"usize"},

    // floats
    .{"f16"},
    .{"f32"},
    .{"f64"},
    .{"f80"},
    .{"f128"},

    // c types
    .{"c_char"},
    .{"c_short"},
    .{"c_int"},
    .{"c_long"},
    .{"c_longlong"},
    .{"c_longdouble"},
    .{"c_ushort"}, // unsigned
    .{"c_uint"},
    .{"c_ulong"},
    .{"c_ulonglong"},

    // etc
    .{"bool"},
    .{"void"},
    .{"anyopaque"},
    .{"noreturn"},
    .{"type"},
    .{"anyerror"},
    .{"comptime_int"},
    .{"comptime_float"},
});

/// ## References
/// - [Zig Docs - Primitive Values](https://ziglang.org/documentation/0.13.0/#Primitive-Values)
const PRIMITIVE_VALUES = StaticStringSet.initComptime([_]struct { []const u8 }{
    .{"null"},
    .{"undefined"},
    .{"true"},
    .{"false"},
});

/// Check if a type is built in to Zig itself.
///
/// ## References
/// - [Zig Docs - Primitive Types](https://ziglang.org/documentation/0.13.0/#Primitive-Types)
pub fn isPrimitiveType(typename: []const u8) bool {
    if (PRIMITIVE_TYPES.has(typename)) return true;

    // Zig allows arbitrary-sized integers.
    if (typename.len > 2 and (typename[0] == 'u' or typename[0] == 'i')) {
        for (1..typename.len) |i| switch (typename[i]) {
            '0'...'9' => {},
            else => return false,
        };

        return true;
    }

    return false;
}

/// Check if an identifier refers to a primitive value.
///
/// ## References
/// - [Zig Docs - Primitive Values](https://ziglang.org/documentation/0.13.0/#Primitive-Values)
pub fn isPrimitiveValue(value: []const u8) bool {
    return PRIMITIVE_VALUES.has(value);
}
