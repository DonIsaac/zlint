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

    pub fn fromSpan(contents: string, span: Span) LocationSpan {
        const loc = Location.fromSpan(contents, span);
        return .{ .span = span, .location = loc };
    }
    pub inline fn start(self: LocationSpan) u32 {
        return self.span.start;
    }
    pub inline fn end(self: LocationSpan) u32 {
        return self.span.end;
    }
    pub inline fn line(self: LocationSpan) u32 {
        return self.location.line;
    }
    pub inline fn column(self: LocationSpan) u32 {
        return self.location.column;
    }
    pub inline fn source(self: LocationSpan) string {
        return self.location.source_line;
    }
};

pub const Span = struct {
    start: u32,
    end: u32,
};

pub const Location = struct {
    /// 1-based line number
    line: u32,
    /// 1-based column number
    column: u32,
    source_line: []const u8,

    pub fn fromSpan(contents: string, span: Span) Location {
        return findLineColumn(contents, @intCast(span.start));
    }
    // TODO: toSpan()
};

/// Copied/modified from std.zig.findLineColumn.
fn findLineColumn(source: []const u8, byte_offset: u32) Location {
    var line: u32 = 1;
    var column: u32 = 1;
    var line_start: u32 = 0;
    var i: u32 = 0;
    while (i < byte_offset) : (i += 1) {
        switch (source[i]) {
            '\n' => {
                line += 1;
                column = 1;
                line_start = i + 1;

                if (util.IS_WINDOWS and i < byte_offset and source[i + 1] == '\r') {
                    i += 1;
                }
            },
            else => {
                column += 1;
            },
        }
    }

    while (i < source.len and source[i] != '\n') {
        i += 1;
        if (util.IS_WINDOWS and i < source.len - 1 and source[i + 1] == '\r') {
            i += 1;
        }
    }

    return .{
        .line = line,
        .column = column,
        .source_line = source[line_start..i],
    };
}

test findLineColumn {
    const t = std.testing;
    const source =
        \\Foo bar
        \\baz
        \\bang
    ;

    {
        const foo_loc = findLineColumn(source, 0);
        try t.expectEqual(1, foo_loc.line);
        try t.expectEqual(1, foo_loc.column);
        try t.expectEqualStrings(foo_loc.source_line, "Foo bar");
    }

    {
        const baz_offset = 9;
        const baz_loc = findLineColumn(source, baz_offset);
        try t.expectEqual(2, baz_loc.line);
        try t.expectEqual(2, baz_loc.column);
        try t.expectEqualStrings(baz_loc.source_line, "baz");
    }
}
