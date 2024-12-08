const std = @import("std");
const walk = @import("../walk/Walker.zig");
const _lint = @import("../linter.zig");
const _source = @import("../source.zig");
const _report = @import("../reporter.zig");
const lint_config = @import("lint_config.zig");

const fs = std.fs;
const log = std.log;
const mem = std.mem;
const path = std.fs.path;

const Allocator = std.mem.Allocator;
const GraphicalReporter = _report.GraphicalReporter;
const Source = _source.Source;
const Thread = std.Thread;
const WalkState = walk.WalkState;
const Error = @import("../Error.zig");

const Linter = _lint.Linter;
const Options = @import("../cli/Options.zig");

pub fn lint(alloc: Allocator, options: Options) !u8 {
    const stdout = std.io.getStdOut().writer();
    // NOTE: everything config related is stored in the same arena. This
    // includes the config source string, the parsed Config object, and
    // (eventually) whatever each rule needs to store. This lets all configs
    // store slices to the config's source, avoiding allocations.
    var arena = std.heap.ArenaAllocator.init(alloc);
    const config = blk: {
        errdefer arena.deinit();
        break :blk try lint_config.resolveLintConfig(arena, fs.cwd(), "zlint.json");
    };
    var reporter = GraphicalReporter.init(stdout, .{ .alloc = alloc });
    reporter.opts = .{ .quiet = options.quiet };

    const start = std.time.milliTimestamp();

    {
        // TODO: use options to specify number of threads (if provided)
        var visitor = try LintVisitor.init(alloc, &reporter, config, null);
        defer visitor.deinit();

        var src = try fs.cwd().openDir(".", .{ .iterate = true });
        defer src.close();
        var walker = try LintWalker.init(alloc, src, &visitor);
        defer walker.deinit();
        try walker.walk();
    }

    const stop = std.time.milliTimestamp();
    const duration = stop - start;
    reporter.printStats(duration);
    return if (reporter.stats.numErrorsSync() > 0) 1 else 0;
}

const LintWalker = walk.Walker(LintVisitor);

const LintVisitor = struct {
    linter: Linter,
    reporter: *GraphicalReporter,
    pool: *Thread.Pool,
    allocator: Allocator,

    fn init(allocator: Allocator, reporter: *GraphicalReporter, config: _lint.Config.Managed, n_threads: ?u32) !LintVisitor {
        errdefer config.arena.deinit();
        var linter = try Linter.init(allocator, config);
        errdefer linter.deinit();
        // try linter.registerAllRules();
        const pool = try allocator.create(Thread.Pool);
        errdefer allocator.destroy(pool);
        try Thread.Pool.init(pool, Thread.Pool.Options{ .n_jobs = n_threads, .allocator = allocator });

        return .{
            .linter = linter,
            .reporter = reporter,
            .pool = pool,
            .allocator = allocator,
        };
    }

    pub fn visit(self: *LintVisitor, entry: walk.Entry) ?WalkState {
        switch (entry.kind) {
            .directory => {
                if (entry.basename.len == 0 or entry.basename[0] == '.') {
                    return WalkState.Skip;
                } else if (mem.eql(u8, entry.basename, "vendor") or mem.eql(u8, entry.basename, "zig-out")) {
                    return WalkState.Skip;
                }
            },
            .file => {
                if (!mem.eql(u8, path.extension(entry.path), ".zig")) {
                    return WalkState.Continue;
                }

                const filepath = self.allocator.dupe(u8, entry.path) catch {
                    return WalkState.Stop;
                };
                self.pool.spawn(LintVisitor.lintFile, .{ self, filepath }) catch |e| {
                    std.log.err("Failed to spawn lint job on file '{s}': {any}\n", .{ filepath, e });
                    self.allocator.free(filepath);
                    return WalkState.Stop;
                };
            },
            else => {
                // todo: warn
            },
        }
        return WalkState.Continue;
    }

    fn lintFile(self: *LintVisitor, filepath: []u8) void {
        self.lintFileImpl(filepath) catch |e| switch (e) {
            error.OutOfMemory => @panic("Out of memory"),
            else => {},
        };
    }

    fn lintFileImpl(self: *LintVisitor, filepath: []u8) !void {
        const file = fs.cwd().openFile(filepath, .{}) catch |e| {
            self.allocator.free(filepath);
            return e;
        };

        var source = try Source.init(self.allocator, file, filepath);
        defer source.deinit();
        var errors: ?std.ArrayList(Error) = null;

        self.linter.runOnSource(&source, &errors) catch |err| {
            if (errors) |e| {
                self.reporter.reportErrors(e);
            } else {
                _ = self.reporter.stats.num_errors.fetchAdd(1, .acquire);
            }
            return err;
        };
        self.reporter.stats.recordSuccess();
    }

    fn deinit(self: *LintVisitor) void {
        self.pool.deinit();
        self.allocator.destroy(self.pool);
        // NOTE: threads must be joined before deinit-ing linter
        self.linter.deinit();
    }
};
