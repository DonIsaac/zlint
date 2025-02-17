const std = @import("std");
const walk = @import("../walk/Walker.zig");
const _lint = @import("../lint.zig");
const _source = @import("../source.zig");
const reporters = @import("../reporter.zig");
const lint_config = @import("lint_config.zig");

const fs = std.fs;
const mem = std.mem;
const path = std.fs.path;

const Allocator = std.mem.Allocator;
const Source = _source.Source;
const Thread = std.Thread;
const WalkState = walk.WalkState;
const Error = @import("../Error.zig");

const LintService = _lint.LintService;
const Fix = _lint.Fix;
const Options = @import("../cli/Options.zig");

pub fn lint(alloc: Allocator, options: Options) !u8 {
    const stdout = std.io.getStdOut().writer();

    // NOTE: everything config related is stored in the same arena. This
    // includes the config source string, the parsed Config object, and
    // (eventually) whatever each rule needs to store. This lets all configs
    // store slices to the config's source, avoiding allocations.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    var reporter = try reporters.Reporter.initKind(options.format, stdout.any(), alloc);
    defer reporter.deinit();
    reporter.opts.quiet = options.quiet;
    reporter.opts.report_stats = reporter.opts.report_stats and options.summary;

    const config = resolve_config: {
        var errors: [1]Error = undefined;
        const c = lint_config.resolveLintConfig(&arena, fs.cwd(), "zlint.json", alloc, &errors[0]) catch {
            reporter.reportErrorSlice(alloc, errors[0..1]);
            return 1;
        };
        break :resolve_config c;
    };

    const start = std.time.milliTimestamp();

    {
        const fix = if (options.fix or options.fix_dangerously) Fix.Meta{
            .kind = .fix,
            .dangerous = options.fix_dangerously,
        } else Fix.Meta.disabled;

        // TODO: use options to specify number of threads (if provided)
        var service = try LintService.init(
            alloc,
            &reporter,
            config,
            .{ .fix = fix },
        );
        defer service.deinit();

        if (!options.stdin) {
            var visitor: LintVisitor = .{ .service = &service, .allocator = alloc };
            var src = try fs.cwd().openDir(".", .{ .iterate = true });
            defer src.close();
            var walker = try LintWalker.init(alloc, src, &visitor);
            defer walker.deinit();
            try walker.walk();
        } else {
            // SAFETY: initialized by reader
            var msg_buf: [4069]u8 = undefined;
            var stdin = std.io.getStdIn();
            // const did_lock = try stdin.tryLock(.shared);
            // defer if (did_lock) stdin.unlock();
            var buf_reader = std.io.bufferedReader(stdin.reader());
            var reader = buf_reader.reader();
            while (try reader.readUntilDelimiterOrEof(&msg_buf, '\n')) |filepath| {
                if (!std.mem.endsWith(u8, filepath, ".zig")) continue;
                const owned = try alloc.dupe(u8, filepath);
                try service.lintFileParallel(owned);
            }
        }
    }

    const stop = std.time.milliTimestamp();
    const duration = stop - start;
    reporter.printStats(duration);
    if (reporter.stats.numErrorsSync() > 0) {
        return 1;
    } else if (options.deny_warnings and reporter.stats.numWarningsSync() > 0) {
        return 1;
    } else {
        return 0;
    }
}

const LintWalker = walk.Walker(LintVisitor);

const LintVisitor = struct {
    /// borrowed
    service: *LintService,
    allocator: Allocator,

    pub fn visit(self: *LintVisitor, entry: walk.Entry) ?walk.WalkState {
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
                self.service.lintFileParallel(filepath) catch |e| {
                    std.log.err("Failed to spawn lint job on file '{s}': {any}\n", .{ filepath, e });
                    self.allocator.free(filepath);
                    return WalkState.Continue;
                };
            },
            else => {
                // todo: warn
            },
        }
        return WalkState.Continue;
    }
};
