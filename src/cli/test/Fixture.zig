const Fixture = @This();
const std = @import("std");
const path = std.fs.path;

const Dir = std.Io.Dir;
const Allocator = std.mem.Allocator;
const TmpDir = std.testing.TmpDir;

files: []File,
dir: TmpDir,

pub const File = struct {
    /// Relative path + file name
    /// `path/to/file.zig`
    path: []const u8,
    contents: []const u8,
};

pub fn new(io: std.Io, files: []File) !Fixture {
    var buffer: [256]u8 = undefined;
    const dir = std.testing.tmpDir(.{});
    for (files) |f| {
        try writeFixture(io, dir.dir, f, &buffer);
    }
    return .{ .dir = dir, .files = files };
}

fn writeFixture(io: std.Io, dir: Dir, fixture: Fixture.File, buf: []u8) !void {
    const subpath = path.dirname(fixture.path);
    if (subpath) |p| {
        try dir.createDirPath(io, p);
    }
    var file = try dir.createFile(io, subpath orelse "", .{ .truncate = true });
    defer file.close(io);
    var w = file.writer(io, buf);
    try w.interface.writeAll(fixture.contents);
    try w.flush();
}

pub fn deinit(self: *Fixture) void {
    self.dir.cleanup();
    self.* = undefined;
}
