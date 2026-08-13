const std = @import("std");
const util = @import("util");
const walk = @import("../walk/Walker.zig");
const glob = @import("../walk/glob.zig");
const _lint = @import("../lint.zig");
const reporters = @import("../reporter.zig");
const lint_config = @import("lint_config.zig");

const mem = std.mem;
const path = std.fs.path;

const Allocator = std.mem.Allocator;
const Io = std.Io;

const WalkState = walk.WalkState;
const Error = @import("../Error.zig");

const LintService = _lint.LintService;
const Fix = _lint.Fix;
const Options = @import("../cli/Options.zig");

pub const Result = struct {
    exit_code: u8,
    stats: reporters.Stats.Snapshot,
};

/// Lint every Zig file in `cwd`, or the paths in `options.args` if any were
/// given. Diagnostics are written to `stdout`, which is flushed before
/// returning.
pub fn lint(
    alloc: Allocator,
    io: Io,
    environ: std.process.Environ,
    options: Options,
    cwd: Io.Dir,
    stdout: *Io.Writer,
) !Result {
    defer stdout.flush() catch @panic("failed to flush writer");

    // NOTE: everything config related is stored in the same arena. This
    // includes the config source string, the parsed Config object, and
    // (eventually) whatever each rule needs to store. This lets all configs
    // store slices to the config's source, avoiding allocations.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var reporter = try reporters.Reporter.initKind(options.format, io, environ, stdout, alloc);
    defer reporter.deinit();
    reporter.opts.quiet = options.quiet;
    reporter.opts.report_stats = reporter.opts.report_stats and options.summary;

    var config = resolve_config: {
        var diagnostic: ?Error = null;
        const c = lint_config.resolveLintConfig(&arena, io, cwd, "zlint.json", alloc, &diagnostic) catch {
            var reported: [1]Error = .{
                diagnostic orelse Error.newStatic("Failed to load zlint configuration."),
            };
            try reporter.reportErrorSlice(alloc, &reported);
            return .{ .exit_code = 1, .stats = reporter.stats.snapshot() };
        };
        break :resolve_config c;
    };
    try lint_config.readGitignore(&config, io, cwd);

    const start = Io.Timestamp.now(io, .real);

    {
        const fix = if (options.fix or options.fix_dangerously) Fix.Meta{
            .kind = .fix,
            .dangerous = options.fix_dangerously,
        } else Fix.Meta.disabled;

        // TODO: use options to specify number of threads (if provided)
        var service = try LintService.init(
            alloc,
            io,
            cwd,
            &reporter,
            config,
            .{ .fix = fix },
        );
        defer service.deinit();

        if (!options.stdin) {
            var visitor: LintVisitor = .{
                .service = &service,
                .allocator = alloc,
                .include = try resolveIncludeArgs(arena.allocator(), io, cwd, options.args.items),
                .exclude = config.config.ignore,
            };
            var src = try cwd.openDir(io, ".", .{ .iterate = true });
            defer src.close(io);
            var walker = try LintWalker.init(alloc, io, src, &visitor);
            defer walker.deinit();
            try walker.walk();
        } else {
            // SAFETY: initialized by reader
            var msg_buf: [4096]u8 = undefined;
            var delim_buf: [1024]u8 = undefined;
            var stdin = Io.File.stdin();
            var reader = stdin.readerStreaming(io, &msg_buf);
            while (try readUntilDelimiterOrEof(&reader.interface, &delim_buf, '\n')) |filepath| {
                if (!std.mem.endsWith(u8, filepath, ".zig")) continue;
                const owned = try alloc.dupe(u8, filepath);
                service.lintFileParallel(owned);
            }
        }
    }

    const stop = Io.Timestamp.now(io, .real);
    const duration: i64 = @intCast(@divTrunc(start.durationTo(stop).nanoseconds, std.time.ns_per_ms));
    const stats = reporter.stats.snapshot();
    if (stats.filesLinted() == 0 and reporter.opts.report_stats) {
        try stdout.writeAll(
            \\No Zig files were linted. Check the paths you passed to zlint, plus
            \\the `ignore` patterns in zlint.json and .gitignore.
            \\
        );
    }
    reporter.printStats(duration);

    const exit_code: u8 = if (stats.errors > 0)
        1
    else if (options.deny_warnings and stats.warnings > 0)
        1
    else
        0;
    return .{ .exit_code = exit_code, .stats = stats };
}

