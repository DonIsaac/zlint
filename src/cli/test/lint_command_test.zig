//! Which files zlint picks up, from the user's point of view.
//!
//! Each test lays out a project in a tmpdir, runs `FileFilter` over it, and
//! asserts on the exact set of files selected. Nothing is parsed, so fixture
//! files can be empty.
//!
//! Assertions describe the behavior documented in
//! `apps/site/docs/configuration/ignore.md` and `zlint.schema.json`, *not*
//! whatever zlint happens to do today. Cases zlint doesn't satisfy yet are
//! wrapped in `todo()`.

const std = @import("std");
const Fixture = @import("Fixture.zig");
const walk = @import("../../io/Walker.zig");
const lint_command = @import("../lint_command.zig");
const lint_config = @import("../lint_config.zig");
const Config = @import("zlint").lint.Config;

const t = std.testing;
const Allocator = std.mem.Allocator;

/// A test scenario that needs fixing. Fails if the test passes.
fn todo(comptime why: []const u8, result: anyerror!void) !void {
    result catch |e| switch (e) {
        error.TestExpectedEqual => return error.SkipZigTest,
        // the fixture or the walk broke; that's a real failure, not a todo
        else => return e,
    };
    std.debug.print("\nthis passes now; drop the todo(): {s}\n", .{why});
    return error.TodoIsFixed;
}

/// A project on disk, plus how zlint was invoked in it.
const Project = struct {
    files: []const Fixture.File,
    /// The `ignore` array in `zlint.json`.
    ignore: []const []const u8 = &.{},
    /// Paths passed on the command line. Empty means "the whole project".
    args: []const []const u8 = &.{},
};

/// Assert that linting `project` lints exactly `expected` and nothing else.
/// Order doesn't matter; paths are relative to the project root.
fn expectLints(project: Project, expected: []const []const u8) !void {
    var fixture = try Fixture.new(t.io, project.files);
    defer fixture.deinit();

    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    // A project with a `.gitignore` is read the way a real run reads it.
    // `.nearest_from_root` walks *up* from the project root, and fixtures live
    // under the repo's own `.zig-cache`, so a fixture without one of its own
    // would silently inherit zlint's.
    var ignore = project.ignore;
    if (hasGitignore(project.files)) {
        var config = Config.DEFAULT.intoManaged(&arena, null);
        config.config.ignore = .new(project.ignore);
        try lint_config.readGitignore(&config, t.io, fixture.root(), .nearest_from_root);
        ignore = config.config.ignore.patterns;
    }

    const found = try collectLintTargets(
        t.allocator,
        t.io,
        fixture.root(),
        project.args,
        ignore,
    );
    defer {
        for (found) |f| t.allocator.free(f);
        t.allocator.free(found);
    }

    try expectSameFiles(expected, found);
}

fn hasGitignore(files: []const Fixture.File) bool {
    for (files) |f| if (std.mem.eql(u8, f.path, ".gitignore")) return true;
    return false;
}

/// Collects the files `lint` would send to the linter, instead of linting them.
const ListSink = struct {
    allocator: Allocator,
    files: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn accept(self: *ListSink, filepath: []u8) void {
        self.files.append(self.allocator, filepath) catch @panic("OOM");
    }
};

/// Every file `lint` would send to the linter if it were run from `root`, in
/// visit order. Paths are relative to `root`; the slice and its contents are
/// owned by `alloc`.
///
/// This is discovery without a `LintService`, stdout, or a process-wide cwd.
/// `lint` walks with the same `FileFilter`, so the two cannot disagree.
fn collectLintTargets(
    alloc: Allocator,
    io: std.Io,
    root: std.Io.Dir,
    include: []const []const u8,
    exclude: []const []const u8,
) ![][]u8 {
    const Filter = lint_command.FileFilter(ListSink);

    var sink = ListSink{ .allocator = alloc };
    errdefer {
        for (sink.files.items) |f| alloc.free(f);
        sink.files.deinit(alloc);
    }

    var visitor: Filter = .{
        .sink = &sink,
        .allocator = alloc,
        .include = .new(include),
        .exclude = .new(exclude),
    };
    var walker = try walk.Walker(Filter).init(alloc, io, root, &visitor);
    defer walker.deinit();
    try walker.walk();

    return sink.files.toOwnedSlice(alloc);
}

