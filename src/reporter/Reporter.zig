pub const Options = struct {
    quiet: bool = false,
    report_stats: bool = true,
};

pub const Reporter = struct {
    opts: Options = .{},
    stats: Stats = .{},

    writer: io.BufferedWriter(4096, Writer),
    writer_lock: Mutex = .{},

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
                // TODO: check terminal support for unicode characters
                // TODO: any non-falsy value should turn off colors
                const color = !util.env.checkEnvFlag("NO_COLOR", .enabled);
                const f = formatters.Graphical.unicode(allocator, color);
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
        comptime if (!@hasDecl(Formatter, "meta")) {
            @compileError(@typeName(Formatter) ++ " is missing a meta: formatter.Meta declaration.");
        };

        const fmt = try allocator.create(Formatter);
        fmt.* = formatter;
        const meta: formatters.Meta = Formatter.meta;

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
            .writer = .{ .unbuffered_writer = writer },
            .opts = .{
                .report_stats = meta.report_statistics,
            },
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
            var w = self.writer.writer().any();
            self.vtable.format(self.ptr, &w, err) catch @panic("Failed to write error.");
            w.writeByte('\n') catch @panic("failed to write newline.");
        }
    }

    pub fn printStats(self: *Reporter, duration: i64) void {
        if (!self.opts.report_stats) return;
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
        var w = self.writer.writer().any();
        w.print(
            "\tFound " ++ yd ++ " errors and " ++ yd ++ " warnings across " ++ yd ++ " files in " ++ yellow.open ++ "{d}ms" ++ yellow.close ++ ".\n",
            .{ errors, warnings, files, duration },
        ) catch {};
    }

    /// Deinitialize the underlying formatter. Only frees memory if the reporter
    /// owns this formatter.
    /// 1. The formatter has a `deinit()` method
    /// 2. This reporter owns the formatter.
    pub fn deinit(self: *Reporter) void {
        self.writer.flush() catch {};
        self.vtable.deinit(self.ptr, self.alloc);
        self.vtable.destroy(self.ptr, self.alloc);

        if (comptime util.IS_DEBUG) {
            self.vtable.format = &PanicForamtter.format;
            self.vtable.deinit = &PanicForamtter.deinit;
        }
    }
    const BufferedWriter = io.BufferedWriter(1024, Writer);
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
const io = std.io;
const util = @import("util");
const Error = @import("../Error.zig");
const Allocator = std.mem.Allocator;
const formatters = @import("./formatter.zig");
const FormatError = formatters.FormatError;
const Chameleon = @import("chameleon");

const AtomicUsize = std.atomic.Value(usize);
const Mutex = std.Thread.Mutex;
const Writer = std.io.AnyWriter;

test {
    std.testing.refAllDecls(@This());
}
