pub fn Reporter(
    Formatter: type,
    FormatFn: fn (ctx: *Formatter, writer: *Writer, e: Error) Writer.Error!void,
) type {
    return struct {
        writer: Writer,
        writer_lock: Mutex = .{},
        formatter: Formatter,

        const Self = @This();
        pub fn init(writer: Writer, formatter: Formatter) Self {
            return .{
                .writer = writer,
                .formatter = formatter,
            };
        }
        pub fn reportErrors(self: *Self, errors: std.ArrayList(Error)) void {
            self.writer_lock.lock();
            defer self.writer_lock.unlock();

            for (errors.items) |err| {
                var e = err;
                FormatFn(&self.formatter, &self.writer, err) catch @panic("Failed to write error.");
                self.writer.writeByte('\n') catch @panic("failed to write newline.");
                e.deinit(errors.allocator);
            }
            errors.deinit();
        }
    };
}

const std = @import("std");
const Error = @import("../Error.zig");
const Span = @import("../source.zig").Span;
const Mutex = std.Thread.Mutex;
const Writer = std.fs.File.Writer; // TODO: use std.io.Writer?
