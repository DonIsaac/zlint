const std = @import("std");
const builtin = @import("builtin");
const unicode = std.unicode;
const posix = std.posix;

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
pub fn checkEnvFlag(comptime key: []const u8, comptime kind: ValueKind) bool {
    if (kind == .defined) return std.process.hasEnvVarConstant(key);
    if (native_os == .windows) {
        const key_w = unicode.utf8ToUtf16LeStringLiteral(key);
        const value = std.process.getenvW(key_w) orelse return false;
        // true for 1, on
        // NOTE: yes?
        return switch (value.len) {
            0 => false,
            1 => value[0] == '1',
            2 => (value[0] == 'o' or value[0] == 'O') and (value[1] == 'n' or value[1] == 'N'),
            else => false,
        };
    } else if (native_os == .wasi and !builtin.link_libc) {
        @compileError("ahg we need to support WASI?");
    } else {
        const value = posix.getenv(key) orelse return false;
        // true for 1, on
        // NOTE: yes?
        return switch (value.len) {
            0 => false,
            1 => value[0] == '1',
            2 => (value[0] == 'o' or value[0] == 'O') and (value[1] == 'n' or value[1] == 'N'),
            else => false,
        };
    }
}
