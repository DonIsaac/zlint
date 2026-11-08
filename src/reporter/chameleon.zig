//! Comptime ANSI terminal styling.
//!
//! Vendored from [chameleon](https://github.com/tr1ckydev/chameleon) at
//! commit `414169dede742d9ac8261d31b9fca6e31a1d7246`, trimmed to the comptime
//! API. The upstream package's `build.zig` does not compile on Zig 0.17, so
//! it cannot be consumed as a dependency.
//!
//! This file is exposed as the `chameleon` module in `build.zig`. Import it by
//! module name, never by path, so it is only ever part of one module.
//!
//! ---
//!
//! MIT License
//!
//! Copyright (c) 2024 Aritra Karak
//!
//! Permission is hereby granted, free of charge, to any person obtaining a copy
//! of this software and associated documentation files (the "Software"), to deal
//! in the Software without restriction, including without limitation the rights
//! to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//! copies of the Software, and to permit persons to whom the Software is
//! furnished to do so, subject to the following conditions:
//!
//! The above copyright notice and this permission notice shall be included in all
//! copies or substantial portions of the Software.
//!
//! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//! IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//! FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//! AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//! LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//! OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//! SOFTWARE.

const std = @import("std");

pub fn initComptime() ComptimeChameleon {
    return .{};
}

/// Builds ANSI open/close escape sequences at comptime. Instances must be
/// `comptime var`s; every method operates on comptime-known strings.
///
/// Styles accumulate until consumed by `fmt` or `createPreset`, which reset
/// the builder. Presets keep their styles and can be reused.
pub const ComptimeChameleon = struct {
    open: []const u8 = "",
    close: []const u8 = "",
    preset: bool = false,

    const Self = @This();

    /// Returns `text` wrapped in the current styles.
    pub inline fn fmt(self: *Self, comptime text: []const u8) []const u8 {
        defer self.removeAll();
        return self.open ++ text ++ self.close;
    }

    /// Create a new instance with the current styles as a preset.
    pub inline fn createPreset(self: *Self) Self {
        defer self.removeAll();
        return .{
            .open = self.open,
            .close = self.close,
            .preset = true,
        };
    }

    inline fn addStyle(self: *Self, comptime style: Style) *Self {
        self.open = self.open ++ sgr(style.open);
        self.close = sgr(style.close) ++ self.close;
        return self;
    }

    inline fn removeAll(self: *Self) void {
        if (self.preset) return;
        self.open = "";
        self.close = "";
    }

    // modifiers

    pub inline fn reset(self: *Self) *Self {
        return self.addStyle(.{ .open = "0", .close = "0" });
    }
    pub inline fn bold(self: *Self) *Self {
        return self.addStyle(.{ .open = "1", .close = "22" });
    }
    pub inline fn dim(self: *Self) *Self {
        return self.addStyle(.{ .open = "2", .close = "22" });
    }
    pub inline fn italic(self: *Self) *Self {
        return self.addStyle(.{ .open = "3", .close = "23" });
    }
    pub inline fn underline(self: *Self) *Self {
        return self.addStyle(.{ .open = "4", .close = "24" });
    }
    pub inline fn inverse(self: *Self) *Self {
        return self.addStyle(.{ .open = "7", .close = "27" });
    }
    pub inline fn strikethrough(self: *Self) *Self {
        return self.addStyle(.{ .open = "9", .close = "29" });
    }

    // foreground colors

    pub inline fn black(self: *Self) *Self {
        return self.addStyle(fg("30"));
    }
    pub inline fn red(self: *Self) *Self {
        return self.addStyle(fg("31"));
    }
    pub inline fn green(self: *Self) *Self {
        return self.addStyle(fg("32"));
    }
    pub inline fn yellow(self: *Self) *Self {
        return self.addStyle(fg("33"));
    }
    pub inline fn blue(self: *Self) *Self {
        return self.addStyle(fg("34"));
    }
    pub inline fn magenta(self: *Self) *Self {
        return self.addStyle(fg("35"));
    }
    pub inline fn cyan(self: *Self) *Self {
        return self.addStyle(fg("36"));
    }
    pub inline fn white(self: *Self) *Self {
        return self.addStyle(fg("37"));
    }
    pub inline fn gray(self: *Self) *Self {
        return self.addStyle(fg("90"));
    }

    /// Set the foreground color to a 24-bit RGB color.
    pub inline fn rgb(self: *Self, comptime r: u8, comptime g: u8, comptime b: u8) *Self {
        return self.addStyle(.{
            .open = std.fmt.comptimePrint("38;2;{d};{d};{d}", .{ r, g, b }),
            .close = "39",
        });
    }

    const Style = struct {
        /// SGR parameter that enables the style.
        open: []const u8,
        /// SGR parameter that disables the style.
        close: []const u8,
    };

    inline fn fg(comptime code: []const u8) Style {
        return .{ .open = code, .close = "39" };
    }

    /// Wrap an SGR parameter in a Control Sequence Introducer.
    inline fn sgr(comptime param: []const u8) []const u8 {
        return "\x1b[" ++ param ++ "m";
    }
};

const t = std.testing;

test "fmt wraps text and resets the builder" {
    comptime var c = initComptime();
    const actual = comptime c.red().fmt("foo");
    try t.expectEqualStrings("\x1b[31mfoo\x1b[39m", actual);
    try t.expectEqualStrings("", c.open);
    try t.expectEqualStrings("", c.close);
}

test "styles nest with closes in reverse order" {
    comptime var c = ComptimeChameleon{};
    comptime var preset = c.bold().green().createPreset();
    const actual = comptime preset.fmt("foo");
    try t.expectEqualStrings("\x1b[1m\x1b[32mfoo\x1b[39m\x1b[22m", actual);
}

test "presets are reusable and leave the builder empty" {
    comptime var c = ComptimeChameleon{};
    comptime var preset = c.underline().createPreset();
    try t.expectEqualStrings("", c.open);
    try t.expect(preset.preset);
    try t.expectEqualStrings("\x1b[4ma\x1b[24m", comptime preset.fmt("a"));
    try t.expectEqualStrings("\x1b[4mb\x1b[24m", comptime preset.fmt("b"));
}

test "empty preset is a no-op" {
    comptime var c = ComptimeChameleon{};
    comptime var empty = c.createPreset();
    try t.expectEqualStrings("foo", comptime empty.fmt("foo"));
}

test "rgb" {
    comptime var c = ComptimeChameleon{};
    const preset = comptime c.rgb(255, 30, 0).createPreset();
    try t.expectEqualStrings("\x1b[38;2;255;30;0m", preset.open);
    try t.expectEqualStrings("\x1b[39m", preset.close);
}

test "gray" {
    comptime var c = ComptimeChameleon{};
    try t.expectEqualStrings("\x1b[90mx\x1b[39m", comptime c.gray().fmt("x"));
}
