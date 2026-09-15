const std = @import("std");
const zlint = @import("zlint");
const fs = @import("../io/fs.zig");
const walk = @import("../io/Walker.zig");

const lint_config = @import("lint/config.zig");
const gitignore = @import("lint/gitignore.zig");
const FileFilter = @import("lint/visitor.zig").FileFilter;

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const File = std.Io.File;
const path = std.fs.path;

const Error = zlint.Error;
const reporters = zlint.report;

const LintService = zlint.lint.LintService;
const Fix = zlint.lint.Fix;
const Options = @import("../cli/Options.zig");

const LintWalker = walk.Walker(FileFilter(LintSink));

/// Sink used by `lint`: hands each accepted file to the linter's thread pool.
const LintSink = struct {
    /// borrowed
    service: *LintService,

    pub fn accept(self: *LintSink, filepath: []u8) void {
        self.service.lintFileParallel(filepath);
    }
};

var buf: [4096]u8 = undefined;

pub fn lint(alloc: Allocator, io: std.Io, environ: std.process.Environ, options: Options) !u8 {
    // writer cannot live on the stack.
    // this gets moved into Reporter, which runs on a different thread.
    const writer = try alloc.create(File.Writer);
    writer.* = File.stdout().writer(io, &buf);
    defer alloc.destroy(writer);
    var stdout = &writer.interface;
    defer stdout.flush() catch @panic("failed to flush writer");

    // NOTE: everything config related is stored in the same arena. This
    // includes the config source string, the parsed Config object, and
    // (eventually) whatever each rule needs to store. This lets all configs
    // store slices to the config's source, avoiding allocations.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var reporter = try reporters.Reporter.initKind(options.format, io, environ, writer, alloc);
    defer reporter.deinit();
    reporter.opts.quiet = options.quiet;
    reporter.opts.report_stats = reporter.opts.report_stats and options.summary;

    var config = resolve_config: {
        var diagnostic: ?Error = null;
        const c = lint_config.getLintConfig(&arena, io, options.config, alloc, &diagnostic) catch {
            var reported: [1]Error = .{
                diagnostic orelse Error.newStatic("Failed to load zlint configuration."),
            };
            try reporter.reportErrorSlice(alloc, &reported);
            return 1;
        };
        break :resolve_config c;
    };
    try gitignore.readGitignore(
        &config,
        io,
        Dir.cwd(),
        if (options.config != null) .nearest_from_root else .beside_config,
    );

    const start = std.Io.Timestamp.now(io, .real);

    {
        const fix = if (options.fix or options.fix_dangerously) Fix.Meta{
            .kind = .fix,
            .dangerous = options.fix_dangerously,
        } else Fix.Meta.disabled;

        var src = try Dir.cwd().openDir(io, ".", .{ .iterate = true });
        defer src.close(io);

        // TODO: use options to specify number of threads (if provided)
        var service = try LintService.init(
            alloc,
            io,
            src,
            &reporter,
            config,
            .{ .fix = fix },
        );
        defer service.deinit();

        if (!options.stdin) {
            try lintTargets(alloc, io, &service, options, &config.config);
        } else {
            // SAFETY: initialized by reader
            var msg_buf: [4096]u8 = undefined;
            var delim_buf: [1024]u8 = undefined;
            var stdin = File.stdin();
            var reader = stdin.readerStreaming(io, &msg_buf);
            while (try fs.readUntilDelimiterOrEof(&reader.interface, &delim_buf, '\n')) |filepath| {
                if (!std.mem.endsWith(u8, filepath, ".zig")) continue;
                const owned = try alloc.dupe(u8, filepath);
                service.lintFileParallel(owned);
            }
        }
    }

    const stop = std.Io.Timestamp.now(io, .real);
    const duration: i64 = @intCast(@divTrunc(start.durationTo(stop).nanoseconds, std.time.ns_per_ms));
    reporter.printStats(duration);
    if (reporter.stats.numErrorsSync() > 0) {
        return 1;
    } else if (options.deny_warnings and reporter.stats.numWarningsSync() > 0) {
        return 1;
    } else {
        return 0;
    }
}

