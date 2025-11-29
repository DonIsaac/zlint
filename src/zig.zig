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
    pub fn fmtEscapes(bytes: []const u8) std.fmt.Formatter([]const u8, stringEscape) {
        return .{ .data = bytes };
    }

    test fmtEscapes {
        const expectFmt = std.testing.expectFmt;
        try expectFmt("\\x0f", "{any}", .{fmtEscapes("\x0f")});
        try expectFmt(
            \\" \\ hi \x07 \x11 \" derp '"
        , "\"{any}\"", .{fmtEscapes(" \\ hi \x07 \x11 \" derp '")});
    }

    /// Print the string as escaped contents of a double quoted string.
    pub fn stringEscape(bytes: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (bytes) |byte| switch (byte) {
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            '\\' => try w.writeAll("\\\\"),
            '"' => try w.writeAll("\\\""),
            '\'' => try w.writeByte('\''),
            ' ', '!', '#'...'&', '('...'[', ']'...'~' => try w.writeByte(byte),
            else => {
                try w.writeAll("\\x");
                try w.printInt(byte, 16, .lower, .{ .width = 2, .fill = '0' });
            },
        };
    }
};
