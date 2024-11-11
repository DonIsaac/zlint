const std = @import("std");
const util = @import("util");
const ptrs = @import("smart-pointers");
const fs = std.fs;

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Arc = ptrs.Arc;
const assert = std.debug.assert;
const string = util.string;

const ArcStr = Arc([:0]u8);

pub const Source = struct {
    // contents: Arc([]const u8),
    contents: ArcStr,
    file: fs.File,
    pathname: ?string = null,
    ast: ?Ast = null,
    gpa: Allocator,

    /// Create a source from an opened file. This file must be opened with at least read permissions.
    ///
    /// Both `file` and `pathname` are moved into the source.
    pub fn init(gpa: Allocator, file: fs.File, pathname: ?string) !Source {
        const meta = try file.metadata();
        const contents = try gpa.allocSentinel(u8, meta.size(), 0);
        errdefer gpa.free(contents);
        const bytes_read = try file.readAll(contents);
        assert(bytes_read == meta.size());
        return Source{
            .contents = try ArcStr.init(gpa, contents),
            .file = file,
            .pathname = pathname,
            .gpa = gpa,
        };
    }

    pub inline fn text(self: *const Source) [:0]const u8 {
        return self.contents.deref().*;
    }

    pub fn deinit(self: *Source) void {
        self.file.close();
        self.contents.deinit();
        if (self.ast != null) {
            self.ast.?.deinit(self.gpa);
        }
        if (self.pathname != null) {
            self.gpa.free(self.pathname.?);
        }
        self.* = undefined;
    }
};

pub const LocationSpan = struct {
    span: Span,
    location: Location,
};
pub const Span = struct {
    start: u32,
    end: u32,
};

pub const Location = struct {
    line: u32,
    column: u32,

    pub fn fromSpan(contents: string, span: Span) Location {
        const l = std.zig.findLineColumn(contents, @intCast(span.start));
        return Location{
            .line = l.line,
            .column = l.column,
        };
    }
    // TODO: toSpan()
};
