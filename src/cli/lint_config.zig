const std = @import("std");
const util = @import("util");
const path = std.fs.path;
const json = std.json;
const mem = std.mem;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;
const Dir = Io.Dir;
const lint = @import("zlint").lint;
const Cow = util.Cow(false);
const Error = @import("zlint").Error;
const Span = @import("zlint").span.Span;

/// Load the lint configuration. When `config_path` is given, that file is used
/// directly and no directory walking happens. Otherwise, `zlint.json` is
/// resolved by walking up the directory tree from `cwd`.
pub fn getLintConfig(
    arena: *ArenaAllocator,
    io: Io,
    config_path: ?[]const u8,
    err_alloc: Allocator,
    err: *?Error,
) !lint.Config.Managed {
    const cwd = Io.Dir.cwd();
    if (config_path) |config| {
        const config_file = cwd.openFile(io, config, .{ .mode = .read_only }) catch |e| {
            err.* = ioDiagnostic(err_alloc, "Failed to open {s}: {s}", config, e);
            return e;
        };
        defer config_file.close(io);

        // Downstream consumers (e.g. `readGitignore`) expect an absolute path.
        const abs_path = cwd.realPathFileAlloc(io, config, arena.allocator()) catch |e| {
            err.* = ioDiagnostic(err_alloc, "Failed to resolve {s}: {s}", config, e);
            return e;
        };

        return parseConfigFile(arena, io, err_alloc, abs_path, config_file, err);
    }

    return resolveLintConfig(arena, io, cwd, "zlint.json", err_alloc, err);
}

/// Resolve the lint configuration, walking up the directory tree from `cwd`
/// looking for `config_filename`.
///
/// On failure, this returns the original error and populates `err` with an
/// actionable diagnostic *when possible*. `err` is left `null` if no diagnostic
/// could be constructed (e.g. because allocating the diagnostic itself failed).
/// Callers must therefore initialize `err` to `null` and tolerate it staying
/// `null` on the error path.
fn resolveLintConfig(
    arena: *ArenaAllocator,
    io: Io,
    cwd: Dir,
    config_filename: [:0]const u8,
    err_alloc: Allocator,
    err: *?Error,
) !lint.Config.Managed {
    var it = ParentIterator(4096).fromDir(io, cwd, config_filename) catch |e| {
        err.* = ioDiagnostic(err_alloc, "Failed to search for config file {s}: {s}", config_filename, e);
        return e;
    };
    while (it.next()) |maybe_path_to_config| {
        const file = Dir.openFileAbsolute(io, maybe_path_to_config, .{ .mode = .read_only }) catch |e| {
            switch (e) {
                error.FileNotFound => continue,
                else => {
                    err.* = ioDiagnostic(err_alloc, "Failed to open {s}: {s}", maybe_path_to_config, e);
                    return e;
                },
            }
        };
        defer file.close(io);

        return parseConfigFile(arena, io, err_alloc, maybe_path_to_config, file, err);
    }

    return lint.Config.default.intoManaged(arena, null);
}

/// Parse a zlint.json's contents into a config. All passed data are borrowed.
fn parseConfigFile(
    arena: *ArenaAllocator,
    io: Io,
    err_alloc: Allocator,
    config_path: []const u8,
    config_file: std.Io.File,
    err: *?Error,
) !lint.Config.Managed {
    const arena_alloc = arena.allocator();

    const source = readToEndAlloc(config_file, io, arena_alloc, std.math.maxInt(u32)) catch |e| {
        err.* = ioDiagnostic(err_alloc, "Failed to read {s}: {s}", config_path, e);
        return e;
    };
    errdefer arena_alloc.free(source);

    var diagnostics: json.Diagnostics = .{};
    var scanner = json.Scanner.initCompleteInput(arena_alloc, source);
    defer scanner.deinit();
    scanner.enableDiagnostics(&diagnostics);
    // FIXME: i hate all these allocations, but they're needed b/c of how
    // errors work. That needs refactoring.
    var config = json.parseFromTokenSourceLeaky(
        lint.Config.File,
        arena_alloc,
        &scanner,
        .{ .ignore_unknown_fields = true },
    ) catch |e| {
        err.* = getReportForParseError(err_alloc, e, source, &diagnostics, config_path);
        return e;
    };
    return config.resolve().intoManaged(arena, try arena_alloc.dupe(u8, config_path));
}

