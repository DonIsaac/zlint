const std = @import("std");
const util = @import("util");
const fs = std.fs;

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const assert = std.debug.assert;
const string = util.string;

pub const Source = struct {
    contents: [:0]u8,
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
        const bytes_read = try file.readAll(contents);
        assert(bytes_read == meta.size());
        return Source{ .contents = contents, .file = file, .pathname = pathname, .gpa = gpa };
    }

    pub fn deinit(self: *Source) void {
        self.file.close();
        self.gpa.free(self.contents);
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
