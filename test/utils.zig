const std = @import("std");
const io = std.io;
const fs = std.fs;
const path = fs.path;
const process = std.process;

const Allocator = std.mem.Allocator;
const Child = process.Child;
const EnvMap = process.EnvMap;

const print = std.debug.print;

pub const string = []const u8;

pub const TestFolders = struct {
    /// List of ecosystem repositories. Used by several test suties.
    pub const REPOS_META_FILE = "test/repos.json";
    /// Folder where repositories in `REPOS_META_FILE` get cloned to
    pub const REPOS_DIR = "zig-out/repos";
    /// Parent folder where snapshots are stored. Use `openSnapshotFile` in
    /// tests to create a snapshot.
    pub const SNAPSHOTS_DIR = "test/snapshots";
    pub const FIXTURES_DIR = "test/fixtures";
    const SNAP_EXT = ".snap";

    pub fn globalInit() !void {
        try fs.cwd().makePath(SNAPSHOTS_DIR);
    }

    pub fn openFixtureDir(alloc: Allocator, path_segs: []const string) !fs.Dir {
        const fixture_dir = try path.join(alloc, &[_]string{ FIXTURES_DIR, path_segs });
        defer alloc.free(fixture_dir);
        return fs.cwd().openDir(fixture_dir, .{});
    }

    pub fn openSnapshotFile(alloc: Allocator, subpath: string, name: string) !fs.File {
        var snapshot_filename: string = "";
        var filename_needs_dealloc = false;

        if(!std.mem.endsWith(u8, name, SNAP_EXT)) {
            const with_ext = try std.mem.concat(alloc, u8, &[_]string {name, SNAP_EXT});
            filename_needs_dealloc = true;
            snapshot_filename = with_ext;
        } else {
            snapshot_filename = name;
        }


        // create suite subfolder if it doesn't exist yet
        const cwd = fs.cwd();
        {
            const snapshot_dir = try path.join(alloc, &[_]string{ SNAPSHOTS_DIR, subpath });
            defer alloc.free(snapshot_dir);
            try cwd.makePath(snapshot_dir);
        }

        const relative_path = try path.join(alloc, &[_]string{ SNAPSHOTS_DIR, subpath, snapshot_filename });
        defer alloc.free(relative_path);
        if (filename_needs_dealloc) {
            alloc.free(snapshot_filename);
        }

        return cwd.createFile(relative_path, .{});
    }

    pub fn openSnapshotDir(alloc: Allocator, path_segs: []const string) !fs.Dir {
        const snapshot_dir = try path.join(alloc, &[_]string{ SNAPSHOTS_DIR, path_segs });
        defer alloc.free(snapshot_dir);
        const cwd = fs.cwd();
        try cwd.makeDir(snapshot_dir, .{});
        return cwd.openDir(snapshot_dir, .{});
    }

    /// Opens a repository directory for iteration. Caller takes ownership of
    /// the opened folder.
    pub fn openRepo(alloc: Allocator, name: string) !fs.Dir {
        const repo_dir_relative = try path.join(alloc, &[_]string{ REPOS_DIR, name });
        defer alloc.free(repo_dir_relative);
        const repo_dir_absolute = try fs.cwd().realpathAlloc(alloc, repo_dir_relative);
        defer alloc.free(repo_dir_absolute);

        return fs.openDirAbsolute(repo_dir_absolute, .{ .iterate = true });
    }
};

pub const Repo = struct {
    /// Repository name, excluding org. This repository will be cloned into
    /// `REPOS_GIT_DIR/{name}`.
    name: []const u8,
    /// URL used to clone the repository
    repo_url: []const u8,
    /// Commit hash to checkout
    hash: []const u8,

    pub fn load(alloc: Allocator) !std.json.Parsed([]Repo) {
        const repos_raw = try std.fs.cwd().readFileAlloc(alloc, TestFolders.REPOS_META_FILE, 8192);
        defer alloc.free(repos_raw);
        return std.json.parseFromSlice([]Repo, alloc, repos_raw, .{ .allocate = .alloc_always });
    }
};

pub const CmdRunner = struct {
    alloc: Allocator,
    env_vars: std.process.EnvMap,

    pub fn init(alloc: Allocator) !CmdRunner {
        return CmdRunner{ .alloc = alloc, .env_vars = try process.getEnvMap(alloc) };
    }

    pub fn deinit(self: *CmdRunner) void {
        self.env_vars.deinit();
    }

    pub fn run(self: *CmdRunner, argv: []const string) !void {
        return self.runWithEnv(argv, &self.env_vars);
    }

    pub fn runIn(self: *CmdRunner, argv: []const string, pwd: string) !void {
        var env = EnvMap.init(self.alloc);
        defer env.deinit();
        try env.put("PWD", pwd);
        return self.runWithEnv(argv, &env);
    }

    fn runWithEnv(self: *CmdRunner, argv: []const string, env: ?*const EnvMap) !void {
        print("Running command: ", .{});
        for (argv) |arg| {
            print("{s} ", .{arg});
        }

        var child = Child.init(argv, self.alloc);
        child.env_map = env;
        child.stderr = io.getStdErr();
        child.stdout = io.getStdOut();
        try child.spawn();
        _ = try child.wait();
    }
};

/// ThreadPool seems to be adding a null byte at the end of ent.path in some
/// cases, which breaks openFile. TODO: open a bug report in Zig.
pub fn cleanStrSlice(slice: string) string {
    const sentinel = std.mem.indexOfScalar(u8, slice, 0);
    if (sentinel) |s|{
        return slice[0..s];
    } else {
        return slice;
    }
}
