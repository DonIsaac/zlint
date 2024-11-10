pub fn Reporter(Formatter: type) type {
    return struct {
        const Self = @This();
        // TODO: use std.io.Writer?
        writer: std.fs.File.Writer,
        writer_lock: std.Thread.Mutex = .{},
        formatter: Formatter,
    };
}

const std = @import("std");
