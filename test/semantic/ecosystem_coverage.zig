const std = @import("std");
const fs = std.fs;
const path = fs.path;
const process = std.process;
const Allocator = std.mem.Allocator;
const print = std.debug.print;

const zlint = @import("zlint");
const Source = zlint.Source;

const TestSuite = @import("../TestSuite.zig");
const utils = @import("../utils.zig");
const string = utils.string;
const Repo = utils.Repo;

// const AccessorError = fs.Acce
const REPOS_META_FILE = "test/repos.json";
const REPOS_DIR = "zig-out/repos";

pub fn globalSetup(_: Allocator) !void {
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
}

pub fn run(alloc: Allocator) !void {
    var repos = try Repo.load(alloc);
    defer repos.deinit();
    for (repos.value) |repo| {
        const repo_dir = try utils.TestFolders.openRepo(alloc, repo.name);
        var suite = try TestSuite.init(alloc, repo_dir, "semantic-coverage", repo.name, &testSemantic);
        defer suite.deinit();

        try suite.run();
    }
}

fn testSemantic(alloc: Allocator, source: *const Source) !void {
    var res = try zlint.semantic.Builder.build(alloc, source.contents);
    defer res.deinit();
    if (res.hasErrors()) return SemanticError.analysis_failed;
}

const SemanticError = error{
    analysis_failed,
};

// const TestSuite = struct {
//     repo: Repo,
//     /// Root directory of the repository being tested
//     dir: fs.Dir,
//     walker: fs.Dir.Walker,
//     snapshot: fs.File,
//     alloc: Allocator,

//     fn init(alloc: Allocator, repo: Repo) !TestSuite {
//         const dir = try utils.TestFolders.openRepo(repo.name);
//         const snapshot = try utils.TestFolders.openSnapshotFile(alloc, "semantic", "ecosystem_coverage.snap");
//         const walker = try dir.walk(alloc);
//         return TestSuite{ .repo = repo, .dir = dir, .walker = walker, .snapshot = snapshot, .alloc = alloc };
//     }

//     fn deinit(self: *TestSuite) void {
//         self.dir.close();
//         self.snapshot.close();
//         self.walker.deinit();
//     }

//     fn run(self: *TestSuite) !void {
//         while (try self.walker.next()) |ent| {
//             if (ent.kind != .file) continue;
//             if (!std.mem.endsWith(u8, ent.path, ".zig")) continue;

//             print("{s}\n", .{ent.path});
//             const file = try self.dir.openFile(ent.path, .{});
//             var source = try zlint.Source.init(self.alloc, file);
//             defer source.deinit();
//             var result = try zlint.semantic.Builder.build(self.alloc, source.contents);
//             // const file = try dir.readFileAlloc(alloc, ent.path, std.math.maxInt(usize));
//             // defer alloc.free(file);

//             // const result = try zlint.semantic.Builder.build(alloc, file);
//             // defer result.deinit();
//             // print("{any}\n", .{result});
//             // // try fs.op
//         }
//     }
//     fn testFile(self: *TestSuite, source: *const zlint.Source) !void {
//         var result = try zlint.semantic.Builder.build(self.alloc, source.contents);
//         self.snapshot.seek
//     }

//     const Stats = struct {
//         pass: usize,
//         fail: usize,
//         error_lines: []string,

//         inline fn total(self: *Stats) usize {
//             return self.pass + self.fail;
//         }
//     };
// };

// fn runOnDir(alloc: Allocator, repo: *const Repo, dir: fs.Dir) !void {
//     var walker = try dir.walk(alloc);
//     defer walker.deinit();
//     while (try walker.next()) |ent| {
//         if (ent.kind != .file) continue;
//         if (!std.mem.endsWith(u8, ent.path, ".zig")) continue;

//         print("{s}\n", .{ent.path});
//         const file = try dir.openFile(ent.path, .{});
//         var source = try zlint.Source.init(alloc, file);
//         defer source.deinit();
//         var result = try zlint.semantic.Builder.build(alloc, source.contents);
//         // const file = try dir.readFileAlloc(alloc, ent.path, std.math.maxInt(usize));
//         // defer alloc.free(file);

//         // const result = try zlint.semantic.Builder.build(alloc, file);
//         // defer result.deinit();
//         // print("{any}\n", .{result});
//         // // try fs.op
//     }
// }

// const Repo = struct {
//     /// Repository name, excluding org. This repository will be cloned into
//     /// `REPOS_GIT_DIR/{name}`.
//     name: []const u8,
//     /// URL used to clone the repository
//     repo_url: []const u8,
//     /// Commit hash to checkout
//     hash: []const u8,

//     fn load(alloc: Allocator) !std.json.Parsed([]Repo) {
//         const repos_raw = try std.fs.cwd().readFileAlloc(alloc, REPOS_META_FILE, 8192);
//         defer alloc.free(repos_raw);
//         return std.json.parseFromSlice([]Repo, alloc, repos_raw, .{ .allocate = .alloc_always });
//     }
// };
