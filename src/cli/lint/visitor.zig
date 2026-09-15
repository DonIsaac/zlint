const std = @import("std");
const util = @import("util");
const glob = @import("zlint").glob;
const walk = @import("../../io/Walker.zig");

const mem = std.mem;
const path = std.fs.path;
const Allocator = std.mem.Allocator;

/// Decides which files in a directory tree get linted, and hands each one to
/// `sink`, which takes ownership of the path.
///
/// `Sink` must expose `fn accept(*Sink, []u8) void`.
pub fn FileFilter(comptime Sink: type) type {
    return struct {
        /// borrowed
        sink: *Sink,
        allocator: Allocator,
        /// `ignore` from `zlint.json`, plus whatever `.gitignore` contributed.
        exclude: glob.GlobSet,

        const Self = @This();

        pub fn visit(self: *Self, entry: walk.Entry) ?walk.WalkState {
            switch (entry.kind) {
                .directory => {
                    if (entry.basename.len == 0 or entry.basename[0] == '.') {
                        return .Skip;
                    } else if (isIgnoredByDefault(&entry)) {
                        return .Skip;
                    }
                    if (self.exclude.matchesPrunableDirectory(entry.path)) {
                        return .Skip;
                    }
                },
                .file => {
                    if (!mem.eql(u8, path.extension(entry.path), ".zig") or
                        !self.isIncluded(&entry))
                    {
                        return .Continue;
                    }

                    const filepath = self.allocator.dupe(u8, entry.path) catch {
                        return .Stop;
                    };
                    self.sink.accept(filepath);
                },
                else => {
                    // todo: warn
                },
            }
            return .Continue;
        }

        const always_ignored = [_][]const u8{ "vendor", "zig-out", "zig-pkg" };
        fn isIgnoredByDefault(entry: *const walk.Entry) bool {
            inline for (always_ignored) |ignored_dir| {
                if (mem.eql(u8, ignored_dir, entry.basename)) {
                    @branchHint(.unlikely);
                    return true;
                }
            }
            return false;
        }

        fn isIncluded(self: *const Self, entry: *const walk.Entry) bool {
            util.debugAssert(
                entry.kind != .directory,
                "isIncluded should only be passed file-like things, got a dir.",
                .{},
            );

            if (self.exclude.patterns.len > 0) {
                if (self.exclude.matches(entry.path)) {
                    @branchHint(.unlikely);
                    return false;
                }
            }

            return true;
        }
    };
}
