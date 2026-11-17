const std = @import("std");

/// ## References
/// - [Zig Docs - Primitive Values](https://ziglang.org/documentation/0.16.0/#Primitive-Values)
const PRIMITIVE_VALUES = std.StaticStringMap(void).initComptime([_]struct { []const u8 }{
    .{"null"},
    .{"undefined"},
    .{"true"},
    .{"false"},
});

/// Check if a type is built in to Zig itself. Integer types are only matched
/// for syntax: oversized bit widths and leading zeros are accepted.
///
/// ## References
/// - [Zig Docs - Primitive Types](https://ziglang.org/documentation/0.16.0/#Primitive-Types)
pub fn isPrimitiveType(typename: []const u8) bool {
    return std.zig.primitives.isPrimitive(typename) and !PRIMITIVE_VALUES.has(typename);
}

const t = std.testing;

test isPrimitiveType {
    const types = [_][]const u8{ "u0", "i0", "u1", "i7", "u8", "u9", "i32", "u65535", "usize", "bool", "void", "f64" };
    for (types) |name| {
        errdefer std.debug.print("name: '{s}'\n", .{name});
        try t.expect(isPrimitiveType(name));
    }

    const not_types = [_][]const u8{ "", "u", "i", "ux", "u1x", "U8", "f8", "_", "null", "undefined", "true", "false" };
    for (not_types) |name| {
        errdefer std.debug.print("name: '{s}'\n", .{name});
        try t.expect(!isPrimitiveType(name));
    }
}
