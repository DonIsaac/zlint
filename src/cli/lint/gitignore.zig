pub const Search = enum {
    /// Beside the config file, which marks the project root.
    beside_config,
    /// Nearest `.gitignore` at or above `root`.
    nearest_from_root,
};

const Spliterator = struct {
    iter: mem.SplitIterator(u8, .scalar),

    fn init(str: []const u8) Spliterator {
        return .{ .iter = mem.splitScalar(u8, str, '\n') };
    }

    pub fn next(self: *Spliterator) ?[]const u8 {
        while (self.iter.next()) |line_| {
            const line = util.trimWhitespace(line_);
            if (line.len == 0 or line[0] == '#') continue;
            return line;
        }
        return null;
    }
};

/// Try to open a `.gitignore` file within `dirname`. Returns `null` if the file doesn't
/// exist or otherwise fails to open.
fn tryOpen(allocator: Allocator, io: std.Io, root: Dir, dirname_: ?[]const u8) Allocator.Error!?std.Io.File {
    if (dirname_) |dirname| {
        var stackfb = std.heap.stackFallback(512, allocator);
        const stackalloc = stackfb.get();
        const gitignore_path = try path.join(stackalloc, &[_][]const u8{ dirname, ".gitignore" });
        defer stackalloc.free(gitignore_path);
        return Dir.openFileAbsolute(io, gitignore_path, .{ .mode = .read_only }) catch return null;
    }

    var it = ParentIterator(4096).fromDir(io, root, ".gitignore") catch return null;
    while (it.next()) |candidate| {
        return Dir.openFileAbsolute(io, candidate, .{ .mode = .read_only }) catch continue;
    }
    return null;
}

/// Try to read the contents of a `.gitignore` and add its entries to `config`'s
/// ignore list.
///
/// A config discovered by walking up from `root` marks the project root, so
/// `.beside_config` applies. An explicit `--config` path carries no such
/// meaning, so callers pass `.nearest_from_root`.
pub fn readGitignore(config: *lint.Config.Managed, io: std.Io, root: Dir, search: Search) !void {
    const allocator = config.allocator();
    const dirname_: ?[]const u8 = switch (search) {
        .nearest_from_root => null,
        .beside_config => if (config.path) |p| blk: {
            // NOTE: the filename is arbitrary; `--config` accepts any path.
            util.debugAssert(path.isAbsolute(p), "config path is not absolute", .{});
            break :blk path.dirname(p);
        } else null,
    };

    var gitignore_file = try tryOpen(allocator, io, root, dirname_) orelse return;
    defer gitignore_file.close(io);

    const gitignore = try fs.readToEndAlloc(gitignore_file, io, allocator, std.math.maxInt(u32), 128);
    errdefer allocator.free(gitignore);
    var it = Spliterator.init(gitignore);

    // count lines to pre-allocate enough memory
    var lines: u32 = 0;
    while (it.next()) |_| lines += 1;
    if (lines == 0) return;
    it.iter.reset();

    // merge existing + new ignores. Each line can expand to two globs.
    var ignores = try std.ArrayListUnmanaged([]const u8).initCapacity(allocator, config.config.ignore.patterns.len + (lines * 2));
    ignores.appendSliceAssumeCapacity(config.config.ignore.patterns);
    while (it.next()) |line| {
        try gitignoreLineToGlobs(allocator, line, &ignores);
    }
    config.config.ignore = .new(ignores.items);
}

/// Rewrite one `.gitignore` line as the glob patterns that reproduce it, and
/// append them to `out`.
///
/// `ignore` is a plain glob matcher, so the gitignore-specific rules have to be
/// spelled out in the pattern itself: an unanchored name applies at any depth
/// (`**/` prefix), and naming a folder excludes what's inside it (a `/**` form
/// alongside the name). `line` must already be trimmed and non-empty.
fn gitignoreLineToGlobs(
    allocator: Allocator,
    line: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var body = line;

    const negated = body[0] == '!';
    if (negated) body = body[1..];

    // a trailing `/` means the entry only ever names a folder
    const dirs_only = body.len > 0 and body[body.len - 1] == '/';
    if (dirs_only) body = mem.trimEnd(u8, body, "/");

    // a leading `/` anchors to the project root; so does an interior `/`
    const rooted = body.len > 0 and body[0] == '/';
    if (rooted) body = mem.trimStart(u8, body, "/");
    const anchored = rooted or mem.indexOfScalar(u8, body, '/') != null;

    // `!`, `/` and `//` carry no pattern
    if (body.len == 0) return;

    const prefix = if (negated) "!" else "";
    const depth = if (anchored) "" else "**/";

    if (!dirs_only) {
        try out.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, depth, body }));
    }
    try out.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}{s}/**", .{ prefix, depth, body }));
}

const t = std.testing;

test gitignoreLineToGlobs {
    const cases = [_]struct { line: []const u8, want: []const []const u8 }{
        .{ .line = "build", .want = &.{ "**/build", "**/build/**" } },
        .{ .line = "build/", .want = &.{"**/build/**"} },
        .{ .line = "/dist", .want = &.{ "dist", "dist/**" } },
        .{ .line = "/dist/", .want = &.{"dist/**"} },
        .{ .line = "src/test", .want = &.{ "src/test", "src/test/**" } },
        .{ .line = "*.gen.zig", .want = &.{ "**/*.gen.zig", "**/*.gen.zig/**" } },
        .{ .line = "!keep.zig", .want = &.{ "!**/keep.zig", "!**/keep.zig/**" } },
        .{ .line = "!lib/", .want = &.{"!**/lib/**"} },
        // nothing to match
        .{ .line = "/", .want = &.{} },
        .{ .line = "!", .want = &.{} },
    };

    for (cases) |case| {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        defer {
            for (out.items) |g| t.allocator.free(g);
            out.deinit(t.allocator);
        }
        try gitignoreLineToGlobs(t.allocator, case.line, &out);

        t.expectEqual(case.want.len, out.items.len) catch |e| {
            std.debug.print("`{s}` produced:\n", .{case.line});
            for (out.items) |g| std.debug.print("  {s}\n", .{g});
            return e;
        };
        for (case.want, out.items) |want, got| try t.expectEqualStrings(want, got);
    }
}
test {
    _ = @import("gitignore_test.zig");
}

const std = @import("std");
const util = @import("util");
const zlint = @import("zlint");
const fs = @import("../../io/fs.zig");
const ParentIterator = @import("../../io/parent_iterator.zig").ParentIterator;

const Allocator = std.mem.Allocator;
const mem = std.mem;
const path = std.fs.path;
const lint = zlint.lint;
const Dir = std.Io.Dir;
