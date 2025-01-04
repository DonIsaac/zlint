const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const NominalId = @import("./util/id.zig").NominalId;
pub const Cow = @import("./util/cow.zig").Cow;

pub const string = []const u8;
pub const stringSlice = [:0]const u8;
pub const stringMut = []u8;

pub const RUNTIME_SAFETY = builtin.mode != .ReleaseFast;
pub const IS_DEBUG = builtin.mode == .Debug;
pub const IS_WINDOWS = builtin.target.os.tag == .windows;
pub const NEWLINE = if (IS_WINDOWS) "\r\n" else "\n";

pub const DebugOnly = @import("./util/debug_only.zig").DebugOnly;
pub const debugOnly = @import("./util/debug_only.zig").debugOnly;

const WHITESPACE = [4]u8{ ' ', '\t', '\n', '\r' };
pub fn trimWhitespace(s: string) string {
    return std.mem.trim(u8, s, &WHITESPACE);
}

pub fn trimWhitespaceRight(s: string) string {
    return std.mem.trimRight(u8, s, &WHITESPACE);
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
pub inline fn assert(condition: bool, comptime fmt: string, args: anytype) void {
    if (comptime IS_DEBUG) {
        if (!condition) {
            std.debug.panic(fmt, args);
        }
    } else {
        std.debug.assert(condition);
    }
}

pub inline fn debugAssert(condition: bool, comptime fmt: string, args: anytype) void {
    if (comptime IS_DEBUG) {
        if (!condition) std.debug.panic(fmt, args);
    }
}

pub inline fn assertUnsafe(condition: bool) void {
    if (comptime IS_DEBUG) {
        if (!condition) @panic("assertion failed");
    } else {
        @setRuntimeSafety(IS_DEBUG);
        unreachable;
    }
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
