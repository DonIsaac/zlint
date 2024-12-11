const reporter = @import("./reporter/Reporter.zig");
pub const Reporter = reporter.Reporter;
pub const Options = reporter.Options;

/// Formatters process diagnostics for a `Reporter`.
pub const formatter = struct {
    pub const Github = @import("./reporter/formatters/GithubFormatter.zig");
    pub const Graphical = @import("./reporter/formatters/GraphicalFormatter.zig");

    pub const Error = reporter.FormatError;
};

// shorthands
pub const GraphicalReporter = Reporter(formatter.Graphical, formatter.Graphical.format);

/// Get a reporter by name. Names are case-insensitive.
pub fn fromName(name: []const u8) ?type {
    return reporters.get(name);
}
const reporters = std.StaticStringMapWithEql(
    type,
    std.static_string_map.eqlAsciiIgnoreCase,
){
    .{ "github", formatter.Github },
    .{ "gh", formatter.Github },
    .{ "graphical", formatter.Graphical },
    .{ "default", formatter.Graphical },
};

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const Error = @import("Error.zig");
const Span = @import("span.zig").Span;
const Mutex = std.Thread.Mutex;
const Writer = std.fs.File.Writer; // TODO: use std.io.Writer?
