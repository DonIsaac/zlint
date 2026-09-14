const std = @import("std");
const util = @import("util");

const Dir = std.Io.Dir;
const mem = std.mem;
const path = std.fs.path;
const assert = std.debug.assert;

pub const ParentIterError = error{
    NotAbsolute,
} || Dir.RealPathFileError;

/// Path-only iteration up a directory tree.
///
/// This iterator yields absolute paths to some possible file starting from within
/// a target directory.
///
/// `ParentIterator` requires an absolute starting path and does not perform
/// path normalization. Iteration does not check for directory or file
/// existence, and all memory is buffer allocated.
///
/// Providing paths that exceed buffer capacity is checked illegal behavior.
///
/// ## Storing Paths
/// `ParentIterator` reuses the same buffer for each iteration. Storing and using
/// paths after the next iteration or past the iterators lifetime is illegal behavior - you must copy them to
/// more permanent storage.
///
/// ```zig
/// const it = try ParentIterator(256).init("/foo/bar", "target.txt");
/// const first = it.next().?; // -> "/foo/bar/target.txt"
/// // `first` may not be used again. Clone it for storage purposes.
/// const second = it.next().? // -> "/foo/target.txt"
/// const stored = try allocator.dupe(u8, second);
/// ```
pub fn ParentIterator(comptime N: usize) type {
    comptime {
        assert(N > 0); // Space is required to store paths
        assert(N < std.math.maxInt(isize)); // last_slash is an isize
    }

    return struct {
        buf: [N]u8,
        filename: []const u8,
        last_slash: isize,
        const SLASH_STR = &[_]u8{path.sep};

        const Self = @This();

        /// Create an iterator that starts walk up from `Dir`'s path.
        ///
        /// Since this walk is path-only, `Dir` does not need to be opened with
        /// iteration enabled.
        pub fn fromDir(io: std.Io, starting_dir: Dir, filename: []const u8) ParentIterError!Self {
            var self = Self{
                .filename = filename,
                .last_slash = 0,
                // SAFETY: initialized in prepare
                .buf = undefined,
            };

            const curr_path_len = try starting_dir.realPathFile(io, ".", self.buf[0..]);
            try self.prepare(self.buf[0..curr_path_len]);

            return self;
        }

        /// Create an iterator from a nonempty, absolute starting path.
        pub fn init(starting_dir: []const u8, filename: []const u8) ParentIterError!Self {
            if (starting_dir.len == 0) return ParentIterError.BadPathName;
            if (starting_dir.len > N) return ParentIterError.NameTooLong;

            var self = Self{
                .filename = filename,
                .last_slash = @intCast(starting_dir.len),
                // SAFETY: initialized below
                .buf = undefined,
            };
            @memcpy(self.buf[0..starting_dir.len], starting_dir);

            // strip trailing slash
            const curr_path = if (starting_dir[starting_dir.len - 1] == path.sep)
                starting_dir[0 .. starting_dir.len - 1]
            else
                starting_dir;

            try self.prepare(curr_path);
            return self;
        }

        fn prepare(self: *Self, curr_path: []const u8) ParentIterError!void {
            const sentinel = [_]u8{ path.sep, 0 };
            if (!path.isAbsolute(curr_path)) return ParentIterError.NotAbsolute;
            if (N - curr_path.len < sentinel.len + self.filename.len) return ParentIterError.NameTooLong;

            // "/foo/bar" slice => "/foo/bar/" sentinel
            self.buf[curr_path.len] = sentinel[0];
            self.buf[curr_path.len + 1] = sentinel[1];
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

const t = std.testing;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expectStringEndsWith = std.testing.expectStringEndsWith;

test ParentIterator {
    const Iter = ParentIterator(4096);

    if (util.IS_WINDOWS) {
        var it = try Iter.init("C:\\foo\\bar\\baz", "zlint.json");
        try expectEqualStrings("C:\\foo\\bar\\baz\\zlint.json", it.next().?);
        try expectEqualStrings("C:\\foo\\bar\\zlint.json", it.next().?);
        try expectEqualStrings("C:\\foo\\zlint.json", it.next().?);
        try expectEqualStrings("C:\\zlint.json", it.next().?);
        try expectEqual(null, it.next());
    } else {
        var it = try Iter.init("/foo/bar/baz", "zlint.json");
        try expectEqualStrings("/foo/bar/baz/zlint.json", it.next().?);
        try expectEqualStrings("/foo/bar/zlint.json", it.next().?);
        try expectEqualStrings("/foo/zlint.json", it.next().?);
        try expectEqualStrings("/zlint.json", it.next().?);
        try expectEqual(null, it.next());
    }

    // starting dirs may not be empty
    try expectError(
        error.BadPathName,
        ParentIterator(16).init("", "foo.txt"),
    );
}

test "trailing slashes have no effect" {
    const Iter = ParentIterator(128);
    if (util.IS_WINDOWS) {
        var it = try Iter.init("C:\\foo\\", "zlint.json");
        try t.expectEqualStrings("C:\\foo\\zlint.json", it.next().?);
    } else {
        var it = try Iter.init("/foo/", "zlint.json");
        try t.expectEqualStrings("/foo/zlint.json", it.next() orelse return error.TestExpectedEqual);
    }
}

test "Overly long paths" {
    const Iter = ParentIterator(4);
    const start = if (util.IS_WINDOWS) "C:\\foo\\bar\\baz" else "/foo/bar/baz";
    try expectError(error.NameTooLong, Iter.init(start, "foo.txt"));
}

test "ParentIterator.fromDir" {
    const io = std.testing.io;
    const Iter = ParentIterator(512);

    const starting_path = if (comptime util.IS_WINDOWS) "foo\\bar\\baz" else "foo/bar/baz";
    const target_file_name = "target.txt";
    var tmpdir = std.testing.tmpDir(.{});
    defer tmpdir.cleanup();

    try tmpdir.dir.createDirPath(io, starting_path);
    const starting_dir = try tmpdir.dir.openDir(io, starting_path, .{});

    var iter = try Iter.fromDir(io, starting_dir, target_file_name);

    if (comptime util.IS_WINDOWS) {
        try expectStringEndsWith(iter.next() orelse return error.ExpectedNextPath, "foo\\bar\\baz\\target.txt");
        try expectStringEndsWith(iter.next() orelse return error.ExpectedNextPath, "foo\\bar\\target.txt");
    } else {
        try expectStringEndsWith(iter.next() orelse return error.ExpectedNextPath, "foo/bar/baz/target.txt");
        try expectStringEndsWith(iter.next() orelse return error.ExpectedNextPath, "foo/bar/target.txt");
    }
}
