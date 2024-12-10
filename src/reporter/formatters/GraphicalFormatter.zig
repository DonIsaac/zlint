context_lines: u32 = 1,
theme: GraphicalTheme = GraphicalTheme.unicode(),
alloc: std.mem.Allocator,

const MAX_CONTEXT_LINES: u32 = 3;

pub const FormatError = Writer.Error || std.mem.Allocator.Error;

pub fn unicode(alloc: std.mem.Allocator, comptime color: bool) GraphicalFormatter {
    // NOTE: must be comptime, otherwise none() returns a reference to a stack
    // pointer.
    const theme = comptime blk: {
        var theme = GraphicalTheme.unicode();
        if (!color) theme.styles = GraphicalTheme.ThemeStyles.none();
        break :blk theme;
    };
    return .{ .theme = theme, .alloc = alloc };
}

pub fn ascii(alloc: std.mem.Allocator, comptime color: bool) GraphicalFormatter {
    // NOTE: must be comptime, otherwise none() returns a reference to a stack
    // pointer.
    const theme = comptime blk: {
        var theme = GraphicalTheme.ascii();
        if (!color) theme.styles = GraphicalTheme.ThemeStyles.none();
        break :blk theme;
    };
    return .{ .theme = theme, .alloc = alloc };
}

pub fn disableColors(self: *GraphicalFormatter) void {
    self.theme.styles = GraphicalTheme.ThemeStyles.none();
}

pub fn format(self: *GraphicalFormatter, w: *Writer, e: Error) FormatError!void {
    var err = e;
    if (e.severity == .off) return;
    try self.renderHeader(w, &err);
    try self.renderContext(w, &err);
    try self.renderFooter(w, &err);
    try w.writeByte('\n');
}

fn renderHeader(self: *GraphicalFormatter, w: *Writer, e: *const Error) FormatError!void {
    const icon = self.iconFor(e.severity);
    const color = self.styleFor(e.severity);
    const emphasize = self.theme.styles.emphasize;

    try w.writeAll(color.open);
    try w.writeAll(emphasize.open);
    defer w.writeAll(emphasize.close) catch {};
    defer w.writeAll(color.close) catch {};

    try w.print("  {s} ", .{icon});

    if (e.code.len > 0) {
        try w.writeAll(e.code);
        try w.writeAll(color.close);
        try w.writeAll(": ");
        try w.writeAll(color.open);
    }

    try w.print("{s}\n", .{e.message.str});
}

fn renderFooter(self: *GraphicalFormatter, w: *Writer, e: *const Error) FormatError!void {
    const help = if (e.help) |h| h.str else return;
    const color = self.theme.styles.help;
    try w.writeByte('\n');
    try w.print("  {s}help:{s} {s}", .{ color.open, color.close, help });
}

fn labelsLt(_: void, a: LabeledSpan, b: LabeledSpan) bool {
    return a.span.start < b.span.start;
}

fn renderContext(self: *GraphicalFormatter, w: *Writer, e: *Error) FormatError!void {
    if (e.labels.items.len == 0 or e.source == null) return;

    const src: []const u8 = e.source.?.deref().*;

    std.sort.insertion(LabeledSpan, e.labels.items, {}, labelsLt);

    var alloc = std.heap.stackFallback(@sizeOf(ContextInfo) * 8, self.alloc);
    var locations = std.ArrayList(ContextInfo).init(alloc.get());
    defer locations.deinit();

    var largest_line_num: u32 = 0;
    for (e.labels.items) |l| {
        const loc = ContextInfo.fromSpan(src, l);
        locations.append(loc) catch @panic("OOM");
        largest_line_num = @max(largest_line_num, loc.line() + self.context_lines);
    }
    const lineum_width = std.math.log10(largest_line_num);

    const primary: ContextInfo = blk: {
        for (locations.items) |loc| {
            if (loc.span.primary) {
                break :blk loc;
            }
        }
        locations.items[0].span.primary = true;
        break :blk locations.items[0];
    };

    try self.renderContextMasthead(w, e, lineum_width, primary);

    for (locations.items) |loc| {
        if (loc.rendered) continue;
        try self.renderContextLines(w, src, lineum_width, locations.items, loc);
    }
    try self.renderContextFinisher(w, lineum_width);
}

