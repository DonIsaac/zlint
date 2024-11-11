pub fn Reporter(
    Formatter: type,
    FormatFn: fn (ctx: *Formatter, e: Error) []const u8,
) type {
    comptime {
        _ = FormatFn;
    }

    return struct {
        // TODO: use std.io.Writer?
        writer: std.fs.File.Writer,
        writer_lock: std.Thread.Mutex = .{},
        formatter: Formatter,

        const Self = @This();
    };
}

const std = @import("std");
const Error = @import("Error.zig");