const Include = struct {
    pattern: glob.Pattern,
    /// Set when the argument named an existing file. Those bypass `ignore`;
    /// directories and globs do not.
    explicit_file: bool,
};

/// Resolve positional CLI paths into the patterns that select them.
///
/// A directory names everything beneath it, so `src`, `src/`, and `src/**` are
/// all the same request. Walked paths are relative to `cwd` and have no `./`
/// prefix or trailing separator, so a raw `src` would otherwise match nothing
/// (compare `lint_config.translateGitignoreLine`).
fn resolveIncludeArgs(
    allocator: Allocator,
    io: Io,
    cwd: Io.Dir,
    args: []const []const u8,
) Allocator.Error![]const Include {
    var include = try std.ArrayListUnmanaged(Include).initCapacity(allocator, 2 * args.len);
    for (args) |arg| {
        var pattern = arg;
        while (mem.startsWith(u8, pattern, "./")) pattern = pattern[2..];
        pattern = mem.trimEnd(u8, pattern, "/");

        // `.`, `./`, and `/` name the whole tree
        if (pattern.len == 0 or mem.eql(u8, pattern, ".")) {
            include.appendAssumeCapacity(.{ .pattern = "**", .explicit_file = false });
            continue;
        }

        const kind: ?Io.File.Kind = if (cwd.statFile(io, pattern, .{})) |stat| stat.kind else |_| null;
        switch (kind orelse .unknown) {
            // a file matches itself, and is linted even when an ignore covers it
            .file => include.appendAssumeCapacity(.{ .pattern = pattern, .explicit_file = true }),
            // a bare `src` never matches a file path, so only the `/**` form is useful
            .directory => include.appendAssumeCapacity(.{
                .pattern = try std.fmt.allocPrint(allocator, "{s}/**", .{pattern}),
                .explicit_file = false,
            }),
            // a glob, or a path that doesn't exist. Both forms, since we can't
            // tell whether it names files or directories.
            else => {
                include.appendAssumeCapacity(.{ .pattern = pattern, .explicit_file = false });
                if (!mem.endsWith(u8, pattern, "**")) {
                    include.appendAssumeCapacity(.{
                        .pattern = try std.fmt.allocPrint(allocator, "{s}/**", .{pattern}),
                        .explicit_file = false,
                    });
                }
            },
        }
    }
    return include.items;
}

const LintWalker = walk.Walker(LintVisitor);

const LintVisitor = struct {
    /// borrowed
    service: *LintService,
    allocator: Allocator,
    /// Patterns built from the command line (see `resolveIncludeArgs`).
    include: []const Include,
    exclude: []const glob.Pattern,

    pub fn visit(self: *LintVisitor, entry: walk.Entry) ?walk.WalkState {
        switch (entry.kind) {
            .directory => {
                // a file named on the command line keeps its ancestors walkable,
                // whichever rule would otherwise prune them
                if (self.hasExplicitFileUnder(entry.path)) return WalkState.Continue;

                if (entry.basename.len == 0 or entry.basename[0] == '.') {
                    return WalkState.Skip;
                } else if (mem.eql(u8, entry.basename, "vendor") or mem.eql(u8, entry.basename, "zig-out")) {
                    return WalkState.Skip;
                }
                // `startsWith` for `zlint.json` entries, globs for translated
                // `.gitignore` ones. Pruning is only safe because no pattern is
                // negated (see `translateGitignoreLine`).
                for (self.exclude) |ignore| {
                    if (mem.startsWith(u8, entry.path, ignore) or glob.match(ignore, entry.path)) {
                        return WalkState.Skip;
                    }
                }
            },
            .file => {
                if (!mem.eql(u8, path.extension(entry.path), ".zig")) {
                    return WalkState.Continue;
                }
                if (!self.isIncluded(&entry)) {
                    self.service.reporter.stats.recordSkipped();
                    return WalkState.Continue;
                }

                const filepath = self.allocator.dupe(u8, entry.path) catch {
                    return WalkState.Stop;
                };
                self.service.lintFileParallel(filepath);
            },
            else => {
                // todo: warn
            },
        }
        return WalkState.Continue;
    }

    fn isIncluded(self: *const LintVisitor, entry: *const walk.Entry) bool {
        util.debugAssert(
            entry.kind != .directory,
            "isIncluded should only be passed file-like things, got a dir.",
            .{},
        );

        if (self.include.len > 0) {
            var included = false;
            for (self.include) |inc| {
                if (!glob.match(inc.pattern, entry.path)) continue;
                if (inc.explicit_file) return true;
                included = true;
            }
            if (!included) return false;
        }

        for (self.exclude) |pattern| {
            if (glob.match(pattern, entry.path)) return false;
        }

        return true;
    }

    /// Whether any file named on the command line lives somewhere under `dir`.
    fn hasExplicitFileUnder(self: *const LintVisitor, dir: []const u8) bool {
        for (self.include) |inc| {
            if (!inc.explicit_file) continue;
            if (inc.pattern.len > dir.len and
                inc.pattern[dir.len] == '/' and
                mem.startsWith(u8, inc.pattern, dir))
            {
                return true;
            }
        }
        return false;
    }
};

