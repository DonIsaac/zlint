//! Formatters process diagnostics for a `Reporter`.

pub const Github = @import("formatters/GithubFormatter.zig");
pub const Graphical = @import("formatters/GraphicalFormatter.zig");
pub const JSON = @import("formatters/JSONFormatter.zig");

pub const Meta = struct {
    report_statistics: bool,
};

pub const Kind = enum {
    ascii,
    unicode,
    github,
    json,
};

pub const FormatError = io.Writer.Error || Allocator.Error;

const std = @import("std");
const io = std.io;
const Allocator = std.mem.Allocator;