/// Build an actionable diagnostic for a config IO failure, e.g.
/// `Failed to read /home/user/zlint.json: AccessDenied`. Returns `null` if the
/// diagnostic itself could not be allocated.
fn ioDiagnostic(
    alloc: Allocator,
    comptime template: []const u8,
    subject: []const u8,
    e: anyerror,
) ?Error {
    var err = Error.fmt(alloc, template, .{ subject, @errorName(e) }) catch return null;
    err.code = "invalid-config";
    return err;
}

/// Read the remaining contents of `file`, up to `max_bytes`. Replaces
/// `std.fs.File.readToEndAlloc` from Zig <= 0.15.
fn readToEndAlloc(file: Io.File, io: Io, allocator: Allocator, max_bytes: usize) ![]u8 {
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(allocator, .limited(max_bytes)) catch |e| switch (e) {
        error.ReadFailed => return reader.err orelse error.InputOutput,
        else => |other| return other,
    };
}

const ParentIterError = error{
    NotAbsolute,
} || Dir.RealPathFileError;
fn ParentIterator(comptime N: usize) type {
    return struct {
        // SAFETY: initialized during .init()
        buf: [N]u8 = undefined,
        filename: []const u8,
        last_slash: isize,
        const SLASH = if (util.IS_WINDOWS) '\\' else '/';
        const SLASH_STR = if (util.IS_WINDOWS) "\\" else "/";

        const Self = @This();
        pub fn fromDir(io: Io, starting_dir: Dir, filename: []const u8) ParentIterError!Self {
            var self = Self{
                .filename = filename,
                .last_slash = 0,
            };

            const curr_path_len = try starting_dir.realPathFile(io, ".", self.buf[0..]);
            try self.prepare(self.buf[0..curr_path_len]);

            return self;
        }

        pub fn init(starting_dir: []const u8, filename: []const u8) ParentIterError!Self {
            std.debug.assert(starting_dir.len > 0);
            var self = Self{
                .filename = filename,
                .last_slash = @intCast(starting_dir.len),
            };
            @memcpy(self.buf[0..starting_dir.len], starting_dir);

            // strip trailing slash
            const curr_path = if (starting_dir[starting_dir.len - 1] == SLASH)
                starting_dir[0 .. starting_dir.len - 1]
            else
                starting_dir;

            try self.prepare(curr_path);
            return self;
        }

        fn prepare(self: *Self, curr_path: []const u8) ParentIterError!void {
            // Windows paths start with C:\ or some other drive letter
            if (comptime !util.IS_WINDOWS) if (curr_path[0] != SLASH) return ParentIterError.NotAbsolute;
            if (N - curr_path.len < 2 + self.filename.len) return ParentIterError.NameTooLong;

            // "/foo/bar" slice => "/foo/bar/" sentinel
            self.buf[curr_path.len] = SLASH;
            self.buf[curr_path.len + 1] = 0;
            self.last_slash = @intCast(curr_path.len);
        }

        pub fn next(self: *Self) ?[]const u8 {
            if (self.last_slash < 0) return null;
            const slash: usize = @intCast(self.last_slash);
            const filename_len = self.filename.len;

            defer if (mem.lastIndexOf(u8, self.buf[0..slash], SLASH_STR)) |prev_slash| {
                self.last_slash = @intCast(prev_slash);
            } else {
                self.last_slash = -1;
            };

            @memcpy(self.buf[slash + 1 ..][0..filename_len], self.filename);
            const next_path = self.buf[0 .. slash + 1 + filename_len];
            return next_path;
        }
    };
}

/// Build a diagnostic describing a config parse failure. Returns `null` if any
/// allocation required to build the diagnostic fails, so the caller can fall
/// back to a safe static message rather than crashing.
fn getReportForParseError(
    alloc: Allocator,
    e: json.ParseError(json.Scanner),
    source: []const u8,
    diagnostics: *const json.Diagnostics,
    source_name: []const u8,
) ?Error {
    return buildReportForParseError(alloc, e, source, diagnostics, source_name) catch null;
}