/// Modified version of `streamUntilDelimiterOrEof` from zig v0.14.1's stdlib.
///
/// Reads from the stream until specified byte is found. If the buffer is not
/// large enough to hold the entire contents, `error.StreamTooLong` is returned.
/// If end-of-stream is found, returns the rest of the stream. If this
/// function is called again after that, returns null.
/// Returns a slice of the stream data, with ptr equal to `buf.ptr`. The
/// delimiter byte is written to the output buffer but is not included
/// in the returned slice.
pub fn readUntilDelimiterOrEof(self: *std.Io.Reader, buffer: []u8, delimiter: u8) anyerror!?[]u8 {
    var fbw = std.Io.Writer.fixed(buffer);
    const bytes_read = self.streamDelimiter(&fbw, delimiter) catch |err| switch (err) {
        error.EndOfStream => if (fbw.end == 0) {
            return null;
        } else {
            // Partial data at EOF (e.g. last line without trailing newline)
            return buffer[0..fbw.end];
        },

        else => |e| return e,
    };
    if (bytes_read == 0) return null;
    self.toss(1); // throw out the delimiter
    return buffer[0..bytes_read];
}

const t = std.testing;

const LintRun = struct {
    result: Result,
    /// Everything the reporter wrote to stdout.
    output: []const u8,
    allocator: Allocator,

    fn deinit(self: *LintRun) void {
        self.allocator.free(self.output);
    }
};

/// Run the lint command inside `fixture` (a path relative to the repo root),
/// capturing stdout instead of writing to the terminal.
fn runInFixture(allocator: Allocator, fixture: []const u8, args: []const []const u8) !LintRun {
    var dir = try Io.Dir.cwd().openDir(t.io, fixture, .{});
    defer dir.close(t.io);

    var options: Options = .{};
    defer options.deinit(allocator);
    try options.args.appendSlice(allocator, args);

    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    const result = try lint(
        allocator,
        t.io,
        .empty,
        options,
        dir,
        &out.writer,
    );
    return .{
        .result = result,
        .output = try out.toOwnedSlice(),
        .allocator = allocator,
    };
}

test "linting a directory reports per-file stats" {
    var run = try runInFixture(t.allocator, "test/fixtures/lint/basic", &.{});
    defer run.deinit();

    // clean.zig
    try t.expectEqual(1, run.result.stats.files_passed);
    // warn.zig (a warning) and fail/bad_syntax.zig (a parse error)
    try t.expectEqual(2, run.result.stats.files_errored);
    // generated.zig; `ignored-dir/` is pruned, so `vendored.zig` is never seen
    try t.expectEqual(1, run.result.stats.files_skipped);
    try t.expectEqual(3, run.result.stats.filesLinted());

    try t.expectEqual(1, run.result.stats.warnings);
    try t.expect(run.result.stats.errors > 0);
    try t.expectEqual(1, run.result.exit_code);
}