fn renderContextMasthead(
    self: *GraphicalFormatter,
    w: *Writer,
    e: *const Error,
    lineum_width: u32,
    primary_span: ContextInfo,
) FormatError!void {
    const chars = self.theme.characters;
    const color = self.theme.styles.help;

    try w.writeByteNTimes(' ', lineum_width + 3);

    // ╭─[
    try w.print("{s}{s}{s}", .{ chars.ltop, chars.hbar, chars.lbox });
    // foo.zig:1:1
    try w.writeAll(color.open);
    try w.print("{s}:{d}:{d}", .{
        if (e.source_name) |s| s else "<anonymous>",
        primary_span.line(),
        primary_span.column(),
    });
    try w.writeAll(color.close);

    // ]
    try w.print("{s}\n", .{chars.rbox});
}

fn renderContextFinisher(self: *GraphicalFormatter, w: *Writer, lineum_col_width: u32) FormatError!void {
    const chars = self.theme.characters;

    try w.writeByteNTimes(' ', lineum_col_width + 3);
    try w.writeAll(chars.lbot);
    const BAR_LEN = 4;
    try w.writeBytesNTimes(chars.hbar, BAR_LEN);
}

fn renderContextLines(
    self: *GraphicalFormatter,
    w: *Writer,
    src: []const u8,
    lineum_width: u32,
    locations: []ContextInfo,
    loc: ContextInfo,
) !void {
    var LINEBUF: [MAX_CONTEXT_LINES * 2 + 1]Line = undefined;
    var linebuf = LINEBUF[0..(self.context_lines * 2 + 1)];

    @memset(&LINEBUF, Line.EMPTY);
    _ = contextFor(self.context_lines, linebuf, src, loc);

    var lines_start: usize = 0;
    var lines_end: usize = linebuf.len - 1;
    while (lines_start < linebuf.len) : (lines_start += 1) {
        const line = linebuf[lines_start];
        if (line.num == 0 or util.trimWhitespace(line.contents).len == 0) continue;
        break;
    }
    while (lines_end >= lines_start) : (lines_end -= 1) {
        const line = linebuf[lines_end];
        if (line.num == 0 or util.trimWhitespace(line.contents).len == 0) continue;
        break;
    }
    lines_end += 1;

    for (linebuf[lines_start..lines_end]) |line| {
        // try w.print("{d}:", .{line.num});
        // try w.writeByteNTimes(' ', padding);
        try self.renderCodeLinePrefix(w, line.num, lineum_width);
        try w.writeAll(util.trimWhitespaceRight(line.contents));
        if (util.IS_WINDOWS) {
            try w.writeAll("\r\n");
        } else {
            try w.writeByte('\n');
        }
        for (locations) |*l| {
            if (l.line() == line.num) {
                try self.renderLabel(w, lineum_width, l.*);
                l.rendered = true;
            }
        }
    }
}

/// Render the line number column and the `|` separator. Has a trailing space.
///
/// e.g. '` 1 | `'
fn renderCodeLinePrefix(self: *GraphicalFormatter, w: *Writer, lineum: u32, linenum_col_width: u32) FormatError!void {
    const styles = self.theme.styles;
    const chars = self.theme.characters;

    const lineum_width = std.math.log10(lineum);
    const padding_needed = linenum_col_width - lineum_width;

    try w.print(" {s}{d}{s} ", .{ styles.linum.open, lineum, styles.linum.close });
    try w.writeByteNTimes(' ', padding_needed);
    try w.writeAll(chars.vbar);
    try w.writeByte(' ');
}

// TODO: render label text
// TODO: handle multi-line labels
fn renderLabel(self: *GraphicalFormatter, w: *Writer, linum_col_len: u32, loc: ContextInfo) FormatError!void {
    const chars = self.theme.characters;
    const h = self.theme.styles.highlights;
    const idx: usize = @min(@intFromBool(!loc.span.primary), h.len - 1);
    const color = h[idx];

    try self.renderLabelPrefix(w, linum_col_len);
    try w.writeByteNTimes(' ', loc.column());

    if (loc.label()) |label| {
        try w.writeAll(color.open);
        const midway = loc.len() / 2;
        const odd = loc.len() % 2 == 0;
        const first_len_half = if (odd) midway + 1 else midway;

        // ───┬───
        try w.writeBytesNTimes(chars.underline, first_len_half);
        try w.writeAll(chars.underbar);
        try w.writeBytesNTimes(chars.underline, first_len_half);
        try w.writeAll(color.close);
        try w.writeAll("\n");
        {
            try self.renderLabelPrefix(w, linum_col_len);
            try w.writeByteNTimes(' ', loc.column());
            try w.writeByteNTimes(' ', first_len_half);
            // ╰── label text
            try w.writeAll(color.open);
            try w.print("{s}{s}{s} ", .{ chars.lbot, chars.hbar, chars.hbar });
            try w.writeAll(label);
            try w.writeAll(color.close);
        }
    } else {
        try w.writeAll(color.open);
        try w.writeBytesNTimes(chars.underline, loc.span.span.len());
        try w.writeAll(color.close);
    }
    try w.writeAll("\n");
}