fn buildReportForParseError(
    alloc: Allocator,
    e: json.ParseError(json.Scanner),
    source: []const u8,
    diagnostics: *const json.Diagnostics,
    source_name: []const u8,
) Allocator.Error!Error {
    const offset: u32 = @truncate(diagnostics.getByteOffset());
    const src_len: u32 = @intCast(source.len);
    const clamped_offset = @min(offset, src_len);
    var span = Span.sized(clamped_offset -| 1, 1);
    span.end = @min(span.end, src_len);

    var suggestion: ?[]const u8 = null;
    const message = switch (e) {
        error.UnknownField => blk: {
            if (unknownFieldSpan(source, clamped_offset)) |field_span| span = field_span;
            const field = source[span.start..span.end];
            if (customRuleMessages.get(field)) |custom| break :blk custom;
            suggestion = closestRuleName(mem.trim(u8, field, "\""));
            break :blk "Unknown field";
        },
        error.UnexpectedToken => "Unexpected Token",
        else => |err| @errorName(err),
    };
    var err = Error{
        .message = Cow.initBorrowed(message),
        .code = "invalid-config",
    };
    errdefer err.deinit(alloc);
    if (suggestion) |name| {
        err.help = try Cow.fmt(alloc, "Did you mean `{s}`?", .{name});
    }

    {
        const own_source = try alloc.dupeZ(u8, source);
        errdefer alloc.free(own_source);
        err.source = try Error.ArcStr.init(alloc, own_source);
    }
    err.source_name = try alloc.dupe(u8, source_name);
    try err.labels.append(alloc, .{ .span = span });
    return err;
}
const customRuleMessages = std.StaticStringMap([]const u8).initComptime([_]struct { []const u8, []const u8 }{
    .{ "\"no-undefined\"", "`no-undefined` has been renamed to `unsafe-undefined`." },
});

pub const GitignoreSearch = enum {
    /// Beside the config file, which marks the project root.
    beside_config,
    /// Nearest `.gitignore` at or above `root`.
    nearest_from_root,
};

/// Span of the quoted key that triggered `error.UnknownField`, quotes included.
/// `offset` points just past that key, so walk back over its two quotes.
fn unknownFieldSpan(source: []const u8, offset: u32) ?Span {
    const close = mem.lastIndexOfScalar(u8, source[0..offset], '"') orelse return null;
    const open = mem.lastIndexOfScalar(u8, source[0..close], '"') orelse return null;
    return Span{ .start = @intCast(open), .end = @intCast(close + 1) };
}

const rule_names: []const []const u8 = names: {
    const fields = @typeInfo(lint.Config.RulesConfig.Rules).@"struct".fields;
    var names: [fields.len][]const u8 = undefined;
    for (fields, &names) |field, *name| name.* = field.type.name;
    const final = names;
    break :names &final;
};

/// The registered rule whose name is closest to `field`, or `null` if none are
/// close enough to be worth suggesting.
fn closestRuleName(field: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_distance: usize = max_edit_distance + 1;
    for (rule_names) |name| {
        const distance = editDistance(field, name) orelse continue;
        if (distance < best_distance) {
            best_distance = distance;
            best = name;
        }
    }
    return best;
}

const max_edit_distance = 3;
const max_rule_name_len = 64;

/// Levenshtein distance between `a` and `b`, or `null` if it exceeds
/// `max_edit_distance` (or either input is too long to bother with).
fn editDistance(a: []const u8, b: []const u8) ?usize {
    if (a.len > max_rule_name_len or b.len > max_rule_name_len) return null;
    if (a.len -| b.len > max_edit_distance or b.len -| a.len > max_edit_distance) return null;

    var prev: [max_rule_name_len + 1]usize = undefined;
    var curr: [max_rule_name_len + 1]usize = undefined;
    for (0..b.len + 1) |i| prev[i] = i;

    for (a, 1..) |a_char, i| {
        curr[0] = i;
        for (b, 1..) |b_char, j| {
            const substitution = prev[j - 1] + @intFromBool(a_char != b_char);
            curr[j] = @min(substitution, @min(prev[j], curr[j - 1]) + 1);
        }
        @memcpy(prev[0 .. b.len + 1], curr[0 .. b.len + 1]);
    }

    return if (prev[b.len] <= max_edit_distance) prev[b.len] else null;
}

