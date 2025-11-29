// NOTE:
// This is a copy/paste of pieces from `std.zig` from v0.14.1
// MIT license. See `src/zig/0.14.1/LICENSE` for details.
pub const @"0.14.1" = struct {
    pub const Ast = @import("zig/0.14.1/Ast.zig");
    pub const Parse = @import("zig/0.14.1/Parse.zig");
    pub const Token = @import("zig/0.14.1/tokenizer.zig").Token;
    pub const Tokenizer = @import("zig/0.14.1/tokenizer.zig").Tokenizer;
    pub const primitives = @import("zig/0.14.1/primitives.zig");
    pub const string_literal = @import("zig/0.14.1/string_literal.zig");


    const std = @import("std");

    /// Return a Formatter for Zig Escapes of a double quoted string.
    /// The format specifier must be one of:
    ///  * `{}` treats contents as a double-quoted string.
    ///  * `{'}` treats contents as a single-quoted string.
    pub fn fmtEscapes(bytes: []const u8) std.fmt.Formatter(stringEscape) {
        return .{ .data = bytes };
    }

    test fmtEscapes {
        const expectFmt = std.testing.expectFmt;
        try expectFmt("\\x0f", "{}", .{fmtEscapes("\x0f")});
        try expectFmt(
            \\" \\ hi \x07 \x11 " derp \'"
        , "\"{'}\"", .{fmtEscapes(" \\ hi \x07 \x11 \" derp '")});
        try expectFmt(
            \\" \\ hi \x07 \x11 \" derp '"
        , "\"{}\"", .{fmtEscapes(" \\ hi \x07 \x11 \" derp '")});
    }

    /// Print the string as escaped contents of a double quoted or single-quoted string.
    /// Format `{}` treats contents as a double-quoted string.
    /// Format `{'}` treats contents as a single-quoted string.
    pub fn stringEscape(
        bytes: []const u8,
        comptime f: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        for (bytes) |byte| switch (byte) {
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            '\\' => try writer.writeAll("\\\\"),
            '"' => {
                if (f.len == 1 and f[0] == '\'') {
                    try writer.writeByte('"');
                } else if (f.len == 0) {
                    try writer.writeAll("\\\"");
                } else {
                    @compileError("expected {} or {'}, found {" ++ f ++ "}");
                }
            },
            '\'' => {
                if (f.len == 1 and f[0] == '\'') {
                    try writer.writeAll("\\'");
                } else if (f.len == 0) {
                    try writer.writeByte('\'');
                } else {
                    @compileError("expected {} or {'}, found {" ++ f ++ "}");
                }
            },
            ' ', '!', '#'...'&', '('...'[', ']'...'~' => try writer.writeByte(byte),
            // Use hex escapes for rest any unprintable characters.
            else => {
                try writer.writeAll("\\x");
                try std.fmt.formatInt(byte, 16, .lower, .{ .width = 2, .fill = '0' }, writer);
            },
        };
    }
};