test "positional args restrict which files are linted" {
    var run = try runInFixture(t.allocator, "test/fixtures/lint/basic", &.{"clean.zig"});
    defer run.deinit();

    try t.expectEqual(1, run.result.stats.files_passed);
    try t.expectEqual(0, run.result.stats.files_errored);
    // warn.zig, generated.zig, fail/bad_syntax.zig. `ignored-dir/` is pruned
    try t.expectEqual(3, run.result.stats.files_skipped);
    try t.expectEqual(0, run.result.stats.errors);
    try t.expectEqual(0, run.result.stats.warnings);
    try t.expectEqual(0, run.result.exit_code);
}

test "an ignored directory is pruned" {
    var run = try runInFixture(t.allocator, "test/fixtures/lint/explicit-arg", &.{});
    defer run.deinit();

    // root.zig; `foo/` is pruned, so `foo/bar.zig` isn't counted as skipped
    try t.expectEqual(1, run.result.stats.files_passed);
    try t.expectEqual(0, run.result.stats.files_skipped);
    try t.expectEqual(1, run.result.stats.filesLinted());
}

test "an explicitly requested file inside an ignored directory is still linted" {
    var run = try runInFixture(t.allocator, "test/fixtures/lint/explicit-arg", &.{"foo/bar.zig"});
    defer run.deinit();

    try t.expectEqual(1, run.result.stats.files_passed);
    try t.expectEqual(0, run.result.stats.files_errored);
    // root.zig
    try t.expectEqual(1, run.result.stats.files_skipped);
    try t.expectEqual(0, run.result.exit_code);
}

test resolveIncludeArgs {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    // has `src/clean.zig`, `src/nested/deep.zig`, and `other.zig`
    var dir = try Io.Dir.cwd().openDir(t.io, "test/fixtures/lint/dir-arg", .{});
    defer dir.close(t.io);

    const cases = [_]struct { []const u8, []const Include }{
        // a directory names everything beneath it, however it is spelled
        .{ "src", &.{.{ .pattern = "src/**", .explicit_file = false }} },
        .{ "src/", &.{.{ .pattern = "src/**", .explicit_file = false }} },
        .{ "./src", &.{.{ .pattern = "src/**", .explicit_file = false }} },
        .{ "./src/", &.{.{ .pattern = "src/**", .explicit_file = false }} },
        .{ "src/nested", &.{.{ .pattern = "src/nested/**", .explicit_file = false }} },
        // an existing file matches itself, and outranks `ignore`
        .{ "other.zig", &.{.{ .pattern = "other.zig", .explicit_file = true }} },
        .{ "./src/clean.zig", &.{.{ .pattern = "src/clean.zig", .explicit_file = true }} },
        // the whole tree
        .{ ".", &.{.{ .pattern = "**", .explicit_file = false }} },
        .{ "./", &.{.{ .pattern = "**", .explicit_file = false }} },
        // a glob can't be stat'd, so it stays a glob and respects `ignore`
        .{ "src/**", &.{.{ .pattern = "src/**", .explicit_file = false }} },
        .{ "*.zig", &.{
            .{ .pattern = "*.zig", .explicit_file = false },
            .{ .pattern = "*.zig/**", .explicit_file = false },
        } },
        // so does a path that doesn't exist
        .{ "nope.zig", &.{
            .{ .pattern = "nope.zig", .explicit_file = false },
            .{ .pattern = "nope.zig/**", .explicit_file = false },
        } },
    };

    for (cases) |case| {
        const arg, const expected = case;
        const include = try resolveIncludeArgs(arena.allocator(), t.io, dir, &.{arg});
        t.expectEqual(expected.len, include.len) catch |e| {
            std.debug.print("arg: '{s}'\n", .{arg});
            for (include) |inc| std.debug.print("  got: '{s}' (file={})\n", .{ inc.pattern, inc.explicit_file });
            return e;
        };
        for (expected, include) |want, got| {
            try t.expectEqualStrings(want.pattern, got.pattern);
            t.expectEqual(want.explicit_file, got.explicit_file) catch |e| {
                std.debug.print("arg: '{s}', pattern: '{s}'\n", .{ arg, got.pattern });
                return e;
            };
        }
    }
}

