const LintService = @This();

pub const Options = struct {
    fix: Fix.Meta = Fix.Meta.disabled,
    /// Defaults to # of CPUs
    n_threads: ?u32 = null,
};

linter: Linter,
options: Options,
config: Config.Managed,
reporter: *reporters.Reporter,
pool: *Thread.Pool,
allocator: Allocator,

pub fn init(
    allocator: Allocator,
    reporter: *reporters.Reporter,
    config: Config.Managed,
    options: Options,
) !LintService {
    errdefer config.arena.deinit();
    var linter = try Linter.initWithOptions(allocator, config, .{ .fix = options.fix });
    errdefer linter.deinit();
    const pool = try allocator.create(Thread.Pool);
    errdefer allocator.destroy(pool);
    try pool.init(Thread.Pool.Options{
        .n_jobs = if (options.n_threads) |nt| @intCast(nt) else null,
        .allocator = allocator,
    });

    return .{
        .linter = linter,
        .options = options,
        .config = config,
        .reporter = reporter,
        .pool = pool,
        .allocator = allocator,
    };
}

pub fn deinit(self: *LintService) void {
    self.pool.deinit();
    self.allocator.destroy(self.pool);
    // NOTE: threads must be joined first
    self.linter.deinit();
}

pub inline fn rulesCount(self: *LintService) usize {
    return self.linter.rules.rules.items.len;
}

/// `filepath` must be an owned allocation on the heap, and gets moved into the
/// visitor. This is for thread safety reasons.
///
/// ## Errors
/// if queueing the lint job to the thread pool fails. Does not error if
/// linting fails.
pub fn lintFileParallel(self: *LintService, filepath: []u8) !void {
    return self.pool.spawn(LintService.lintFile, .{ self, filepath });
}

/// `filepath` must be an owned allocation on the heap, and gets moved into the
/// visitor. This is for thread safety reasons.
pub fn lintFile(self: *LintService, filepath: []u8) void {
    self.tryLintFile(filepath) catch |e| switch (e) {
        error.OutOfMemory => @panic("Out of memory"),
        else => {},
    };
}

fn tryLintFile(self: *LintService, filepath: []u8) !void {
    const file = fs.cwd().openFile(filepath, .{}) catch |e| {
        self.allocator.free(filepath);
        return e;
    };

    var source = try Source.init(self.allocator, file, filepath);
    defer source.deinit();
    var errors: ?std.ArrayList(Error) = null;

    self.lintSource(&source, &errors) catch |err| {
        if (errors) |e| {
            self.reporter.reportErrors(e);
        } else {
            _ = self.reporter.stats.num_errors.fetchAdd(1, .acquire);
        }
        return err;
    };
    self.reporter.stats.recordSuccess();
}

/// Lint a `Source` file in a single thread.
///
/// When an error is returned, the `errors` list will be populated with `Errors`
/// describing the problems found. Not necessarily true for allocation errors.
/// See `Linter.runOnSource` for more details.
pub fn lintSource(
    self: *LintService,
    source: *Source,
    errors: *?std.ArrayList(Error),
) (LintError || Allocator.Error)!void {
    // FIXME: empty sources break something but i forget what
    if (source.text().len == 0) return;
    var builder = Semantic.Builder.init(self.allocator);
    builder.withSource(source);
    defer builder.deinit();

    var semantic_result = builder.build(source.text()) catch |e| {
        errors.* = builder._errors.toManaged(self.allocator);
        return switch (e) {
            error.ParseFailed => LintError.ParseFailed,
            else => LintError.AnalysisFailed,
        };
    };
    if (semantic_result.hasErrors()) {
        errors.* = builder._errors.toManaged(self.allocator);
        semantic_result.value.deinit();
        return LintError.AnalysisFailed;
    }
    defer semantic_result.deinit();
    const semantic = semantic_result.value;

    var diagnostics_: ?Linter.Diagnostic.List = null;
    // NOTE: errors are moved into reporter, so only the list itself gets
    // destroyed (not the errors it contains.)
    defer if (diagnostics_) |*d| d.deinit();
    self.linter.runOnSource(&semantic, source, &diagnostics_) catch |e| {
        var diagnostics = diagnostics_ orelse return e;

        // FIXME: take errors from ctx. requires using Error instead of Diagnostic
        // when fix is false
        if (self.options.fix.isDisabled()) {
            const n = diagnostics.items.len;
            util.assert(n > 0, "Linter should never assign an empty error list when problems are reported", .{});
            util.assert(self.allocator.ptr == diagnostics.allocator.ptr, "diagnostics used a different allocator than one used to make errors", .{});
            var es = try std.ArrayList(Error).initCapacity(self.allocator, n);
            for (0..n) |i| es.appendAssumeCapacity(diagnostics.items[i].err);
            errors.* = es;
            return LintError.LintingFailed;
        }

        const unfixed_errors = try self.applyFixes(&diagnostics, source);
        if (unfixed_errors.items.len > 0) {
            errors.* = unfixed_errors;
            return LintError.LintingFailed;
        }
    };
}

fn applyFixes(self: *const LintService, diagnostics: *Linter.Diagnostic.List, source: *Source) Allocator.Error!std.ArrayList(Error) {
    var fixer = Fixer{ .allocator = self.allocator };
    var result = try fixer.applyFixes(source.text(), diagnostics.items);
    defer result.deinit(self.allocator);

    if (result.did_fix and source.pathname != null) {
        const pathname = source.pathname.?;
        // create instead of open to truncate contents
        // TODO: handle errors here instead of panicking
        var file = fs.cwd().createFile(pathname, .{}) catch |e| {
            std.debug.panic("Failed to apply fixes to '{s}': {}", .{ pathname, e });
        };
        defer file.close();
        file.writeAll(result.source.items) catch |e| std.debug.panic("Failed to save fixed source to '{s}': {s}", .{ pathname, @errorName(e) });
    }

    const managed = result.unfixed_errors.toManaged(self.allocator);
    result.unfixed_errors = .{};
    return managed;
}

const LintError = Linter.LintError;

const std = @import("std");
const util = @import("util");

const fs = std.fs;

const reporters = @import("../reporter.zig");

const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const Linter = @import("linter.zig").Linter;
const Config = @import("Config.zig");
const Source = @import("../source.zig").Source;
const Fix = @import("fix.zig").Fix;
const Fixer = @import("fix.zig").Fixer;
const Error = @import("../Error.zig");

const Semantic = @import("../Semantic.zig");