/// Try to read the contents of a `.gitignore` and add its entries to `config`'s
/// ignore list.
///
/// A config discovered by walking up from `root` marks the project root, so
/// `.beside_config` applies. An explicit `--config` path carries no such
/// meaning, so callers pass `.nearest_from_root`.
pub fn readGitignore(config: *lint.Config.Managed, io: Io, root: Dir, search: GitignoreSearch) !void {
    const allocator = config.allocator();
    const dirname_: ?[]const u8 = switch (search) {
        .nearest_from_root => null,
        .beside_config => if (config.path) |p| blk: {
            // NOTE: the filename is arbitrary; `--config` accepts any path.
            if (comptime util.IS_DEBUG) std.debug.assert(path.isAbsolute(p));
            break :blk path.dirname(p);
        } else null,
    };

    var gitignore_file = if (dirname_) |dirname| blk: {
        var stackfb = std.heap.stackFallback(512, allocator);
        const stackalloc = stackfb.get();
        const gitignore_path = try path.join(stackalloc, &[_][]const u8{ dirname, ".gitignore" });
        defer stackalloc.free(gitignore_path);
        break :blk Dir.openFileAbsolute(io, gitignore_path, .{ .mode = .read_only }) catch return;
    } else root: {
        var it = ParentIterator(4096).fromDir(io, root, ".gitignore") catch return;
        while (it.next()) |candidate| {
            break :root Dir.openFileAbsolute(io, candidate, .{ .mode = .read_only }) catch continue;
        }
        return;
    };
    defer gitignore_file.close(io);

    const gitignore = try readToEndAlloc(gitignore_file, io, allocator, std.math.maxInt(u32));
    errdefer allocator.free(gitignore);
    var it = mem.splitScalar(u8, gitignore, '\n');

    // count lines to pre-allocate enough memory
    var lines: u32 = 0;
    while (it.next()) |line_| {
        // const line = mem.trim(u8, line_, &std.ascii.whitespace);
        const line = util.trimWhitespace(line_);
        if (line.len == 0 or line[0] == '#') continue;
        lines += 1;
    }

    if (lines == 0) return;
    it.reset();

    // merge existing + new ignores
    var ignores = try std.ArrayListUnmanaged([]const u8).initCapacity(allocator, config.config.ignore.patterns.len + lines);
    ignores.appendSliceAssumeCapacity(config.config.ignore.patterns);
    while (it.next()) |line_| {
        const line = mem.trim(u8, line_, &std.ascii.whitespace);
        if (line.len == 0 or line[0] == '#') continue;
        ignores.appendAssumeCapacity(line);
    }
    config.config.ignore = .new(ignores.items);
}

const t = std.testing;

test closestRuleName {
    try t.expectEqualStrings("unsafe-undefined", closestRuleName("unsafe-undefned").?);
    try t.expectEqualStrings("homeless-try", closestRuleName("homeless-try").?);
    try t.expectEqualStrings("no-print", closestRuleName("no-prints").?);
    // exact matches never reach this path, but shouldn't misbehave if they do
    try t.expectEqualStrings("empty-file", closestRuleName("empty-file").?);
    // too far from anything to be a useful guess
    try t.expectEqual(null, closestRuleName("zzzzzzzzzzzz"));
    try t.expectEqual(null, closestRuleName(""));
}

test unknownFieldSpan {
    // `offset` points just past the offending key, as json.Diagnostics reports it
    const compact =
        \\{"rules":{"no-undefined":"allow"}}
    ;
    const span = unknownFieldSpan(compact, 24).?;
    try t.expectEqualStrings("\"no-undefined\"", compact[span.start..span.end]);

    try t.expectEqual(null, unknownFieldSpan("{}", 2));
}

test ParentIterator {
    if (util.IS_WINDOWS) {
        var it = try ParentIterator(4096).init("C:\\foo\\bar\\baz", "zlint.json");
        try t.expectEqualStrings("C:\\foo\\bar\\baz\\zlint.json", it.next().?);
        try t.expectEqualStrings("C:\\foo\\bar\\zlint.json", it.next().?);
        try t.expectEqualStrings("C:\\foo\\zlint.json", it.next().?);
        try t.expectEqualStrings("C:\\zlint.json", it.next().?);
        try t.expectEqual(null, it.next());
    } else {
        var it = try ParentIterator(4096).init("/foo/bar/baz", "zlint.json");
        try t.expectEqualStrings("/foo/bar/baz/zlint.json", it.next().?);
        try t.expectEqualStrings("/foo/bar/zlint.json", it.next().?);
        try t.expectEqualStrings("/foo/zlint.json", it.next().?);
        try t.expectEqualStrings("/zlint.json", it.next().?);
        try t.expectEqual(null, it.next());
    }
}

