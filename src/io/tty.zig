const std = @import("std");
const builtin = @import("builtin");
const Environ = std.process.Environ;

pub fn supportsUnicode(io: std.Io, file: std.Io.File, environ: Environ) bool {
    // Piped output is not constrained by the terminal's character set.
    if (!(file.isTty(io) catch false)) return true;

    if (comptime builtin.os.tag == .windows) {
        return environ.containsConstant("CI") or
            environ.containsConstant("WT_SESSION") or
            envEquals(environ, "ConEmuTask", "{cmd:Cmder}") or
            envEquals(environ, "TERM_PROGRAM", "vscode") or
            envEquals(environ, "TERM", "xterm-256color") or
            envEquals(environ, "TERM", "alacritty");
    }

    if (envEquals(environ, "TERM", "linux")) return false;

    const ctype = environ.getPosix("LC_ALL") orelse
        environ.getPosix("LC_CTYPE") orelse
        environ.getPosix("LANG") orelse
        return false;

    return std.ascii.endsWithIgnoreCase(ctype, "UTF8") or
        std.ascii.endsWithIgnoreCase(ctype, "UTF-8");
}

fn envEquals(environ: Environ, comptime name: []const u8, comptime expected: []const u8) bool {
    if (comptime builtin.os.tag == .windows) {
        const key = comptime std.unicode.wtf8ToWtf16LeStringLiteral(name);
        const value = environ.getWindows(key) orelse return false;
        const expected_w = comptime std.unicode.wtf8ToWtf16LeStringLiteral(expected);
        return std.mem.eql(u16, value, expected_w[0..expected_w.len]);
    }
    return if (environ.getPosix(name)) |value| std.mem.eql(u8, value, expected) else false;
}

test "non-terminal output supports unicode" {
    try std.testing.expect(supportsUnicode(std.testing.io, std.Io.File.stderr(), Environ.empty));
}
