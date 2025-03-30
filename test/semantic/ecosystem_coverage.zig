const test_runner = @import("../harness.zig");

const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const print = std.debug.print;

const zlint = @import("zlint");
const Source = zlint.Source;

const utils = @import("../utils.zig");
const Repo = utils.Repo;

const REPOS_DIR = "zig-out/repos";

// SAFETY: globalSetup is always run before this is read
var repos: std.json.Parsed([]Repo) = undefined;

const SemanticError = zlint.semantic.Semantic.Builder.SemanticError;
var is_tty: bool = false;

pub fn globalSetup(alloc: Allocator) !void {
    is_tty = std.io.getStdErr().isTty();
    var repos_dir_fd = fs.cwd().openDir(REPOS_DIR, .{}) catch |e| {
        switch (e) {
            error.FileNotFound => {
                print("Could not find git repos to test, please run `just submodules`", .{});
                return e;
            },
            else => return e,
        }
    };
    repos_dir_fd.close();
    repos = try Repo.load(alloc);
}

pub fn globalTeardown(_: Allocator) void {
    repos.deinit();
}

fn isTTY_() bool {
    return std.io.getStdErr().isTTY();
}

fn testSemantic(alloc: Allocator, source: *const Source) !void {
    {
        const p = source.pathname orelse "<missing>";
        print("ecosystem coverage: {s}", .{p});
        if (is_tty)
            print("                                                                                                                           \r", .{})
        else
            print("\n", .{});
    }
    var builder = zlint.semantic.Semantic.Builder.init(alloc);
    defer builder.deinit();
    var res = try builder.build(source.text());
    defer res.deinit();
    if (res.hasErrors()) return error.AnalysisFailed;
}

// const fns: test_runner.TestSuite.TestSuiteFns = .{
//     .test_fn = &testSemantic,
//     .setup_fn = &globalSetup,
//     .teardown_fn = &globalTeardown,
// };

pub fn run(alloc: Allocator) !void {
    for (repos.value) |repo| {
        const repo_dir = try utils.TestFolders.openRepo(alloc, repo.name);
        var suite = try test_runner.TestSuite.init(alloc, repo_dir, "semantic-coverage", repo.name, .{ .test_fn = &testSemantic });
        defer suite.deinit();

        try suite.run();
    }
}

pub const SUITE = test_runner.TestFile{
    .name = "semantic_coverage",
    .globalSetup = globalSetup,
    .deinit = globalTeardown,
    .run = run,
};