fn lintTargets(
    allocator: Allocator,
    io: std.Io,
    service: *LintService,
    options: Options,
    config: *zlint.lint.Config,
) !void {
    const targets = options.args.items;
    var sink = LintSink{ .service = service };
    var visitor: FileFilter(LintSink) = .{
        .sink = &sink,
        .allocator = allocator,
        .exclude = config.ignore,
    };

    // common-path: short circuit when linting everything
    if (targets.len == 0 or
        targets.len == 1 and std.mem.eql(u8, targets[0], "."))
    {
        var walker = try LintWalker.initAtDir(
            allocator,
            io,
            .{ .dir = service.cwd },
            &visitor,
        );
        defer walker.deinit();
        return walker.walk();
    }

    var walker = try LintWalker.init(allocator, io, &visitor);
    defer walker.deinit();
    for (targets) |target| {
        if (target.len == 0) {
            @branchHint(.cold);
            continue;
        }

        const prefix = normalizeTarget(target);

        // Explicitly specifying a file to lint bypasses ignore checks
        if (std.mem.endsWith(u8, prefix, ".zig")) {
            const filename = try allocator.dupe(u8, prefix);
            service.lintFileParallel(filename);
            continue;
        }

        const next_target = service.cwd.openDir(
            io,
            target,
            .{ .iterate = true },
        ) catch continue;
        defer next_target.close(io);
        try walker.reset(.{ .dir = next_target, .prefix = prefix });
        try walker.walk();
    }
}

pub fn normalizeTarget(target: []const u8) []const u8 {
    var normalized = target;
    while (normalized.len >= 2 and
        normalized[0] == '.' and path.isSep(normalized[1]))
    {
        normalized = normalized[1..];
        while (normalized.len > 0 and path.isSep(normalized[0])) {
            normalized = normalized[1..];
        }
    }
    while (normalized.len > 0 and path.isSep(normalized[normalized.len - 1])) {
        normalized = normalized[0 .. normalized.len - 1];
    }
    return if (std.mem.eql(u8, normalized, ".")) "" else normalized;
}

test normalizeTarget {
    const t = std.testing;
    // already in the shape patterns are written in
    try t.expectEqualStrings("src", normalizeTarget("src"));
    try t.expectEqualStrings("src/main.zig", normalizeTarget("src/main.zig"));

    // the whole project, however it is spelled
    try t.expectEqualStrings("", normalizeTarget("."));
    try t.expectEqualStrings("", normalizeTarget("./"));
    try t.expectEqualStrings("", normalizeTarget(".//"));

    // redundant leading and trailing separators
    try t.expectEqualStrings("src", normalizeTarget("./src"));
    try t.expectEqualStrings("src", normalizeTarget("src/"));
    try t.expectEqualStrings("src", normalizeTarget("./src/"));
    try t.expectEqualStrings("src", normalizeTarget(".//./src//"));
    try t.expectEqualStrings("src/deep", normalizeTarget("./src/deep/"));

    // not a `./` prefix, so left alone
    try t.expectEqualStrings("..", normalizeTarget(".."));
    try t.expectEqualStrings("../sib", normalizeTarget("../sib"));
    try t.expectEqualStrings(".hidden", normalizeTarget(".hidden"));
    try t.expectEqualStrings("a/./b", normalizeTarget("a/./b"));

    // absolute paths are out of reach of root-anchored patterns either way
    try t.expectEqualStrings("/abs/src", normalizeTarget("/abs/src"));

    // degenerate
    try t.expectEqualStrings("", normalizeTarget(""));
}

test {
    _ = @import("test/lint_command_test.zig");
    std.testing.refAllDecls(lint_config);
    std.testing.refAllDecls(gitignore);
}
