const std = @import("std");
const Io = std.Io;
const path = std.fs.path;

const Allocator = std.mem.Allocator;

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

    pub fn globalInit(io: Io) !void {
        try Io.Dir.cwd().createDirPath(io, SNAPSHOTS_DIR);
    }

    pub fn openFixtureDir(alloc: Allocator, io: Io, path_segs: []const string) !Io.Dir {
        const fixture_dir = try path.join(alloc, &[_]string{ FIXTURES_DIR, path_segs });
        defer alloc.free(fixture_dir);
        return Io.Dir.cwd().openDir(io, fixture_dir, .{});
    }

    pub fn openSnapshotFile(alloc: Allocator, io: Io, subpath: string, name: string) !Io.File {
        var snapshot_filename: string = "";
        var filename_needs_dealloc = false;

        if (!std.mem.endsWith(u8, name, SNAP_EXT)) {
            const with_ext = try std.mem.concat(alloc, u8, &[_]string{ name, SNAP_EXT });
            filename_needs_dealloc = true;
            snapshot_filename = with_ext;
        } else {
            snapshot_filename = name;
        }

        // create suite subfolder if it doesn't exist yet
        const cwd = Io.Dir.cwd();
        {
            const snapshot_dir = try path.join(alloc, &[_]string{ SNAPSHOTS_DIR, subpath });
            defer alloc.free(snapshot_dir);
            try cwd.createDirPath(io, snapshot_dir);
        }

        const relative_path = try path.join(alloc, &[_]string{ SNAPSHOTS_DIR, subpath, snapshot_filename });
        defer alloc.free(relative_path);
        if (filename_needs_dealloc) {
            alloc.free(snapshot_filename);
        }

        return cwd.createFile(io, relative_path, .{});
    }

    pub fn openSnapshotDir(alloc: Allocator, io: Io, path_segs: []const string) !Io.Dir {
        const snapshot_dir = try path.join(alloc, &[_]string{ SNAPSHOTS_DIR, path_segs });
        defer alloc.free(snapshot_dir);
        const cwd = Io.Dir.cwd();
        try cwd.createDir(io, snapshot_dir, .default_dir);
        return cwd.openDir(io, snapshot_dir, .{});
    }

    /// Opens a repository directory for iteration. Caller takes ownership of
    /// the opened folder.
    pub fn openRepo(alloc: Allocator, io: Io, name: string) !Io.Dir {
        const repo_dir_relative = try path.join(alloc, &[_]string{ REPOS_DIR, name });
        defer alloc.free(repo_dir_relative);
        const repo_dir_absolute = try Io.Dir.cwd().realPathFileAlloc(io, repo_dir_relative, alloc);
        defer alloc.free(repo_dir_absolute);

        return Io.Dir.openDirAbsolute(io, repo_dir_absolute, .{ .iterate = true });
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

    pub fn load(alloc: Allocator, io: Io) !std.json.Parsed([]Repo) {
        const repos_raw = try Io.Dir.cwd().readFileAlloc(io, TestFolders.REPOS_META_FILE, alloc, .limited(8192));
        defer alloc.free(repos_raw);
        return std.json.parseFromSlice([]Repo, alloc, repos_raw, .{ .allocate = .alloc_always });
    }
};

/// ThreadPool seems to be adding a null byte at the end of ent.path in some
/// cases, which breaks openFile. TODO: open a bug report in Zig.
pub fn cleanStrSlice(slice: string) string {
    const sentinel = std.mem.indexOfScalar(u8, slice, 0);
    if (sentinel) |s| {
        return slice[0..s];
    } else {
        return slice;
    }
}