test resolveLintConfig {
    const cwd = Dir.cwd();

    const fixtures_dir = try cwd.realPathFileAlloc(t.io, "test/fixtures/config", t.allocator);
    defer t.allocator.free(fixtures_dir);

    var arena = ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    var err: ?Error = null;
    defer if (err) |*e| e.deinit(t.allocator);
    const config = try resolveLintConfig(
        &arena,
        t.io,
        try cwd.openDir(t.io, fixtures_dir, .{}),
        "zlint.json",
        t.allocator,
        &err,
    );
    try t.expect(err == null);
    try t.expect(config.path != null);

    const expected_path = try path.join(t.allocator, &.{ fixtures_dir, "zlint.json" });
    defer t.allocator.free(expected_path);

    try t.expectEqualStrings(expected_path, config.path.?);
    try t.expectEqual(.warning, config.config.rules.rules.unsafe_undefined.severity);
}

// Regression test for https://github.com/DonIsaac/zlint/issues/358: a zlint.json
// containing an `ignore` key panicked while parsing the glob set.
test "resolveLintConfig parses ignore globs" {
    const cwd = Dir.cwd();

    const fixtures_dir = try cwd.realPathFileAlloc(t.io, "test/fixtures/config-ignore", t.allocator);
    defer t.allocator.free(fixtures_dir);

    var arena = ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    var err: ?Error = null;
    defer if (err) |*e| e.deinit(t.allocator);
    const config = try resolveLintConfig(
        &arena,
        t.io,
        try cwd.openDir(t.io, fixtures_dir, .{}),
        "zlint.json",
        t.allocator,
        &err,
    );
    try t.expect(err == null);

    const ignore = config.config.ignore;
    try t.expectEqual(2, ignore.patterns.len);
    try t.expectEqualStrings("foo/**", ignore.patterns[0]);
    try t.expectEqualStrings("bar/*.zig", ignore.patterns[1]);
    try t.expect(ignore.matches("foo/bar.zig"));
    try t.expect(!ignore.matches("src/foo.zig"));

    // keys following `ignore` are still parsed
    try t.expectEqual(.warning, config.config.rules.rules.unsafe_undefined.severity);
}

// Regression test for https://github.com/DonIsaac/zlint/issues/360: an empty
// zlint.json produced a label span past the end of the (empty) source, which
// caused a `u32` underflow panic when the graphical formatter rendered it.
test "resolveLintConfig with an empty zlint.json does not crash the formatter" {
    const GraphicalFormatter = @import("zlint").report.formatter.Graphical;

    const cwd = Dir.cwd();
    const fixtures_dir = try cwd.realPathFileAlloc(t.io, "test/fixtures/config-empty", t.allocator);
    defer t.allocator.free(fixtures_dir);

    var arena = ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    var maybe_err: ?Error = null;
    try t.expectError(error.UnexpectedEndOfInput, resolveLintConfig(
        &arena,
        t.io,
        try cwd.openDir(t.io, fixtures_dir, .{}),
        "zlint.json",
        t.allocator,
        &maybe_err,
    ));
    try t.expect(maybe_err != null);
    var err = maybe_err.?;
    defer err.deinit(t.allocator);

    try t.expectEqual(0, err.source.?.deref().*.len);
    try t.expectEqual(1, err.labels.items.len);
    try t.expectEqual(Span.empty, err.labels.items[0].span);

    var fmt = GraphicalFormatter.unicode(t.allocator, false);
    var w = std.Io.Writer.Allocating.init(t.allocator);
    defer w.deinit();
    try fmt.format(&w.writer, err);
}

// Config IO failures (open/read errors) should surface an actionable
// diagnostic that names both the offending path and the underlying OS error.
test "config IO failures produce actionable diagnostics" {
    var read_err = ioDiagnostic(t.allocator, "Failed to read {s}: {s}", "/home/user/zlint.json", error.AccessDenied).?;
    defer read_err.deinit(t.allocator);
    try t.expectEqualStrings("Failed to read /home/user/zlint.json: AccessDenied", read_err.message.borrow());
    try t.expectEqualStrings("invalid-config", read_err.code);

    var open_err = ioDiagnostic(t.allocator, "Failed to open {s}: {s}", "/home/user/zlint.json", error.IsDir).?;
    defer open_err.deinit(t.allocator);
    try t.expectEqualStrings("Failed to open /home/user/zlint.json: IsDir", open_err.message.borrow());
    try t.expectEqualStrings("invalid-config", open_err.code);
}

