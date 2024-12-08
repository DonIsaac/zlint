const std = @import("std");
const fs = std.fs;
const path = std.fs.path;
const json = std.json;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Dir = std.fs.Dir;
const lint = @import("../linter.zig");

pub fn resolveLintConfig(
    arena: ArenaAllocator,
    cwd: Dir,
    config_filename: [:0]const u8,
) !lint.Config.Managed {
    var _arena = arena;
    const alloc = _arena.allocator();

    var it = try ParentIterator(4096).fromDir(cwd, config_filename);
    while (it.next()) |maybe_path_to_config| {
        const file = fs.openFileAbsolute(maybe_path_to_config, .{ .mode = .read_only }) catch |err| {
            switch (err) {
                error.FileNotFound => continue,
                else => return err,
            }
        };
        defer file.close();
        const source = try file.readToEndAlloc(alloc, std.math.maxInt(u32));
        errdefer alloc.free(source);
        var scanner = json.Scanner.initCompleteInput(alloc, source);
        defer scanner.deinit();
        const config = try json.parseFromTokenSourceLeaky(lint.Config, alloc, &scanner, .{});
        return config.intoManaged(arena);
    }
    return lint.Config.DEFAULT.intoManaged(arena);
}

const ParentIterError = error{
    NotAbsolute,
} || Dir.RealPathError;
fn ParentIterator(comptime N: usize) type {
    return struct {
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
            if (curr_path[0] != SLASH) return ParentIterError.NotAbsolute;
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

            defer if (std.mem.lastIndexOf(u8, self.buf[0..slash], SLASH_STR)) |prev_slash| {
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
test ParentIterator {
    var it = try ParentIterator(4096).init("/foo/bar/baz", "zlint.json");
    try t.expectEqualStrings("/foo/bar/baz/zlint.json", it.next().?);
    try t.expectEqualStrings("/foo/bar/zlint.json", it.next().?);
    try t.expectEqualStrings("/foo/zlint.json", it.next().?);
    try t.expectEqualStrings("/zlint.json", it.next().?);
    try t.expectEqual(null, it.next());
}

const util = @import("util");
test resolveLintConfig {
    const cwd = fs.cwd();

    const fixtures_dir = if (util.IS_WINDOWS)
        try cwd.realpathAlloc(t.allocator, "test\\fixtures\\config")
    else
        try cwd.realpathAlloc(t.allocator, "test/fixtures/config");
    defer t.allocator.free(fixtures_dir);

    const arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const config = try resolveLintConfig(arena, cwd, "zlint.json");
    try t.expectEqual(.warning, config.config.rules.no_undefined.severity);
}

// fn iterParents(comptime N: usize, buf: [N]u8, path: []const u8, filename: []const u8) {

//     var buf = buffer;
//     const curr_path = try cwd.realpath(".", buf[0..]);
//     std.debug.assert(buf[0] == '/');
//     if (buf.len - curr_path.len < 2 + config_filename.len) return Dir.RealPathError.NameTooLong;
//     // "/foo/bar" slice => "/foo/bar/" sentinel
//     buf[curr_path.len] = '/';
//     buf[curr_path.len + 1] = 0;

//     // FIXME: this is likely buggy as hell.
//     var last_slash = curr_path.len;
//     while (last_slash > 0) : ({
//         last_slash = std.mem.lastIndexOf(u8, buf[0..last_slash], "/") orelse return null;
//     }) {
//         @memcpy(buf[last_slash + 1 ..][0..config_filename.len], config_filename);
//         // "/foo/bar/zlint.json"
//         const slice: [*:0]const u8 = @ptrCast(buf[0 .. last_slash + 1 + config_filename.len]);
//         const file = fs.openFileAbsoluteZ(slice, .{ .mode = .read_only }) catch |err| {
//             switch (err) {
//                 error.FileNotFound => continue,
//                 else => return err,
//             }
//         };
//         return file;
//     }

//     return null;
// }
