const std = @import("std");
const util = @import("util");
const path = std.fs.path;
const json = std.json;
const mem = std.mem;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;
const Dir = Io.Dir;
const lint = @import("../lint.zig");
const Cow = util.Cow(false);
const Error = @import("../Error.zig");
const Span = @import("../span.zig").Span;

/// Resolve the lint configuration, walking up the directory tree from `cwd`
/// looking for `config_filename`.
///
/// On failure, this returns the original error and populates `err` with an
/// actionable diagnostic *when possible*. `err` is left `null` if no diagnostic
/// could be constructed (e.g. because allocating the diagnostic itself failed).
/// Callers must therefore initialize `err` to `null` and tolerate it staying
/// `null` on the error path.
pub fn resolveLintConfig(
    arena: *ArenaAllocator,
    io: Io,
    cwd: Dir,
    config_filename: [:0]const u8,
    err_alloc: Allocator,
    err: *?Error,
) !lint.Config.Managed {
    const arena_alloc = arena.allocator();

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
        const source = readToEndAlloc(file, io, arena_alloc, std.math.maxInt(u32)) catch |e| {
            err.* = ioDiagnostic(err_alloc, "Failed to read {s}: {s}", maybe_path_to_config, e);
            return e;
        };
        errdefer arena_alloc.free(source);

        var diagnostics: json.Diagnostics = .{};
        var scanner = json.Scanner.initCompleteInput(arena_alloc, source);
        defer scanner.deinit();
        scanner.enableDiagnostics(&diagnostics);
        // FIXME: i hate all these allocations, but they're needed b/c of how
        // errors work. That needs refactoring.
        const config = json.parseFromTokenSourceLeaky(
            lint.Config,
            arena_alloc,
            &scanner,
            .{ .ignore_unknown_fields = true },
        ) catch |e| {
            err.* = getReportForParseError(err_alloc, e, source, &diagnostics, maybe_path_to_config);
            return e;
        };
        var managed = config.intoManaged(arena, null);
        managed.path = try managed.arena.allocator().dupe(u8, maybe_path_to_config);
        return managed;
    }

    return lint.Config.DEFAULT.intoManaged(arena, null);
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

    const message = switch (e) {
        error.UnknownField => blk: {
            if (mem.lastIndexOfAny(u8, source[0..clamped_offset], &std.ascii.whitespace)) |start| {
                span.start = @intCast(start + 1);
            }
            const field = source[span.start..span.end];
            break :blk customRuleMessages.get(field) orelse "Unknown field";
        },
        error.UnexpectedToken => "Unexpected Token",
        else => |err| @errorName(err),
    };
    var err = Error{
        .message = Cow.initBorrowed(message),
        .code = "invalid-config",
    };
    errdefer err.deinit(alloc);

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

/// Try to read the contents of a `.gitignore` and add its entries to `config`'s
/// ignore list. if `config` doesn't have a path, looks for `.gitignore` within
/// `root`.
pub fn readGitignore(config: *lint.Config.Managed, io: Io, root: Dir) !void {
    const allocator = config.allocator();
    const dirname_: ?[]const u8 = if (config.path) |p| blk: {
        if (comptime util.IS_DEBUG) {
            std.debug.assert(mem.endsWith(u8, p, "zlint.json"));
            std.debug.assert(path.isAbsolute(p));
        }
        break :blk path.dirname(p);
    } else null;

    var gitignore_file = if (dirname_) |dirname| blk: {
        var stackfb = std.heap.stackFallback(512, allocator);
        const stackalloc = stackfb.get();
        const gitignore_path = try path.join(stackalloc, &[_][]const u8{ dirname, ".gitignore" });
        defer stackalloc.free(gitignore_path);
        break :blk Dir.openFileAbsolute(io, gitignore_path, .{ .mode = .read_only }) catch return;
    } else root: {
        break :root root.openFile(io, ".gitignore", .{ .mode = .read_only }) catch return;
    };
    defer gitignore_file.close(io);

    const gitignore = try readToEndAlloc(gitignore_file, io, allocator, std.math.maxInt(u32));
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
    var ignores = try std.ArrayListUnmanaged([]const u8).initCapacity(allocator, config.config.ignore.len + lines);
    ignores.appendSliceAssumeCapacity(config.config.ignore);
    while (it.next()) |line_| {
        const line = mem.trim(u8, line_, &std.ascii.whitespace);
        if (line.len == 0 or line[0] == '#') continue;
        ignores.appendAssumeCapacity(line);
    }
    config.config.ignore = ignores.items;
}

const t = std.testing;
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

    const expected_path = try path.resolve(t.allocator, &.{"zlint/test/fixtures/config/zlint.json"});
    defer t.allocator.free(expected_path);

    try t.expectStringEndsWith(config.path.?, expected_path);
    try t.expectEqual(.warning, config.config.rules.rules.unsafe_undefined.severity);
}

// Regression test for https://github.com/DonIsaac/zlint/issues/360: an empty
// zlint.json produced a label span past the end of the (empty) source, which
// caused a `u32` underflow panic when the graphical formatter rendered it.
test "resolveLintConfig with an empty zlint.json does not crash the formatter" {
    const GraphicalFormatter = @import("../reporter.zig").formatter.Graphical;

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
    try t.expectEqual(.empty, err.labels.items[0].span);

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
