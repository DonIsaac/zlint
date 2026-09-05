//! A throwaway project tree on disk, for tests that need to exercise file
//! discovery. Files are written into a temp dir that is deleted by `deinit`.
const Fixture = @This();
const std = @import("std");
const path = std.fs.path;

const Dir = std.Io.Dir;
const TmpDir = std.testing.TmpDir;

tmp: TmpDir,
io: std.Io,

pub const File = struct {
    /// Path relative to the fixture root, e.g. `src/main.zig`. Parent
    /// directories are created as needed.
    path: []const u8,
    contents: []const u8 = "",
};

pub fn new(io: std.Io, files: []const File) !Fixture {
    var self = Fixture{ .tmp = std.testing.tmpDir(.{ .iterate = true }), .io = io };
    errdefer self.tmp.cleanup();
    for (files) |f| try self.write(f);
    return self;
}

/// The project root. Iterable.
pub fn root(self: *const Fixture) Dir {
    return self.tmp.dir;
}

fn write(self: *Fixture, f: File) !void {
    var buf: [1024]u8 = undefined;
    if (path.dirname(f.path)) |parent| {
        try self.tmp.dir.createDirPath(self.io, parent);
    }
    var file = try self.tmp.dir.createFile(self.io, f.path, .{ .truncate = true });
    defer file.close(self.io);
    var w = file.writer(self.io, &buf);
    try w.interface.writeAll(f.contents);
    try w.flush();
}

pub fn deinit(self: *Fixture) void {
    self.tmp.cleanup();
    self.* = undefined;
}
