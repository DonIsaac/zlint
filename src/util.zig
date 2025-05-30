const std = @import("std");
const builtin = @import("builtin");

pub const RUNTIME_SAFETY = builtin.mode != .ReleaseFast;
pub const IS_DEBUG = builtin.mode == .Debug;
pub const IS_TEST = builtin.is_test;
pub const IS_WINDOWS = builtin.target.os.tag == .windows;
pub const NEWLINE = if (IS_WINDOWS) "\r\n" else "\n";

pub const @"inline": std.builtin.CallingConvention = if (IS_DEBUG) .Inline else .Unspecified;

pub const env = @import("util/env.zig");
pub const NominalId = @import("util/id.zig").NominalId;
pub const Cow = @import("util/cow.zig").Cow;
pub const DebugOnly = @import("util/debug_only.zig").DebugOnly;
pub const debugOnly = @import("util/debug_only.zig").debugOnly;
pub const Bitflags = @import("util/bitflags.zig").Bitflags;
pub const FeatureFlags = @import("util/feature_flags.zig");

/// remove leading and trailing whitespace characters from a string
pub fn trimWhitespace(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, &std.ascii.whitespace);
}
pub fn trimWhitespaceRight(s: []const u8) []const u8 {
    return std.mem.trimRight(u8, s, &std.ascii.whitespace);
}
pub fn isWhitespace(c: u8) bool {
    return std.mem.indexOfScalar(u8, &std.ascii.whitespace, c) != null;
}

/// Assert that `condition` is true, panicking if it is not.
///
/// Behaves identically to `std.debug.assert`, except that assertions will fail
/// with a formatted message in debug builds. `fmt` and `args` follow the same
/// formatting conventions as `std.debug.print` and `std.debug.panic`.
///
/// Similarly to `std.debug.assert`, undefined behavior is invoked if
/// `condition` is false. In `ReleaseFast` mode, `unreachable` is stripped and
/// assumed to be true by the compiler, which will lead to strange program
/// behavior.
pub inline fn assert(condition: bool, comptime fmt: []const u8, args: anytype) void {
    if (comptime IS_DEBUG) {
        if (!condition) std.debug.panic(fmt, args);
    } else {
        if (!condition) unreachable;
    }
}

pub inline fn debugAssert(condition: bool, comptime fmt: []const u8, args: anytype) void {
    if (comptime IS_DEBUG) {
        if (!condition) std.debug.panic(fmt, args);
    }
}

pub inline fn assertUnsafe(condition: bool) void {
    if (comptime IS_DEBUG) {
        if (!condition) @panic("assertion failed");
    } else {
        @setRuntimeSafety(IS_DEBUG);
        if (!condition) unreachable;
    }
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
