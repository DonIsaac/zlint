pub const FormatError = Writer.Error || std.mem.Allocator.Error;
const Chameleon = @import("chameleon");

pub const Options = struct {
    quiet: bool = false,
};

pub fn Reporter(
    Formatter: type,
    FormatFn: fn (ctx: *Formatter, writer: *Writer, e: Error) FormatError!void,
) type {
    return struct {
        writer: Writer,
        writer_lock: Mutex = .{},
        formatter: Formatter,
        stats: Stats = .{},
        opts: Options = .{},

        const Self = @This();
        /// Initialization does not allocate memory. The formatter may allocate,
        /// but it always disposes of it after formatting each set of errors.
        pub fn init(writer: Writer, formatter: Formatter) Self {
            return .{
                .writer = writer,
                .formatter = formatter,
            };
        }

        pub fn reportErrors(self: *Self, errors: std.ArrayList(Error)) void {
            defer errors.deinit();
            self.reportErrorSlice(errors.allocator, errors.items);
        }

        pub fn reportErrorSlice(self: *Self, alloc: std.mem.Allocator, errors: []Error) void {
            self.stats.recordErrors(errors);
            if (errors.len == 0) return;
            self.writer_lock.lock();
            defer self.writer_lock.unlock();

            for (errors) |err| {
                var e = err;
                defer e.deinit(alloc);
                if (self.opts.quiet and err.severity != .err) continue;
                FormatFn(&self.formatter, &self.writer, err) catch @panic("Failed to write error.");
                self.writer.writeByte('\n') catch @panic("failed to write newline.");
            }
        }

        pub fn printStats(self: *Self, duration: i64) void {
            const yellow, const yd = comptime blk: {
                var c = Chameleon.initComptime();
                const yellow = c.yellow().createPreset();
                // Yellow {d} format string
                const yd = yellow.open ++ "{d}" ++ yellow.close;
                break :blk .{ yellow, yd };
            };

            const errors = self.stats.numErrorsSync();
            const warnings = self.stats.numWarningsSync();
            const files = self.stats.numFilesSync();
            self.writer.print(
                "\tFound " ++ yd ++ " errors and " ++ yd ++ " warnings across " ++ yd ++ " files in " ++ yellow.open ++ "{d}ms" ++ yellow.close ++ ".\n",
                .{ errors, warnings, files, duration },
            ) catch {};
        }
    };
}

const Stats = struct {
    num_files: AtomicUsize = AtomicUsize.init(0),
    num_errors: AtomicUsize = AtomicUsize.init(0),
    num_warnings: AtomicUsize = AtomicUsize.init(0),

    pub fn recordErrors(self: *Stats, errors: []const Error) void {
        var num_warnings: usize = 0;
        var num_errors: usize = 0;
        for (errors) |err| {
            switch (err.severity) {
                .warning => num_warnings += 1,
                .err => num_errors += 1,
                else => {},
            }
        }
        _ = self.num_files.fetchAdd(1, .acquire);
        _ = self.num_errors.fetchAdd(num_errors, .acquire);
        _ = self.num_warnings.fetchAdd(num_warnings, .acquire);
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

    /// Get the number of lint warnings. Only call this after all files have been
    /// processed.
    pub fn numWarningsSync(self: *const Stats) usize {
        return self.num_warnings.raw;
    }
};

const std = @import("std");
const Error = @import("../Error.zig");
const Span = @import("../span.zig").Span;

const AtomicUsize = std.atomic.Value(usize);
const Mutex = std.Thread.Mutex;
const Writer = std.fs.File.Writer; // TODO: use std.io.Writer?
