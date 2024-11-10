pub fn Reporter(
    FormatterContext: type,
    Formatter: fn (ctx: *FormatterContext, e: Error) []const u8,
) type {
    return struct {
        const Self = @This();
        // TODO: use std.io.Writer?
        writer: std.fs.File.Writer,
        writer_lock: std.Thread.Mutex = .{},
        formatter: Formatter,
    };
}

const std = @import("std");
const Error = @import("Error.zig");
