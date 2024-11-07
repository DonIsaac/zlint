const std = @import("std");
const walk = @import("../walk/Walker.zig");
const multiwalk = @import("../walk/MultiWalker.zig");
const _lint = @import("../lint.zig");
const _source = @import("../source.zig");

const mem = std.mem;
const fs = std.fs;
const path = std.fs.path;
const log = std.log;

const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const WalkState = walk.WalkState;
const Source = _source.Source;

const Linter = _lint.Linter;
const Options = @import("../cli/Options.zig");

pub fn lint(alloc: Allocator, opts: *const Options) !void {
    // TODO: use options to specify number of threads (if provided)
    var visitor = try LintVisitor.init(alloc, null);
    defer visitor.deinit();
    const paths = opts.args.items;
    var walker = switch (paths.len) {
        0 => try LintWalker.init(alloc, try fs.cwd().openDir(".", .{ .iterate = true }), &visitor),
        1 => try LintWalker.init(alloc, try fs.cwd().openDir(paths[0], .{ .iterate = true }), &visitor),
        else => try MultiLintWalker.init(alloc, paths, &visitor),
    };
    // var dirs: std.ArrayListUnmanaged(fs.Dir) = .{};
    // defer {
    //     for (0..dirs.items.len) |i| {
    //         dirs.items[i].close();
    //     }
    //     dirs.deinit(alloc);
    // }

    // if (opts.args.items.len == 0) {
    //     const cwd = try fs.cwd().openDir(".", .{ .iterate = true });
    //     try dirs.append(alloc, cwd);
    // } else {
    //     for (opts.args.items) |dir_to_lint| {
    //         const dir = try fs.cwd().openDir(dir_to_lint, .{ .iterate = true });
    //         try dirs.append(alloc, dir);
    //     }
    // }
    // std.debug.assert(dirs.items.len > 0);

    // var walker = try LintWalker.init(alloc, dirs.items[0], &visitor);
    // const rest = dirs.items[1..dirs.items.len];
    // for (rest) |dir| {
    //     try walker.addDir(dir);
    // }
    defer walker.deinit();
    try walker.walk();
}

const LintWalker = walk.Walker(LintVisitor);
const MultiLintWalker = multiwalk.MultiWalker(LintVisitor);

const LintVisitor = struct {
    linter: Linter,
    pool: *Thread.Pool,
    allocator: Allocator,

    fn init(allocator: Allocator, n_threads: ?u32) !LintVisitor {
        const linter = Linter.init(allocator);
        const pool = try allocator.create(Thread.Pool);
        errdefer allocator.destroy(pool);
        try Thread.Pool.init(pool, Thread.Pool.Options{ .n_jobs = n_threads, .allocator = allocator });

        return .{
            .linter = linter,
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
        std.debug.print("linting file '{s}'\n", .{filepath});
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

        var errors = try self.linter.runOnSource(&source);
        defer errors.deinit();
        for (errors.items) |err| {
            log.err("{s}\n", .{err.message});
        }
    }

    fn deinit(self: *LintVisitor) void {
        self.pool.deinit();
        self.allocator.destroy(self.pool);
        // NOTE: threads must be joined before deinit-ing linter
        self.linter.deinit();
    }
};
