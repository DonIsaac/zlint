context_lines: u32 = 1,

const MAX_CONTEXT_LINES: u32 = 3;
// characters: Th

pub fn format(self: *GraphicalFormatter, w: *Writer, e: Error) !void {
    var LINEBUF: [MAX_CONTEXT_LINES * 2 + 1]Line = undefined;
    var linebuf = LINEBUF[0..(self.context_lines * 2 + 1)];

    if (e.code.len > 0) {
        try w.print("{s}: ", .{e.code});
    }
    try w.print("{s}", .{e.message.str});

    if (e.labels.len > 0 and e.source != null) {

        // std.mem.sortUnstable()
        const l = e.labels[0];
        const src: []const u8 = e.source.?.deref().*;
        // const lineNo, const colNo = getLineAndCol(src, l);
        const loc = LocationSpan.fromSpan(src, l);
        try w.print("\n[{s}:{d}:{d}]\n", .{
            if (e.source_name) |s| s else "<anonymous>",
            loc.line(),
            loc.column(),
        });
        for (0..linebuf.len) |i| {
            linebuf[i] = Line{ .num = 0, .offset = 0, .contents = "" };
        }
        _ = contextFor(self.context_lines, linebuf, src, loc);
        var lines_start: usize = 0;
        var lines_end: usize = linebuf.len - 1;
        const WHITESPACE = [_]u8{ ' ', '\t', '\n', '\r' };
        while (lines_start < linebuf.len) : (lines_start += 1) {
            const line = linebuf[lines_start];
            if (line.num == 0 or std.mem.trim(u8, line.contents, &WHITESPACE).len == 0) continue;
            break;
        }
        while (lines_end >= lines_start) : (lines_end -= 1) {
            const line = linebuf[lines_end];
            if (line.num == 0 or std.mem.trim(u8, line.contents, &WHITESPACE).len == 0) continue;
            break;
        }
        lines_end += 1;
        const padding = std.math.log10(linebuf[lines_end - 1].num) + 1;
        for (linebuf[lines_start..lines_end]) |line| {
            try w.print("{d}:", .{line.num});
            try w.writeByteNTimes(' ', padding);
            try w.writeAll(line.contents);
            if (util.IS_WINDOWS) {
                try w.writeAll("\r\n");
            } else {
                try w.writeByte('\n');
            }
        }
    }
}

fn contextFor(
    // self: *const GraphicalFormatter,
    context_lines: u32,
    /// Where resolved lines are stored.
    /// has length `2 * self.context_lines + 1`
    linebuf: []Line,
    /// Source text
    src: []const u8,
    span: LocationSpan,
) u32 {
    var start = span.start();
    var end = span.end();
    const lineno = span.line();
    const len: u32 = @intCast(src.len);
    var lines_collected: u32 = 0;
    assert(src.len < std.math.maxInt(u32));
    assert(context_lines <= MAX_CONTEXT_LINES);
    const expected_lines = (context_lines * 2) + 1;
    assert(linebuf.len == expected_lines);

    // expand start/end to cover the entire line
    while (start > 0) : (start -= 1) {
        if (src[start] == '\n') {
            start += 1;
            break;
        }
    }
    while (end < len) : (end += 1) {
        // NOTE: windows \r\n handled b/c this stops at \n
        if (src[end] == '\n') {
            break;
        }
    }
    linebuf[context_lines] = Line{
        .num = lineno,
        .offset = start,
        .contents = src[start..end],
    };
    lines_collected += 1;
    // move start back to the newline of the previous line
    start -|= 1;
    const saved_end = end;

    // collect lines before
    {
        var lines_left = context_lines;
        while (start > 0 and lines_left > 0) : (lines_left -= 1) {
            // move start/end into position at the end of the predecessor line.
            // move start before the newline, but keep end on it.
            end = start;
            eatNewlineBefore(src, &start);
            while (start > 0) : (start -= 1) {
                if (src[start] == '\n') {
                    start += 1;
                    break;
                }
            }
            // NOTE: lines_left is always > 0 (otherwise loop breaks)
            linebuf[lines_left - 1] = Line{
                .num = lineno - (context_lines - lines_left) - 1,
                .offset = start,
                .contents = src[start..end],
            };
            lines_collected += 1;
        }
        // reached start of file before collecting all lines, so we need to
        // zero-out the rest of the buffer
        if (lines_left != 0) {
            for (0..lines_left) |i| {
                linebuf[i] = Line{ .num = 0, .offset = 0, .contents = "" };
            }
        }
    }

    // collect lines after
    {
        // start at the line after the first line collected
        start = saved_end;
        eatNewlineAfter(src, &start);
        end = start;
        var lines_left = context_lines;
        while (end < len and lines_left > 0) : (lines_left -= 1) {
            // move start/end into position at the start of the successor line
            start = end;
            while (end < len) : (end += 1) {
                if (src[end] == '\n') {
                    break;
                }
            }
            const lineno_offset = (context_lines - lines_left) + 1;
            assert(lineno_offset < linebuf.len);
            linebuf[context_lines + lineno_offset] = Line{
                .num = lineno + lineno_offset,
                .offset = start,
                .contents = src[start..end],
            };
            lines_collected += 1;
            eatNewlineAfter(src, &end);
        }
        // same as before, but zeroing out the end
        if (lines_left != 0) {
            const buf_start = context_lines + 1 + lines_left;
            for (buf_start..linebuf.len) |i| {
                linebuf[i] = Line{ .num = 0, .offset = 0, .contents = "" };
            }
        }
    }

    return lines_collected;
}

