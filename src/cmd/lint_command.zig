const std = @import("std");
const walk = @import("../walk/Walker.zig");
const _lint = @import("../linter.zig");
const _source = @import("../source.zig");
const _report = @import("../reporter.zig");

const fs = std.fs;
const log = std.log;
const mem = std.mem;
const path = std.fs.path;

const Allocator = std.mem.Allocator;
const GraphicalReporter = _report.GraphicalReporter;
const Source = _source.Source;
const Thread = std.Thread;
const WalkState = walk.WalkState;

const Linter = _lint.Linter;
const Options = @import("../cli/Options.zig");

pub fn lint(alloc: Allocator, _: Options) !void {
    var reporter = GraphicalReporter.init(std.io.getStdOut().writer(), .{ .alloc = alloc });

    // TODO: use options to specify number of threads (if provided)
    var visitor = try LintVisitor.init(alloc, &reporter, null);
    defer visitor.deinit();

    var src = try fs.cwd().openDir(".", .{ .iterate = true });
    defer src.close();
    var walker = try LintWalker.init(alloc, src, &visitor);
    defer walker.deinit();
    try walker.walk();
}

const LintWalker = walk.Walker(LintVisitor);

const LintVisitor = struct {
    linter: Linter,
    reporter: *GraphicalReporter,
    pool: *Thread.Pool,
    allocator: Allocator,

    fn init(allocator: Allocator, reporter: *GraphicalReporter, n_threads: ?u32) !LintVisitor {
        var linter = Linter.init(allocator);
        linter.registerAllRules();
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
        self.lintFileImpl(filepath) catch |e| {
            log.err("Failed to lint file '{s}': {any}\n", .{ filepath, e });
        };
    }

    fn lintFileImpl(self: *LintVisitor, filepath: []u8) !void {
        const file = fs.cwd().openFile(filepath, .{}) catch |e| {
            self.allocator.free(filepath);
            return e;
        };

        var source = try Source.init(self.allocator, file, filepath);
        defer source.deinit();

        const errors = try self.linter.runOnSource(&source);
        self.reporter.reportErrors(errors);
        // defer errors.deinit();
        // for (errors.items) |err| {
        //     log.err("{s}\n", .{err.message});
        // }
    }

    fn deinit(self: *LintVisitor) void {
        self.pool.deinit();
        self.allocator.destroy(self.pool);
        // NOTE: threads must be joined before deinit-ing linter
        self.linter.deinit();
    }
};