test "getLintConfig with an explicit path loads that file" {
    var arena = ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    var err: ?Error = null;
    defer if (err) |*e| e.deinit(t.allocator);

    const config_path = "test/fixtures/config/zlint.json";
    const config = try getLintConfig(&arena, t.io, config_path, t.allocator, &err);
    try t.expect(err == null);
    try t.expect(path.isAbsolute(config.path.?));

    const expected_suffix = try path.join(t.allocator, &.{ "test", "fixtures", "config", "zlint.json" });
    defer t.allocator.free(expected_suffix);
    try t.expect(mem.endsWith(u8, config.path.?, expected_suffix));
    try t.expectEqual(.warning, config.config.rules.rules.unsafe_undefined.severity);
}

// An explicit path bypasses directory walking entirely, so the file doesn't
// need to be named `zlint.json` and doesn't need to be in an ancestor of cwd.
test "getLintConfig with an explicit path does not walk the directory tree" {
    var arena = ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    var err: ?Error = null;
    defer if (err) |*e| e.deinit(t.allocator);

    const config_path = "test/fixtures/config/custom.json";
    var config = try getLintConfig(&arena, t.io, config_path, t.allocator, &err);
    try t.expect(err == null);

    const expected_suffix = try path.join(t.allocator, &.{ "test", "fixtures", "config", "custom.json" });
    defer t.allocator.free(expected_suffix);
    try t.expect(mem.endsWith(u8, config.path.?, expected_suffix));

    // An explicit config says nothing about where the project is, so ignores
    // come from the nearest .gitignore at or above cwd (here, the repo root's)
    // rather than the one beside the config file.
    try readGitignore(&config, t.io, Dir.cwd(), .nearest_from_root);
    try expectIgnores(config, "zig-out");
    try t.expectEqual(.err, config.config.rules.rules.unsafe_undefined.severity);
    try t.expectEqual(.warning, config.config.rules.rules.homeless_try.severity);
}

fn expectIgnores(config: lint.Config.Managed, expected: []const u8) !void {
    for (config.config.ignore.patterns) |ignored| {
        if (mem.eql(u8, ignored, expected)) return;
    }
    std.debug.print("expected ignore list to contain '{s}'\n", .{expected});
    return error.TestExpectedIgnoreEntry;
}

// A discovered config marks the project root, so its sibling .gitignore is used
// and cwd's is not consulted. `test/fixtures/config` has no .gitignore, and the
// config omits `ignore`, so the resolved defaults must come back untouched.
test "readGitignore does not fall back to cwd for a discovered config" {
    const cwd = Dir.cwd();

    var arena = ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    var err: ?Error = null;
    defer if (err) |*e| e.deinit(t.allocator);

    var config = try resolveLintConfig(
        &arena,
        t.io,
        try cwd.openDir(t.io, "test/fixtures/config", .{}),
        "zlint.json",
        t.allocator,
        &err,
    );
    try t.expect(err == null);

    try readGitignore(&config, t.io, cwd, .beside_config);
    try t.expectEqualDeep(lint.Config.default.ignore.patterns, config.config.ignore.patterns);
}

test "getLintConfig falls back to resolution when no path is given" {
    var arena = ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    var err: ?Error = null;
    defer if (err) |*e| e.deinit(t.allocator);

    const config = try getLintConfig(&arena, t.io, null, t.allocator, &err);
    try t.expect(err == null);
    if (config.path) |p| try t.expect(mem.endsWith(u8, p, "zlint.json"));
}

test "getLintConfig reports a missing explicit config file" {
    var arena = ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    var maybe_err: ?Error = null;
    try t.expectError(error.FileNotFound, getLintConfig(
        &arena,
        t.io,
        "test/fixtures/config/does-not-exist.json",
        t.allocator,
        &maybe_err,
    ));

    var err = maybe_err.?;
    defer err.deinit(t.allocator);
    try t.expectEqualStrings(
        "Failed to open test/fixtures/config/does-not-exist.json: FileNotFound",
        err.message.borrow(),
    );
    try t.expectEqualStrings("invalid-config", err.code);
}

test "getLintConfig reports parse errors in an explicit config file" {
    var arena = ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    var maybe_err: ?Error = null;
    try t.expectError(error.UnexpectedEndOfInput, getLintConfig(
        &arena,
        t.io,
        "test/fixtures/config-empty/zlint.json",
        t.allocator,
        &maybe_err,
    ));

    var err = maybe_err.?;
    defer err.deinit(t.allocator);
    try t.expectEqualStrings("invalid-config", err.code);

    const expected_suffix = try path.join(t.allocator, &.{ "config-empty", "zlint.json" });
    defer t.allocator.free(expected_suffix);
    try t.expect(mem.endsWith(u8, err.source_name.?, expected_suffix));
}