test "a directory argument respects ignore patterns" {
    for ([_][]const u8{ "src", "src/", "src/**", "." }) |arg| {
        var run = try runInFixture(t.allocator, "test/fixtures/lint/dir-arg-ignored", &.{arg});
        defer run.deinit();

        // src/clean.zig, but not the ignored src/generated.zig
        t.expectEqual(1, run.result.stats.files_passed) catch |e| {
            std.debug.print("arg: '{s}'\n", .{arg});
            return e;
        };
        try t.expectEqual(1, run.result.stats.files_skipped);
        try t.expectEqual(0, run.result.exit_code);
    }
}

test "`.` lints exactly what passing no arguments does" {
    var dot = try runInFixture(t.allocator, "test/fixtures/lint/basic", &.{"."});
    defer dot.deinit();
    var bare = try runInFixture(t.allocator, "test/fixtures/lint/basic", &.{});
    defer bare.deinit();

    try t.expectEqual(bare.result.stats, dot.result.stats);
    try t.expectEqual(bare.result.exit_code, dot.result.exit_code);
}

test "an explicitly named file outranks the hidden-directory skip" {
    var run = try runInFixture(t.allocator, "test/fixtures/lint/explicit-arg", &.{".hidden/secret.zig"});
    defer run.deinit();

    try t.expectEqual(1, run.result.stats.files_passed);
    // root.zig. `foo/` is still pruned
    try t.expectEqual(1, run.result.stats.files_skipped);
    try t.expectEqual(0, run.result.exit_code);
}

test "an explicitly named file outranks the ignore that covers it" {
    // `generated.zig` is in this fixture's zlint.json `ignore` list
    var run = try runInFixture(t.allocator, "test/fixtures/lint/basic", &.{"generated.zig"});
    defer run.deinit();

    try t.expectEqual(1, run.result.stats.files_passed);
    try t.expectEqual(0, run.result.stats.files_errored);
    try t.expectEqual(0, run.result.exit_code);
}

test "a directory argument lints everything under it, however it is spelled" {
    // src/clean.zig and src/nested/deep.zig, but not other.zig
    for ([_][]const u8{ "src", "src/", "src/**", "./src", "./src/" }) |arg| {
        var run = try runInFixture(t.allocator, "test/fixtures/lint/dir-arg", &.{arg});
        defer run.deinit();

        t.expectEqual(2, run.result.stats.files_passed) catch |e| {
            std.debug.print("arg: '{s}'\n", .{arg});
            return e;
        };
        try t.expectEqual(0, run.result.stats.files_errored);
        try t.expectEqual(1, run.result.stats.files_skipped);
        try t.expectEqual(0, run.result.exit_code);
    }
}

test "`.` lints the whole tree" {
    // this fixture has no `ignore` patterns, so passing `.` matches passing no
    // arguments at all. They diverge when there are ignores, since explicitly
    // requested paths bypass them.
    for ([_][]const u8{ ".", "./", "**" }) |arg| {
        var run = try runInFixture(t.allocator, "test/fixtures/lint/dir-arg", &.{arg});
        defer run.deinit();

        t.expectEqual(3, run.result.stats.files_passed) catch |e| {
            std.debug.print("arg: '{s}'\n", .{arg});
            return e;
        };
        try t.expectEqual(0, run.result.stats.files_skipped);
    }

    var no_args = try runInFixture(t.allocator, "test/fixtures/lint/dir-arg", &.{});
    defer no_args.deinit();
    try t.expectEqual(3, no_args.result.stats.files_passed);
    try t.expectEqual(0, no_args.result.stats.files_skipped);
}

test "a run that lints nothing says so" {
    var run = try runInFixture(t.allocator, "test/fixtures/lint/basic", &.{"does-not-exist.zig"});
    defer run.deinit();

    try t.expectEqual(0, run.result.stats.filesLinted());
    // every Zig file the walker reaches; `ignored-dir/` is pruned
    try t.expectEqual(4, run.result.stats.files_skipped);
    try t.expectEqual(0, run.result.exit_code);
    try t.expect(mem.indexOf(u8, run.output, "No Zig files were linted") != null);
}