fn expectSameFiles(expected: []const []const u8, found: [][]u8) !void {
    // Walk order is filesystem-dependent, and paths are joined with the native
    // separator. Neither is a behavior worth pinning: `glob.match` treats `/`
    // and `\\` alike (see `isSeparator` in io/glob.zig), so patterns written
    // with `/` work on every platform.
    for (found) |f| std.mem.replaceScalar(u8, f, std.fs.path.sep, '/');
    std.mem.sort([]u8, found, {}, lessThan([]u8));

    const want = try t.allocator.dupe([]const u8, expected);
    defer t.allocator.free(want);
    std.mem.sort([]const u8, want, {}, lessThan([]const u8));

    same: {
        if (want.len != found.len) break :same;
        for (want, found) |w, f| {
            if (!std.mem.eql(u8, w, f)) break :same;
        }
        return;
    }

    std.debug.print("\nexpected these files to be linted:\n", .{});
    for (want) |f| std.debug.print("  {s}\n", .{f});
    std.debug.print("but zlint linted:\n", .{});
    for (found) |f| std.debug.print("  {s}\n", .{f});
    return error.TestExpectedEqual;
}

fn lessThan(comptime S: type) fn (void, S, S) bool {
    return struct {
        fn cmp(_: void, a: S, b: S) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.cmp;
}

// =============================================================================
// A project with no configuration
// =============================================================================

test "lints every zig file in the project" {
    try expectLints(.{ .files = &.{
        .{ .path = "build.zig" },
        .{ .path = "src/main.zig" },
        .{ .path = "src/nested/deep.zig" },
    } }, &.{ "build.zig", "src/main.zig", "src/nested/deep.zig" });
}

test "does not lint files that aren't zig source" {
    try expectLints(.{ .files = &.{
        .{ .path = "src/main.zig" },
        .{ .path = "build.zig.zon" },
        .{ .path = "README.md" },
        .{ .path = "LICENSE" },
    } }, &.{"src/main.zig"});
}

test "never lints vendor or zig-out" {
    try expectLints(.{ .files = &.{
        .{ .path = "src/main.zig" },
        .{ .path = "vendor/dep.zig" },
        .{ .path = "zig-out/bin/gen.zig" },
    } }, &.{"src/main.zig"});
}

test "never lints hidden directories" {
    try expectLints(.{ .files = &.{
        .{ .path = "src/main.zig" },
        .{ .path = ".zig-cache/o/tmp.zig" },
        .{ .path = ".git/hooks/thing.zig" },
    } }, &.{"src/main.zig"});
}

test "never lints a vendor directory nested inside the project" {
    try expectLints(.{ .files = &.{
        .{ .path = "src/main.zig" },
        .{ .path = "tools/vendor/dep.zig" },
    } }, &.{"src/main.zig"});
}

// =============================================================================
// `ignore` in zlint.json
// =============================================================================

test "ignore skips a directory named directly" {
    try expectLints(.{
        .files = &.{ .{ .path = "src/main.zig" }, .{ .path = "examples/demo.zig" } },
        .ignore = &.{"examples"},
    }, &.{"src/main.zig"});
}

// The example given in apps/site/docs/configuration/ignore.md.
test "ignore accepts glob patterns" {
    try expectLints(.{
        .files = &.{
            .{ .path = "src/main.zig" },
            .{ .path = "src/test/helper.zig" },
            .{ .path = "src/test/deep/other.zig" },
        },
        .ignore = &.{"src/test/**"},
    }, &.{"src/main.zig"});
}

test "ignore matches a file pattern at any depth" {
    try expectLints(.{
        .files = &.{
            .{ .path = "src/main.zig" },
            .{ .path = "src/proto.gen.zig" },
            .{ .path = "src/deep/other.gen.zig" },
        },
        .ignore = &.{"**/*.gen.zig"},
    }, &.{"src/main.zig"});
}

test "ignore matches a directory at any depth" {
    try expectLints(.{
        .files = &.{
            .{ .path = "src/main.zig" },
            .{ .path = "src/generated/proto.zig" },
            .{ .path = "lib/generated/other.zig" },
        },
        .ignore = &.{"**/generated"},
    }, &.{"src/main.zig"});
}

test "ignore does not skip sibling directories that share a prefix" {
    try expectLints(.{
        .files = &.{ .{ .path = "src/main.zig" }, .{ .path = "srcgen/tool.zig" } },
        .ignore = &.{"src"},
    }, &.{"srcgen/tool.zig"});
}

// =============================================================================
// .gitignore
//
// "ZLint respects .gitignore files by default; no files ignored by git will be
// linted." Entries are appended to `ignore` verbatim and then matched as globs,
// so these tests really ask whether gitignore syntax survives that trip.
// =============================================================================

test "respects a plain directory name in gitignore" {
    try expectLints(.{ .files = &.{
        .{ .path = ".gitignore", .contents = "build\n" },
        .{ .path = "src/main.zig" },
        .{ .path = "build/gen.zig" },
    } }, &.{"src/main.zig"});
}

test "ignores comments and blank lines in gitignore" {
    try expectLints(.{ .files = &.{
        .{ .path = ".gitignore", .contents = "# a comment\n\n   \nbuild\n" },
        .{ .path = "src/main.zig" },
        .{ .path = "build/gen.zig" },
    } }, &.{"src/main.zig"});
}

test "respects gitignore directory entries written with a trailing slash" {
    try expectLints(.{ .files = &.{
        .{ .path = ".gitignore", .contents = "build/\n" },
        .{ .path = "src/main.zig" },
        .{ .path = "build/gen.zig" },
    } }, &.{"src/main.zig"});
}

test "respects gitignore patterns at any depth" {
    try expectLints(.{ .files = &.{
        .{ .path = ".gitignore", .contents = "*.gen.zig\n" },
        .{ .path = "src/main.zig" },
        .{ .path = "root.gen.zig" },
        .{ .path = "src/deep/proto.gen.zig" },
    } }, &.{"src/main.zig"});
}

test "respects gitignore entries for a directory nested in the project" {
    try expectLints(.{ .files = &.{
        .{ .path = ".gitignore", .contents = "node_modules\n" },
        .{ .path = "src/main.zig" },
        .{ .path = "node_modules/a.zig" },
        .{ .path = "tools/node_modules/b.zig" },
    } }, &.{"src/main.zig"});
}

test "respects root-anchored gitignore entries" {
    try todo(
        "a leading `/` anchors a gitignore pattern to the project root; zlint " ++
            "matches it literally, so it never matches anything",
        expectLints(.{ .files = &.{
            .{ .path = ".gitignore", .contents = "/dist\n" },
            .{ .path = "src/main.zig" },
            .{ .path = "dist/out.zig" },
            .{ .path = "src/dist/keep.zig" },
        } }, &.{ "src/dist/keep.zig", "src/main.zig" }),
    );
}

// =============================================================================
// Paths passed on the command line
// =============================================================================

test "lints only the file named on the command line" {
    try expectLints(.{
        .files = &.{ .{ .path = "src/main.zig" }, .{ .path = "src/other.zig" } },
        .args = &.{"src/main.zig"},
    }, &.{"src/main.zig"});
}

test "lints a directory named on the command line" {
    try todo(
        "`zlint src` matches nothing: command-line paths are matched as globs, " ++
            "and `src` does not match `src/main.zig`",
        expectLints(.{
            .files = &.{
                .{ .path = "src/main.zig" },
                .{ .path = "src/deep/other.zig" },
                .{ .path = "test/helper.zig" },
            },
            .args = &.{"src"},
        }, &.{ "src/deep/other.zig", "src/main.zig" }),
    );
}

test "lints a file named with a leading ./" {
    try todo(
        "walk paths carry no `./` prefix, so `./src/main.zig` never matches",
        expectLints(.{
            .files = &.{ .{ .path = "src/main.zig" }, .{ .path = "src/other.zig" } },
            .args = &.{"./src/main.zig"},
        }, &.{"src/main.zig"}),
    );
}

test "lints a file named on the command line even when it is ignored" {
    try todo(
        "naming a file explicitly should override `ignore` (or report that it " ++
            "was skipped); today it is dropped silently and zlint exits 0",
        expectLints(.{
            .files = &.{ .{ .path = "src/main.zig" }, .{ .path = "generated/proto.zig" } },
            .ignore = &.{"generated"},
            .args = &.{"generated/proto.zig"},
        }, &.{"generated/proto.zig"}),
    );
}
