const std = @import("std");
const util = @import("util");

const assert = std.debug.assert;

const t = std.testing;

pub const LocationSpan = struct {
    span: LabeledSpan,
    location: Location,

    pub fn fromSpan(contents: []const u8, span: anytype) LocationSpan {
        const labeled_span: LabeledSpan, const loc: Location = brk: {
            switch (@TypeOf(span)) {
                Span => {
                    const labeled = .{ .span = span };
                    break :brk .{ labeled, Location.fromSpan(contents, span) };
                },
                LabeledSpan => {
                    break :brk .{ span, Location.fromSpan(contents, span.span) };
                },
                else => @panic("`span` must be a Span or LabeledSpan"),
            }
        };
        return .{ .span = labeled_span, .location = loc };
    }

    pub inline fn start(self: LocationSpan) u32 {
        return self.span.span.start;
    }
    pub inline fn end(self: LocationSpan) u32 {
        return self.span.span.end;
    }
    pub inline fn line(self: LocationSpan) u32 {
        return self.location.line;
    }
    pub inline fn column(self: LocationSpan) u32 {
        return self.location.column;
    }
    pub inline fn source(self: LocationSpan) []const u8 {
        return self.location.source_line;
    }
};

pub const Span = struct {
    start: u32,
    end: u32,

    pub const EMPTY = Span{ .start = 0, .end = 0 };

    pub inline fn new(start: u32, end: u32) Span {
        assert(end >= start);
        return .{ .start = start, .end = end };
    }

    pub inline fn sized(start: u32, size: u32) Span {
        return .{ .start = start, .end = start + size };
    }

    pub fn from(value: anytype) Span {
        return switch (@TypeOf(value)) {
            Span => value, // base case
            LabeledSpan => value.span,
            std.zig.Ast.Span => .{ .start = value.start, .end = value.end },
            std.zig.Token.Loc => .{ .start = @intCast(value.start), .end = @intCast(value.end) },
            [2]u32 => .{ .start = value[0], .end = value[1] },
            else => |T| {
                const info = @typeInfo(T);
                switch (info) {
                    .@"struct", .@"enum" => {
                        if (@hasField(T, "span")) {
                            return Span.from(@field(value, "span"));
                        }
                    },
                    else => {},
                }
                @compileError("Cannot convert type " ++ @typeName(T) ++ "into a Span.");
            },
        };
    }

    pub inline fn len(self: Span) u32 {
        assert(self.end >= self.start);
        return self.end - self.start;
    }

    pub inline fn snippet(self: Span, contents: []const u8) []const u8 {
        assert(self.end >= self.start);
        return contents[self.start..self.end];
    }

    /// Translate a span towards the end of the file by `offset` characters.
    /// Opposite of `shiftLeft`.
    ///
    /// ## Example
    /// ```zig
    /// const span = Span.new(5, 7);
    /// const moved = span.shiftRight(5);
    /// try std.testing.expectEqual(Span.new(10, 12), moved);
    /// ```
    pub fn shiftRight(self: Span, offset: u32) Span {
        return .{ .start = self.start + offset, .end = self.end + offset };
    }

    /// Translate a span towards the start of the file by `offset` characters.
    /// Opposite of `shiftRight`.
    ///
    /// ## Example
    /// ```zig
    /// const span = Span.new(5, 7);
    /// const moved = span.shiftLeft(5);
    /// try std.testing.expectEqual(Span.new(0, 2), moved);
    /// ```
    pub fn shiftLeft(self: Span, offset: u32) Span {
        return .{ .start = self.start - offset, .end = self.end - offset };
    }

    pub inline fn contains(self: Span, point: u32) bool {
        self.start >= point and point < self.end;
    }

    pub fn eql(self: Span, other: Span) bool {
        return self.start == other.start and self.end == other.end;
    }
};

