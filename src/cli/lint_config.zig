const std = @import("std");
const util = @import("util");
const fs = std.fs;
const path = std.fs.path;
const json = std.json;
const mem = std.mem;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Dir = std.fs.Dir;
const lint = @import("../lint.zig");
const Cow = util.Cow(false);
const Error = @import("../Error.zig");
const Span = @import("../span.zig").Span;

pub fn resolveLintConfig(
    arena: *ArenaAllocator,
    cwd: Dir,
    config_filename: [:0]const u8,
    err_alloc: Allocator,
    err: *Error,
) !lint.Config.Managed {
    const arena_alloc = arena.allocator();

    var it = try ParentIterator(4096).fromDir(cwd, config_filename);
    while (it.next()) |maybe_path_to_config| {
        const file = fs.openFileAbsolute(maybe_path_to_config, .{ .mode = .read_only }) catch |e| {
            switch (e) {
                error.FileNotFound => continue,
                else => return e,
            }
        };
        defer file.close();
        const source = try file.readToEndAlloc(arena_alloc, std.math.maxInt(u32));
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
            err.* = getReportForParseError(err_alloc, e, source, &diagnostics);
            err.source_name = err_alloc.dupe(u8, maybe_path_to_config) catch @panic(err.message.borrow());
            return e;
        };
        var managed = config.intoManaged(arena, null);
        managed.path = try managed.arena.allocator().dupe(u8, maybe_path_to_config);
        return managed;
    }

    return lint.Config.DEFAULT.intoManaged(arena, null);
}

const ParentIterError = error{
    NotAbsolute,
} || Dir.RealPathError;
fn ParentIterator(comptime N: usize) type {
    return struct {
        // SAFETY: initialized during .init()
        buf: [N]u8 = undefined,
        filename: []const u8,
        last_slash: isize,
        const SLASH = if (util.IS_WINDOWS) '\\' else '/';
        const SLASH_STR = if (util.IS_WINDOWS) "\\" else "/";

        const Self = @This();
        pub fn fromDir(starting_dir: Dir, filename: []const u8) ParentIterError!Self {
            var self = Self{
                .filename = filename,
                .last_slash = 0,
            };

            const curr_path = try starting_dir.realpath(".", self.buf[0..]);
            try self.prepare(curr_path);

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

fn getReportForParseError(
    alloc: Allocator,
    e: json.ParseError(json.Scanner),
    source: []const u8,
    diagnostics: *const json.Diagnostics,
) Error {
    const offset: u32 = @truncate(diagnostics.getByteOffset());
    var span = Span.sized(offset -| 1, 1);

    const message = switch (e) {
        error.UnknownField => blk: {
            if (mem.lastIndexOfAny(u8, source[0..offset], &std.ascii.whitespace)) |start| {
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

    const own_source = alloc.dupeZ(u8, source) catch @panic(message);
    err.source = Error.ArcStr.init(alloc, own_source) catch @panic(message);
    err.labels.append(alloc, .{ .span = span }) catch @panic(message);
    return err;
}
const customRuleMessages = std.StaticStringMap([]const u8).initComptime([_]struct { []const u8, []const u8 }{
    .{ "\"no-undefined\"", "`no-undefined` has been renamed to `unsafe-undefined`." },
});

/// Try to read the contents of a `.gitignore` and add its entries to `config`'s
/// ignore list. if `config` doesn't have a path, looks for `.gitignore` within
/// `root`.
pub fn readGitignore(config: *lint.Config.Managed, root: fs.Dir) !void {
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
        break :blk fs.openFileAbsolute(gitignore_path, .{ .mode = .read_only }) catch return;
    } else root: {
        break :root root.openFile(".gitignore", .{ .mode = .read_only }) catch return;
    };
    defer gitignore_file.close();

    const gitignore = try gitignore_file.readToEndAlloc(allocator, std.math.maxInt(u32));
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
    const cwd = fs.cwd();

    const fixtures_dir = try cwd.realpathAlloc(t.allocator, "test/fixtures/config");
    defer t.allocator.free(fixtures_dir);

    var arena = ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    var err: Error = undefined;
    const config = try resolveLintConfig(
        &arena,
        try cwd.openDir(fixtures_dir, .{}),
        "zlint.json",
        t.allocator,
        &err,
    );
    try t.expect(config.path != null);

    const expected_path = try path.resolve(t.allocator, &.{"zlint/test/fixtures/config/zlint.json"});
    defer t.allocator.free(expected_path);

    try t.expectStringEndsWith(config.path.?, expected_path);
    try t.expectEqual(.warning, config.config.rules.rules.unsafe_undefined.severity);
}