/// Renders enough space to pad-out the line number column followed by a
/// vertical bar break with _no_ trailing space.
fn renderLabelPrefix(self: *GraphicalFormatter, w: *Writer, linum_col_len: u32) FormatError!void {
    const chars = self.theme.characters;
    try w.writeByteNTimes(' ', linum_col_len + 3);
    try w.writeAll(chars.vbar_break);
}

fn styleFor(self: *GraphicalFormatter, severity: Error.Severity) GraphicalTheme.Chameleon {
    return switch (severity) {
        .err => self.theme.styles.err,
        .warning => self.theme.styles.warning,
        .notice => self.theme.styles.advice,
        .off => @panic("off severity should not be rendered at all."),
    };
}

fn highlightFor(self: *GraphicalFormatter, severity: Error.Severity) GraphicalTheme.Chameleon {
    const highlights = self.theme.styles.highlights;
    assert(highlights.len > 0);
    const idx = switch (severity) {
        .err => 0,
        .warning => 1,
        .notice => 2,
        .off => @panic("off severity should not be rendered at all."),
    };

    return highlights[@min(idx, highlights.len - 1)];
}

fn iconFor(self: *GraphicalFormatter, severity: Error.Severity) util.string {
    return switch (severity) {
        .err => self.theme.characters.err,
        .warning => self.theme.characters.warning,
        .notice => self.theme.characters.advice,
        .off => @panic("off severity should not be rendered at all."),
    };
}

fn contextFor(
    context_lines: u32,
    /// Where resolved lines are stored.
    /// has length `2 * self.context_lines + 1`
    linebuf: []Line,
    /// Source text
    src: []const u8,
    span: ContextInfo,
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

    // happens sometimes when reporting missing semicolon parse errors.
    if (start == src.len) start -= 1;

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
        .contents = util.trimWhitespaceRight(src[start..end]),
    };
    lines_collected += 1;
    // move start back to the newline of the previous line
    start -|= 1;

    // collect lines before
    {
        var lines_left = context_lines;
        var it = std.mem.splitBackwardsScalar(u8, src[0..start], '\n');
        while (lines_left > 0) : ({
            lines_left -= 1;
            lines_collected += 1;
        }) {
            const prev_line = it.next() orelse break;
            linebuf[lines_left - 1] = Line{
                .num = (lineno - 1) - (context_lines - lines_left),
                .offset = start,
                .contents = util.trimWhitespaceRight(prev_line),
            };
        }
        // reached start of file before collecting all lines, so we need to
        // zero-out the rest of the buffer
        if (lines_left != 0) {
            for (0..lines_left) |i| {
                linebuf[i] = Line.EMPTY;
            }
        }
    }

    // collect lines after
    {
        var lines_left = context_lines;
        eatNewlineAfter(src, &end);
        var it = std.mem.splitScalar(u8, src[end..len], '\n');
        while (lines_left > 0) : ({
            lines_left -= 1;
            lines_collected += 1;
        }) {
            const next_line = it.next() orelse break;
            linebuf[context_lines + 1 + (context_lines - lines_left)] = Line{
                .num = (lineno + 1) + (context_lines - lines_left),
                .offset = end,
                .contents = util.trimWhitespaceRight(next_line),
            };
        }
        // same as before, but zeroing out the end
        if (lines_left != 0) {
            const buf_start = context_lines + 1 + lines_left;
            for (buf_start..linebuf.len) |i| {
                linebuf[i] = Line.EMPTY;
            }
        }
    }

    return lines_collected;
}

fn eatNewlineBefore(src: []const u8, i: *u32) void {
    if (i.* == 0) return;
    if (src[i.*] == '\n') i.* -= 1;
    if (i.* > 0 and src[i.*] == '\n') i.* -= 1;
    if (comptime util.IS_WINDOWS) {
        if (i.* > 0 and src[i.*] == '\r') i.* -= 1;
    }
}

