pub const FormatError = Writer.Error || std.mem.Allocator.Error;
const Chameleon = @import("chameleon");

pub fn Reporter(
    Formatter: type,
    FormatFn: fn (ctx: *Formatter, writer: *Writer, e: Error) FormatError!void,
) type {
    return struct {
        writer: Writer,
        writer_lock: Mutex = .{},
        formatter: Formatter,
        stats: Stats = .{},

        const Self = @This();
        pub fn init(writer: Writer, formatter: Formatter) Self {
            return .{
                .writer = writer,
                .formatter = formatter,
            };
        }

        pub fn reportErrors(self: *Self, errors: std.ArrayList(Error)) void {
            // self.stats.recordErrors(errors.items.len);
            defer errors.deinit();
            self.reportErrorSlice(errors.allocator, errors.items);
            // if (errors.items.len == 0) return;
            // self.writer_lock.lock();
            // defer self.writer_lock.unlock();

            // for (errors.items) |err| {
            //     var e = err;
            //     FormatFn(&self.formatter, &self.writer, err) catch @panic("Failed to write error.");
            //     self.writer.writeByte('\n') catch @panic("failed to write newline.");
            //     e.deinit(errors.allocator);
            // }
        }

        pub fn reportErrorSlice(self: *Self, alloc: std.mem.Allocator, errors: []Error) void {
            self.stats.recordErrors(errors.len);
            if (errors.len == 0) return;
            self.writer_lock.lock();
            defer self.writer_lock.unlock();

            for (errors) |err| {
                var e = err;
                FormatFn(&self.formatter, &self.writer, err) catch @panic("Failed to write error.");
                self.writer.writeByte('\n') catch @panic("failed to write newline.");
                e.deinit(alloc);
            }
        }

        pub fn printStats(self: *Self, duration: i64) void {
            const yellow, const yd = comptime blk: {
                var c = Chameleon.initComptime();
                const yellow = c.yellow().createPreset();
                const yd = yellow.open ++ "{d}" ++ yellow.close;
                // const yk = yellow.open ++ "{d}" ++ yellow.close;
                break :blk .{ yellow, yd };
            };

            const errors = self.stats.numErrorsSync();
            const files = self.stats.numFilesSync();
            // yellow.fmt()
            self.writer.print(
                // "\tFound {s} errors across {s} files in {s}ms.\n",
                "\tFound " ++ yd ++ " errors across " ++ yd ++ " files in " ++ yellow.open ++ "{d}ms" ++ yellow.close ++ ".\n",
                .{ errors, files, duration },
            ) catch {};
        }
    };
}

const Stats = struct {
    num_files: AtomicUsize = AtomicUsize.init(0),
    num_errors: AtomicUsize = AtomicUsize.init(0),

    pub fn recordErrors(self: *Stats, num_errors: usize) void {
        _ = self.num_files.fetchAdd(1, .acquire);
        _ = self.num_errors.fetchAdd(num_errors, .acquire);
    }

    pub fn recordSuccess(self: *Stats) void {
        _ = self.num_files.fetchAdd(1, .acquire);
    }

    /// Get the number of linted files. Only call this after all files have been
    /// processed.
    pub fn numFilesSync(self: *const Stats) usize {
        return self.num_files.raw;
    }

    /// Get the number of lint errors. Only call this after all files have been
    /// processed.
    pub fn numErrorsSync(self: *const Stats) usize {
        return self.num_errors.raw;
    }
};

const std = @import("std");
const Error = @import("../Error.zig");
const Span = @import("../source.zig").Span;

const AtomicUsize = std.atomic.Value(usize);
const Mutex = std.Thread.Mutex;
const Writer = std.fs.File.Writer; // TODO: use std.io.Writer?
