const std = @import("std");
const builtin = @import("builtin");
const unicode = std.unicode;
const Environ = std.process.Environ;

const native_os = builtin.os.tag;

/// Categories for environment values. Used to check flags, not when you actually
/// want the value itself
pub const ValueKind = enum {
    /// Environment variable is present
    defined,
    /// Environment variable has a "truthy" value (`1`, `on`, whatever)
    enabled,
};

/// Check a flag-like environment variable. Whether the flag is "on" depends on
/// `kind`:
/// - `.defined`: `true` if the env var is present at all
/// - `.enabled`: `true` if it has an affirmative value (`1` or `on`).
///                Case-insensitive.
pub fn checkEnvFlag(environ: Environ, comptime key: []const u8, comptime kind: ValueKind) bool {
    if (comptime Environ.Block == Environ.PosixBlock) {
        const value = environ.getPosix(key) orelse return false;
        return kind == .defined or isTruthy(u8, value);
    } else if (comptime native_os == .windows) {
        const key_w = comptime unicode.utf8ToUtf16LeStringLiteral(key);
        const value = environ.getWindows(key_w) orelse return false;
        return kind == .defined or isTruthy(u16, value);
    } else {
        // WASI/freestanding: the environment must be queried and allocated at
        // runtime; flag checks are not worth that cost.
        return false;
    }
}

/// `true` for `1` and (case-insensitive) `on`.
fn isTruthy(comptime Char: type, value: []const Char) bool {
    return switch (value.len) {
        1 => value[0] == '1',
        2 => (value[0] == 'o' or value[0] == 'O') and (value[1] == 'n' or value[1] == 'N'),
        else => false,
    };
}

test isTruthy {
    try std.testing.expect(isTruthy(u8, "1"));
    try std.testing.expect(isTruthy(u8, "on"));
    try std.testing.expect(isTruthy(u8, "ON"));

    try std.testing.expect(!isTruthy(u8, "0"));
    try std.testing.expect(!isTruthy(u8, "false"));
    try std.testing.expect(!isTruthy(u8, "no"));
}
