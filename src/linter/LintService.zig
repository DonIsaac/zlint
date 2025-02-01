const LintService = @This();

pub const Options = struct {
    fix: bool = false,
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
    var linter = try Linter.init(allocator, config);
    errdefer linter.deinit();
    const pool = try allocator.create(Thread.Pool);
    errdefer allocator.destroy(pool);
    try Thread.Pool.init(pool, Thread.Pool.Options{ .n_jobs = options.n_threads, .allocator = allocator });

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

    self.runOnSource(&source, &errors) catch |err| {
        if (errors) |e| {
            self.reporter.reportErrors(e);
        } else {
            _ = self.reporter.stats.num_errors.fetchAdd(1, .acquire);
        }
        return err;
    };
    self.reporter.stats.recordSuccess();
}

fn runOnSource(
    self: *LintService,
    source: *Source,
    errors: *?std.ArrayList(Error),
) (LintError || Allocator.Error)!void {
    // FIXME: empty sources break something but i forget what
    if (source.text().len == 0) return;
    var builder = SemanticBuilder.init(self.allocator);
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

    return self.linter.runOnSource(&semantic, source, errors);
}
const LintError = Linter.LintError;

const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const path = std.fs.path;
const reporters = @import("../reporter.zig");
const walk = @import("../walk/Walker.zig");
const WalkState = walk.WalkState;

const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const Linter = @import("linter.zig").Linter;
const Config = @import("Config.zig");
const Source = @import("../source.zig").Source;
const Error = @import("../Error.zig");
const Semantic = @import("../semantic.zig").Semantic;
const SemanticBuilder = @import("../semantic.zig").SemanticBuilder;
