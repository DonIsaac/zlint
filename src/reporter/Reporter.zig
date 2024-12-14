pub const FormatError = Writer.Error || std.mem.Allocator.Error;
const Chameleon = @import("chameleon");

pub const Options = struct {
    quiet: bool = false,
};

pub const Reporter = struct {
    writer: Writer,
    writer_lock: Mutex = .{},
    stats: Stats = .{},
    opts: Options = .{},
    alloc: Allocator,
    /// pointer to formatter impl. Allocation is owned.
    ptr: *anyopaque,
    vtable: struct {
        format: *const fn (ctx: *anyopaque, writer: *Writer, e: Error) FormatError!void,
        deinit: *const fn (ctx: *anyopaque, allocator: Allocator) void,
        destroy: *const fn (ctx: *anyopaque, allocator: Allocator) void,
    },

    /// Shorthand for creating a `Reporter` with a `GraphicalFormtter`, since
    /// this is so common.
    pub fn graphical(
        writer: Writer,
        allocator: Allocator,
        // Optionally override the default theme
        theme: ?formatters.Graphical.Theme,
    ) Allocator.Error!Reporter {
        var formatter = formatters.Graphical{ .alloc = allocator };
        if (theme) |t| formatter.theme = t;
        return init(formatters.Graphical, formatter, writer, allocator);
    }

    pub fn initKind(kind: formatters.Kind, writer: Writer, allocator: Allocator) Allocator.Error!Reporter {
        switch (kind) {
            formatters.Kind.graphical => {
                const f = formatters.Graphical{ .alloc = allocator };
                return init(formatters.Graphical, f, writer, allocator);
            },
            formatters.Kind.github => {
                const f = formatters.Github{};
                return init(formatters.Github, f, writer, allocator);
            },
        }
    }

    /// Create a new reporter. `formatter` is moved.
    pub fn init(
        comptime Formatter: type,
        formatter: Formatter,
        writer: Writer,
        allocator: Allocator,
    ) Allocator.Error!Reporter {
        const fmt = try allocator.create(Formatter);
        fmt.* = formatter;

        const gen = struct {
            fn format(ctx: *anyopaque, _writer: *Writer, e: Error) FormatError!void {
                const this: *Formatter = @alignCast(@ptrCast(ctx));
                return Formatter.format(this, _writer, e);
            }
            fn deinit(ctx: *anyopaque, alloc: Allocator) void {
                if (!@hasDecl(Formatter, "deinit")) return;
                const this: *Formatter = @alignCast(@ptrCast(ctx));
                const info = @typeInfo(Formatter.deinit);
                switch (info.Fn.params.len) {
                    1 => this.deinit(),
                    2 => this.deinit(alloc),
                    else => @compileError("Formatter.deinit must take (this) or (this, allocator) as parameters."),
                }
            }
            fn destroy(ctx: *anyopaque, alloc: Allocator) void {
                const this: *Formatter = @alignCast(@ptrCast(ctx));
                alloc.destroy(this);
            }
        };

        return .{
            .writer = writer,
            .alloc = allocator,
            .ptr = @ptrCast(fmt),
            .vtable = .{
                .format = &gen.format,
                .deinit = &gen.deinit,
                .destroy = &gen.destroy,
            },
        };
    }

    pub fn reportErrors(self: *Reporter, errors: std.ArrayList(Error)) void {
        defer errors.deinit();
        self.reportErrorSlice(errors.allocator, errors.items);
    }

    pub fn reportErrorSlice(self: *Reporter, alloc: std.mem.Allocator, errors: []Error) void {
        self.stats.recordErrors(errors);
        if (errors.len == 0) return;
        self.writer_lock.lock();
        defer self.writer_lock.unlock();

        for (errors) |err| {
            var e = err;
            defer e.deinit(alloc);
            if (self.opts.quiet and err.severity != .err) continue;
            self.vtable.format(self.ptr, &self.writer, err) catch @panic("Failed to write error.");
            self.writer.writeByte('\n') catch @panic("failed to write newline.");
        }
    }

    pub fn printStats(self: *Reporter, duration: i64) void {
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

    /// Deinitialize the underlying formatter. Only frees memory if the reporter
    /// owns this formatter.
    /// 1. The formatter has a `deinit()` method
    /// 2. This reporter owns the formatter.
    pub fn deinit(self: *Reporter) void {
        self.vtable.deinit(self.ptr, self.alloc);
        self.vtable.destroy(self.ptr, self.alloc);

        if (comptime util.IS_DEBUG) {
            self.vtable.format = &PanicForamtter.format;
            self.vtable.deinit = &PanicForamtter.deinit;
        }
    }
};

/// Formatter that always panics. Used to check for use-after-free bugs.
///
/// Only used in debug builds.
const PanicForamtter = struct {
    fn format(_: *anyopaque, _: *Writer, _: Error) FormatError!void {
        std.debug.panic("Attempted to format an error after this Reporter was freed.", .{});
    }
    fn deinit(_: *anyopaque, _: Allocator) void {
        std.debug.panic("Attempted to deinitialize the same Reporter twice. This is a bug.", .{});
    }
};

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
const util = @import("util");
const Error = @import("../Error.zig");
const Span = @import("../span.zig").Span;
const Allocator = std.mem.Allocator;
const formatters = @import("./formatter.zig");

const AtomicUsize = std.atomic.Value(usize);
const Mutex = std.Thread.Mutex;
const Writer = std.fs.File.Writer; // TODO: use std.io.Writer?

test {
    std.testing.refAllDecls(@This());
}
