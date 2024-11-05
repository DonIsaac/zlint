const std = @import("std");
const builtin = @import("builtin");

pub const string = []const u8;
pub const stringSlice = [:0]const u8;
pub const stringMut = []u8;
pub const IS_DEBUG = builtin.mode == .Debug;

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
pub inline fn assert(condition: bool, fmt: string, args: anytype) void {
    if (comptime IS_DEBUG) {
        if (!condition) {
            std.debug.panic(fmt, args);
        }
    } else {
        std.debug.assert(condition);
    }
}
