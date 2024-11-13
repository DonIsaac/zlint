pub const RESET = style("0");
pub const BOLD = style("1");
pub const DIM = style("2");
pub const ITALIC = style("3");
pub const UNDERLINE = style("4");
pub const BLINK = style("5");
pub const INVERT = style("7");
pub const HIDDEN = style("8");
pub const STRIKETHROUGH = style("9");

pub fn style(comptime ctl: anytype) staticString {
    return "\x1b[" ++ ctl ++ "m";
}

const staticString = []const u8;

test {
    const std = @import("std");
    const expectEqual = std.testing.expectEqual;

    try expectEqual(BOLD, "\x1b[1m");
}
