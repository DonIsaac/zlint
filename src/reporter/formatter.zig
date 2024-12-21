//! Formatters process diagnostics for a `Reporter`.

pub const Github = @import("./formatters/GithubFormatter.zig");
pub const Graphical = @import("./formatters/GraphicalFormatter.zig");

pub const Meta = struct {
    report_statistics: bool,
};

pub const Kind = enum {
    graphical,
    github,

    const FormatMap = std.StaticStringMapWithEql(
        Kind,
        std.static_string_map.eqlAsciiIgnoreCase,
    );
    const formats = FormatMap.initComptime(&[_]struct { []const u8, Kind }{
        .{ "github", .github },
        .{ "gh", .github },
        .{ "graphical", .graphical },
        .{ "default", .graphical },
    });

    /// Get a formatter kind by name. Names are case-insensitive.
    pub fn fromString(str: []const u8) ?Kind {
        return formats.get(str);
    }
};

pub const FormatError = Writer.Error || Allocator.Error;

const std = @import("std");
const Writer = std.fs.File.Writer;
const Allocator = std.mem.Allocator;
