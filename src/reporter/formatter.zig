//! Formatters process diagnostics for a `Reporter`.

pub const Github = @import("formatters/GithubFormatter.zig");
pub const Graphical = @import("formatters/GraphicalFormatter.zig");
pub const JSON = @import("formatters/JSONFormatter.zig");

pub const Meta = struct {
    report_statistics: bool,
};

pub const Kind = enum {
    ascii,
    graphical,
    github,
    json,

    const FormatMap = std.StaticStringMapWithEql(
        Kind,
        std.static_string_map.eqlAsciiIgnoreCase,
    );
    const formats = FormatMap.initComptime(&[_]struct { []const u8, Kind }{
        .{ "ascii", .ascii },
        .{ "github", .github },
        .{ "gh", .github },
        .{ "json", .json },
        .{ "graphical", .graphical },
        .{ "default", .graphical },
    });

    /// Get a formatter kind by name. Names are case-insensitive.
    pub fn fromString(str: []const u8) ?Kind {
        return formats.get(str);
    }
};

pub const FormatError = io.Writer.Error || Allocator.Error;

const std = @import("std");
const io = std.Io;
const Allocator = std.mem.Allocator;

test "Kind.fromString" {
    try std.testing.expectEqual(Kind.ascii, Kind.fromString("ASCII"));
    try std.testing.expectEqual(Kind.graphical, Kind.fromString("default"));
    try std.testing.expectEqual(Kind.graphical, Kind.fromString("graphical"));
    try std.testing.expectEqual(Kind.github, Kind.fromString("gh"));
    try std.testing.expectEqual(Kind.github, Kind.fromString("github"));
    try std.testing.expectEqual(Kind.json, Kind.fromString("json"));
    try std.testing.expectEqual(null, Kind.fromString("unknown"));
}
