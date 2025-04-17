const std = @import("std");
const ptrs = @import("smart-pointers");
const fs = std.fs;

const Allocator = std.mem.Allocator;
const Arc = ptrs.Arc;
const assert = std.debug.assert;

pub const ArcStr = Arc([:0]u8);

pub const Source = struct {
    // contents: Arc([]const u8),
    contents: ArcStr,
    pathname: ?[]const u8 = null,
    gpa: Allocator,

    /// Create a source from an opened file. This file must be opened with at least read permissions.
    ///
    /// Both `file` and `pathname` are moved into the source.
    pub fn init(gpa: Allocator, file: fs.File, pathname: ?[]const u8) !Source {
        defer file.close();
        const meta = try file.metadata();
        const contents = try gpa.allocSentinel(u8, meta.size(), 0);
        errdefer gpa.free(contents);
        const bytes_read = try file.readAll(contents);
        assert(bytes_read == meta.size());
        // const contents = try std.zig.readSourceFileToEndAlloc(gpa, file, meta.size());
        return Source{
            .contents = try ArcStr.init(gpa, contents),
            .pathname = pathname,
            .gpa = gpa,
        };
    }
    /// Create a source file directly from a string. Takes ownership of both
    /// `contents` and `pathname`.
    ///
    /// Primarily used for testing.
    pub fn fromString(gpa: Allocator, contents: [:0]u8, pathname: ?[]const u8) Allocator.Error!Source {
        const contents_arc = try ArcStr.init(gpa, contents);
        return Source{
            .contents = contents_arc,
            .pathname = pathname,
            .gpa = gpa,
        };
    }

    pub inline fn text(self: *const Source) [:0]const u8 {
        return self.contents.deref().*;
    }

    pub fn deinit(self: *Source) void {
        self.contents.deinit();
        if (self.pathname) |p| self.gpa.free(p);
        self.* = undefined;
    }
};