fn eatNewlineBefore(src: []const u8, i: *u32) void {
    if (i.* == 0) return;
    if (src[i.*] == '\n') i.* -= 1;
    if (i.* > 0 and src[i.*] == '\n') i.* -= 1;
    if (IS_WINDOWS and i.* > 0) {
        assert(src[i.*] == '\r');
        i.* -= 1;
    }
}

fn eatNewlineAfter(src: []const u8, i: *u32) void {
    if (comptime IS_WINDOWS) {
        if (@as(u32, @intCast(src.len)) - i.* > 2) i.* += 2 else i.* = @intCast(src.len);
    } else {
        i.* = @min(@as(u32, @intCast(src.len)), i.* + 1);
    }
}

const Line = struct {
    /// 1-indexed line number. 0 used for omitted/null lines.
    num: u32,
    /// byte offset of the start of the line
    offset: u32,
    /// String contents of the line. Can be used to get the line's length.
    contents: []const u8,

    pub const EMPTY = Line{ .num = 0, .offset = 0, .contents = "" };

    pub inline fn len(self: Line) u32 {
        return @intCast(self.contents.len);
    }
};

const GraphicalFormatter = @This();

const IS_WINDOWS = builtin.target.os.tag == .windows;

const std = @import("std");
const builtin = @import("builtin");
const util = @import("util");
const assert = std.debug.assert;
const Writer = std.fs.File.Writer; // TODO: use std.io.Writer?

const _source = @import("../../source.zig");
const Span = _source.Span;
const Location = _source.Location;
const LocationSpan = _source.LocationSpan;

const Error = @import("../../Error.zig");

const t = std.testing;

test eatNewlineBefore {
    const src = "foo\nbar";

    {
        // "foo\nbar"
        //       ^
        var start: u32 = 4;
        eatNewlineBefore(src, &start);
        try t.expectEqual(4, start);
    }

    {
        // "foo\nbar"
        //      ^
        var start: u32 = 3;
        eatNewlineBefore(src, &start);
        try t.expectEqual(2, start);
    }
}

test contextFor {
    const src =
        \\const std = @import("std");
        \\
        \\var bad: []const u8 = undefined;
        \\
        \\pub const good: ?[]const u8 = null;
        \\
        \\const Foo = struct {
        \\    foo: u32 = undefined,
        \\    const Bar: u32 = 1;
        \\    fn baz(self: *Foo) void {
        \\        std.debug.print("{d}\n", .{self.foo});
        \\    }
        \\};
    ;

    // span over "Bar" in "const Bar: u32 = 1;"
    const bar_span: Span = Span.new(157, 160);
    try t.expectEqualStrings("Bar", bar_span.snippet(src));
    var bar_loc = LocationSpan.fromSpan(src, bar_span);
    try t.expectEqual(9, bar_loc.line());
    try t.expectEqual(11, bar_loc.column());

    // 0 surrounding lines
    {
        var buf = [1]Line{Line.EMPTY};

        const lines_collected = contextFor(0, &buf, src, bar_loc);
        try t.expectEqual(1, lines_collected);
        const line = buf[0];
        try t.expectEqual(9, line.num);
        try t.expectEqual(147, line.offset);
        try t.expectEqual(23, line.len());
        try t.expectEqualStrings("    const Bar: u32 = 1;", line.contents);
    }

    // 1 surrounding line on each side
    {
        var buf = [3]Line{ Line.EMPTY, Line.EMPTY, Line.EMPTY };
        const lines_collected = contextFor(1, &buf, src, bar_loc);
        try t.expectEqual(3, lines_collected);

        try t.expectEqualStrings("    foo: u32 = undefined,", buf[0].contents);
        try t.expectEqualStrings("    const Bar: u32 = 1;", buf[1].contents);
        try t.expectEqualStrings("    fn baz(self: *Foo) void {", buf[2].contents);

        try t.expectEqual(8, buf[0].num);
        try t.expectEqual(9, buf[1].num);
        try t.expectEqual(10, buf[2].num);
    }
}