test "Span.shiftRight" {
    const span = Span.new(5, 7);
    const moved = span.shiftRight(5);
    try t.expectEqual(Span.new(10, 12), moved);
    try t.expectEqual(Span.new(5, 7), span); // original span is not mutated
}

test "Span.shiftLeft" {
    const span = Span.new(5, 7);
    const moved = span.shiftLeft(5);
    try t.expectEqual(Span.new(0, 2), moved);
    try t.expectEqual(Span.new(5, 7), span); // original span is not mutated
}

pub const LabeledSpan = struct {
    span: Span,
    label: ?util.Cow(false) = null,
    primary: bool = false,

    pub inline fn unlabeled(start: u32, end: u32) LabeledSpan {
        return .{
            .span = .{ .start = start, .end = end },
        };
    }

    pub fn from(value: anytype) LabeledSpan {
        return switch (@TypeOf(value)) {
            LabeledSpan => value, // base case
            Span => .{ .span = value },
            std.zig.Ast.Span => .{ .span = Span.from(value) },
            std.zig.Token.Loc => .{ .span = Span.from(value) },
            [2]u32 => .{ .span = Span.from(value) },
            else => |T| {
                const info = @typeInfo(T);
                switch (info) {
                    .@"struct", .@"enum" => {
                        if (@hasField(T, "span")) {
                            return LabeledSpan.from(@field(value, "span"));
                        }
                    },
                    else => {},
                }
                @compileError("Cannot convert type " ++ @typeName(T) ++ "into a LabeledSpan.");
            },
        };
    }
    pub fn fmtJson(self: LabeledSpan, source: []const u8) LocationFormatter {
        return .{ .span = self, .source = source };
    }

    pub const LocationFormatter = struct {
        span: LabeledSpan,
        source: []const u8,

        const Repr = struct {
            start: Location,
            end: Location,
            primary: bool,
            label: ?util.Cow(false),
        };

        // pub fn format(self: *const LocationFormatter, comptime _: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        // pub fn format(self: *const LocationFormatter, comptime _: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        pub fn jsonStringify(self: *const LocationFormatter, jw: anytype) !void {
            const start_offset = self.span.span.start;
            const len = self.span.span.len();
            const start = findLineColumn(self.source, start_offset);
            var end = findLineColumn(self.source[start_offset..], len);
            end.line += start.line - 1;
            end.column += start.column - 1;

            try jw.write(Repr{
                .start = start,
                .end = end,
                .primary = self.span.primary,
                .label = self.span.label,
            });
        }
    };
};

pub const Location = struct {
    /// 1-based line number
    line: u32,
    /// 1-based column number
    column: u32,
    source_line: []const u8,

    pub fn fromSpan(contents: []const u8, span: Span) Location {
        return findLineColumn(contents, @intCast(span.start));
    }
    pub fn jsonStringify(self: *const Location, jw: anytype) !void {
        // { line, column }
        try jw.beginObject();
        try jw.objectFieldRaw("\"line\"");
        try jw.write(self.line);
        try jw.objectFieldRaw("\"column\"");
        try jw.write(self.column);
        try jw.endObject();
    }
    // TODO: toSpan()
};

/// Copied/modified from std.zig.findLineColumn.
fn findLineColumn(source: []const u8, byte_offset: u32) Location {
    var line: u32 = 1;
    var column: u32 = 1;
    var line_start: u32 = 0;
    var i: u32 = 0;
    const slice = source[0..byte_offset];

    while (i < byte_offset) {
        if (std.mem.indexOfScalarPos(u8, slice, i, '\n')) |pos| {
            line += 1;
            column = 1;
            i = @as(u32, @intCast(pos)) + 1;
            line_start = i;
        } else {
            column += byte_offset - i;
            break;
        }
    }

    const pos = std.mem.indexOfScalarPos(u8, source, i, '\n') orelse source.len;
    i = @intCast(pos);

    return Location{
        .line = line,
        .column = column,
        .source_line = source[line_start..i],
    };
}

test findLineColumn {
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