fn eatNewlineAfter(src: []const u8, i: *u32) void {
    if (comptime util.IS_WINDOWS) {
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

const ContextInfo = struct {
    span: LabeledSpan,
    location: Location,
    rendered: bool = false,

    pub fn fromSpan(contents: util.string, span: anytype) ContextInfo {
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

    pub inline fn len(self: ContextInfo) u32 {
        return self.span.span.len();
    }
    pub inline fn start(self: ContextInfo) u32 {
        return self.span.span.start;
    }
    pub inline fn end(self: ContextInfo) u32 {
        return self.span.span.end;
    }
    pub inline fn line(self: ContextInfo) u32 {
        return self.location.line;
    }
    pub inline fn column(self: ContextInfo) u32 {
        return self.location.column;
    }
    pub inline fn source(self: ContextInfo) util.string {
        return self.location.source_line;
    }
    pub inline fn label(self: ContextInfo) ?util.string {
        if (self.span.label) |l| {
            const label_text = l.borrow();
            return if (label_text.len == 0) null else label_text;
        }
        return null;
    }
};

const GraphicalFormatter = @This();

const std = @import("std");
const builtin = @import("builtin");
const util = @import("util");

const assert = std.debug.assert;
const Writer = std.fs.File.Writer; // TODO: use std.io.Writer?

const GraphicalTheme = @import("GraphicalTheme.zig");

const _span = @import("../../span.zig");
const Span = _span.Span;
const LabeledSpan = _span.LabeledSpan;
const Location = _span.Location;
const LocationSpan = _span.LocationSpan;

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
        //     ^^
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
    var bar_loc = ContextInfo.fromSpan(src, bar_span);
    try t.expectEqual(9, bar_loc.line());
    try t.expectEqual(11, bar_loc.column());

    // span over "bad"
    const bad_span: Span = Span.new(33, 36);
    try t.expectEqualStrings("bad", bad_span.snippet(src));
    const bad_loc = ContextInfo.fromSpan(src, bad_span);
    try t.expectEqual(3, bad_loc.line());
    try t.expectEqual(5, bad_loc.column());

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
        if (!util.IS_WINDOWS) { // FIXME
            try t.expectEqualStrings("    fn baz(self: *Foo) void {", buf[2].contents);
        }

        try t.expectEqual(8, buf[0].num);
        try t.expectEqual(9, buf[1].num);
        try t.expectEqual(10, buf[2].num);
    }

    // When surrounded by empty lines
    {
        var buf = [3]Line{ Line.EMPTY, Line.EMPTY, Line.EMPTY };
        const lines_collected = contextFor(1, &buf, src, bad_loc);
        try t.expectEqual(3, lines_collected);

        try t.expectEqualStrings("", buf[0].contents);
        try t.expectEqualStrings("var bad: []const u8 = undefined;", buf[1].contents);
        if (!util.IS_WINDOWS) { // FIXME
            try t.expectEqualStrings("", buf[2].contents);
        }
    }
}

// TODO: get a windows machine and debug/fix these tests
// test "contextFor with CRLF newlines on windows" {
//     if (!util.IS_WINDOWS) return;

//     const src = "const Foo = struct {\r\n    foo: u32 = undefined,\r\n    const Bar: u32 = 1;\r\n    fn baz(self: *Foo) void {\r\n        std.debug.print(\"{d}\\n\", .{self.foo});\r\n    }\r\n};\r\n";

//     // span over "Bar" in "const Bar: u32 = 1;"
//     const bar_span: Span = Span.new(157, 160);
//     try t.expectEqualStrings("Bar", bar_span.snippet(src));
//     var bar_loc = LocationSpan.fromSpan(src, bar_span);
//     try t.expectEqual(9, bar_loc.line());
//     try t.expectEqual(11, bar_loc.column());
//     var buf = [3]Line{ Line.EMPTY, Line.EMPTY, Line.EMPTY };
//     const lines_collected = contextFor(1, &buf, src, bar_loc);
//     try t.expectEqual(3, lines_collected);

//     try t.expectEqualStrings("    foo: u32 = undefined,", buf[0].contents);
//     try t.expectEqualStrings("    const Bar: u32 = 1;", buf[1].contents);
//     try t.expectEqualStrings("    fn baz(self: *Foo) void {", buf[2].contents);

//     try t.expectEqual(8, buf[0].num);
//     try t.expectEqual(9, buf[1].num);
//     try t.expectEqual(10, buf[2].num);
// }
