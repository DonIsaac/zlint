context_lines: u32 = 1,
theme: GraphicalTheme = GraphicalTheme.unicode(),
alloc: std.mem.Allocator,

const MAX_CONTEXT_LINES: u32 = 3;

pub const Theme = GraphicalTheme;

pub const meta: Meta = .{ .report_statistics = true };

pub fn unicode(alloc: std.mem.Allocator, color: bool) GraphicalFormatter {
    const theme: GraphicalTheme = .{
        .styles = if (color) Styles.ansi() else Styles.none(),
        .characters = GraphicalTheme.ThemeCharacters.unicode(),
    };
    return .{ .theme = theme, .alloc = alloc };
}

pub fn ascii(alloc: std.mem.Allocator, color: bool) GraphicalFormatter {
    const theme: GraphicalTheme = .{
        .styles = if (color) Styles.ansi() else Styles.none(),
        .characters = GraphicalTheme.ThemeCharacters.ascii(),
    };
    return .{ .theme = theme, .alloc = alloc };
}

pub fn disableColors(self: *GraphicalFormatter) void {
    self.theme.styles = GraphicalTheme.ThemeStyles.none();
}

pub fn format(self: *GraphicalFormatter, w: *io.Writer, e: Error) FormatError!void {
    var err = e;
    if (e.severity == .off) return;
    try self.renderHeader(w, &err);
    try self.renderContext(w, &err);
    try self.renderFooter(w, &err);
    try writeNewline(w);
}

/// `𝙭  some-code: a message here`
fn renderHeader(self: *GraphicalFormatter, w: *io.Writer, e: *const Error) FormatError!void {
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

    try w.writeAll(e.message.str);
    try writeNewline(w);
}

fn renderFooter(self: *GraphicalFormatter, w: *io.Writer, e: *const Error) FormatError!void {
    const help = if (e.help) |h| h.str else return;
    const color = self.theme.styles.help;
    try writeNewline(w);
    try w.print("  {s}help:{s} {s}", .{ color.open, color.close, help });
}

fn labelsLt(_: void, a: LabeledSpan, b: LabeledSpan) bool {
    return a.span.start < b.span.start;
}

fn renderContext(self: *GraphicalFormatter, w: *io.Writer, e: *Error) FormatError!void {
    if (e.labels.items.len == 0 or e.source == null) return;

    const src: []const u8 = e.source.?.deref().*;
    // No source text means there are no lines to render a code frame for.
    if (src.len == 0) return;

    std.sort.insertion(LabeledSpan, e.labels.items, {}, labelsLt);

    var alloc = std.heap.stackFallback(@sizeOf(ContextInfo) * 8, self.alloc);
    var locations = std.array_list.Managed(ContextInfo).init(alloc.get());
    defer locations.deinit();

    var largest_line_num: u32 = 0;
    for (e.labels.items) |l| {
        const loc = ContextInfo.fromSpan(src, l);
        locations.append(loc) catch @panic("OOM");
        largest_line_num = @max(largest_line_num, loc.endLine() + self.context_lines);
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

    var last_rendered_line: u32 = 0;
    for (locations.items) |loc| {
        if (loc.rendered) continue;
        try self.renderContextLines(w, src, lineum_width, locations.items, loc, last_rendered_line);
        last_rendered_line = loc.endLine() + self.context_lines;
    }
    try self.renderContextFinisher(w, lineum_width);
}

fn renderContextMasthead(
    self: *GraphicalFormatter,
    w: *io.Writer,
    e: *const Error,
    lineum_width: u32,
    primary_span: ContextInfo,
) FormatError!void {
    const chars = self.theme.characters;
    const color = self.theme.styles.help;

    try writeByteNTimes(w, ' ', lineum_width + 3);

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
    try w.writeAll(chars.rbox);
    try writeNewline(w);
}

fn renderContextFinisher(self: *GraphicalFormatter, w: *io.Writer, lineum_col_width: u32) FormatError!void {
    const chars = self.theme.characters;

    try writeByteNTimes(w, ' ', lineum_col_width + 3);
    try w.writeAll(chars.lbot);
    const BAR_LEN = 4;
    try writeBytesNTimes(w, chars.hbar, BAR_LEN);
}

fn renderContextLines(
    self: *GraphicalFormatter,
    w: *io.Writer,
    src: []const u8,
    lineum_width: u32,
    locations: []ContextInfo,
    loc: ContextInfo,
    // last rendered line of the previous location
    last_rendered_line: u32,
) !void {
    if (loc.isMultiline()) {
        try self.renderMultilineContext(w, src, lineum_width, locations, loc, last_rendered_line);
        return;
    }

    var LINEBUF: [MAX_CONTEXT_LINES * 2 + 1]Line = undefined;
    var linebuf = LINEBUF[0..(self.context_lines * 2 + 1)];

    @memset(&LINEBUF, .empty);
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
        // avoid double-rendering lines when two spans have their context lines
        // overlap.
        if (line.num <= last_rendered_line) continue;
        const gutter: Gutter = .fromLine(line.num, locations);
        try self.renderSourceLine(w, line, lineum_width, gutter);
        try self.renderLabelsOnLine(w, lineum_width, locations, line.num, gutter);
    }
}

/// Multiline spans this long or shorter render every line.
const MULTILINE_COLLAPSE_AFTER: u32 = 8;
/// How many lines to keep at each end of a collapsed multiline span.
const MULTILINE_KEEP_LINES: u32 = 2;

fn renderMultilineContext(
    self: *GraphicalFormatter,
    w: *io.Writer,
    src: []const u8,
    lineum_width: u32,
    locations: []ContextInfo,
    loc: ContextInfo,
    last_rendered_line: u32,
) !void {
    const src_lines = countLines(src);
    const span_start = loc.line();
    const span_end = loc.endLine();
    const span_len = span_end - span_start + 1;
    const collapse = span_len > MULTILINE_COLLAPSE_AFTER;

    const window_start: u32 = if (span_start > self.context_lines) span_start - self.context_lines else 1;
    const window_end: u32 = @min(src_lines, span_end + self.context_lines);

    var line_num = window_start;
    while (line_num <= window_end) : (line_num += 1) {
        if (line_num <= last_rendered_line) continue;

        if (collapse and line_num == span_start + MULTILINE_KEEP_LINES) {
            try self.renderElidedLine(w, lineum_width);
            line_num = span_end - MULTILINE_KEEP_LINES;
            continue;
        }

        const line = nthLine(src, line_num);
        if (line.num == 0) continue;
        if ((line_num < span_start or line_num > span_end) and util.trimWhitespace(line.contents).len == 0) {
            continue;
        }

        const gutter: Gutter = .fromLine(line_num, locations);
        try self.renderSourceLine(w, line, lineum_width, gutter);
        try self.renderLabelsOnLine(w, lineum_width, locations, line_num, gutter);
    }
}

fn renderLabelsOnLine(
    self: *GraphicalFormatter,
    w: *io.Writer,
    lineum_width: u32,
    locations: []ContextInfo,
    line_num: u32,
    gutter: Gutter,
) FormatError!void {
    for (locations) |*l| {
        if (l.isMultiline()) {
            if (l.endLine() == line_num) {
                if (l.label()) |label_text| {
                    try self.renderMultilineLabel(w, lineum_width, l.*, label_text);
                }
                l.rendered = true;
            }
            continue;
        }
        if (l.line() == line_num) {
            try self.renderLabel(w, lineum_width, l.*, gutter.width());
            l.rendered = true;
        }
    }
}

const Gutter = struct {
    kind: Kind,
    loc: ?ContextInfo,

    pub const none: Gutter = .{ .kind = .none, .loc = null };

    const default_width: u32 = 4;

    const Kind = enum {
        none,
        start,
        flyby,
        end,
        end_labeled,
    };

    pub fn width(self: Gutter) u32 {
        return if (self.kind == .none) 0 else default_width;
    }

    fn fromLine(line_num: u32, locations: []const ContextInfo) Gutter {
        var flyby: Gutter = .none;
        for (locations) |loc| {
            if (!loc.isMultiline()) continue;
            if (line_num == loc.line()) return .{ .kind = .start, .loc = loc };
            if (line_num == loc.endLine()) {
                return .{
                    .kind = if (loc.label() != null) .end_labeled else .end,
                    .loc = loc,
                };
            }
            if (line_num > loc.line() and line_num < loc.endLine()) {
                flyby = .{ .kind = .flyby, .loc = loc };
            }
        }
        return flyby;
    }
};

fn renderSourceLine(
    self: *GraphicalFormatter,
    w: *io.Writer,
    line: Line,
    lineum_width: u32,
    gutter: Gutter,
) FormatError!void {
    try self.renderCodeLinePrefix(w, line.num, lineum_width);
    try self.renderGutter(w, gutter);
    try w.writeAll(util.trimWhitespaceRight(line.contents));
    try writeNewline(w);
}

fn renderGutter(self: *GraphicalFormatter, w: *io.Writer, gutter: Gutter) FormatError!void {
    const chars = self.theme.characters;
    const color = if (gutter.loc) |loc| self.highlightForSpan(loc) else self.theme.styles.highlights[0];
    switch (gutter.kind) {
        .none => {},
        .start => {
            try w.writeAll(color.open);
            try w.writeAll(chars.ltop);
            try w.writeAll(chars.hbar);
            try w.writeAll(chars.rarrow);
            try w.writeAll(color.close);
            try w.writeByte(' ');
        },
        .flyby => {
            try w.writeAll(color.open);
            try w.writeAll(chars.vbar);
            try w.writeAll(color.close);
            try w.writeAll("   ");
        },
        .end, .end_labeled => {
            try w.writeAll(color.open);
            try w.writeAll(if (gutter.kind == .end_labeled) chars.lcross else chars.lbot);
            try w.writeAll(chars.hbar);
            try w.writeAll(chars.rarrow);
            try w.writeAll(color.close);
            try w.writeByte(' ');
        },
    }
}

fn renderElidedLine(self: *GraphicalFormatter, w: *io.Writer, lineum_width: u32) FormatError!void {
    const chars = self.theme.characters;
    const color = self.theme.styles.highlights[0];
    try writeByteNTimes(w, ' ', lineum_width + 3);
    try w.writeAll(chars.vbar_break);
    try w.writeByte(' ');
    try w.writeAll(color.open);
    try w.writeAll(chars.elided);
    try w.writeAll(color.close);
    try writeNewline(w);
}

fn renderMultilineLabel(
    self: *GraphicalFormatter,
    w: *io.Writer,
    lineum_width: u32,
    loc: ContextInfo,
    label: []const u8,
) FormatError!void {
    const chars = self.theme.characters;
    const color = self.highlightForSpan(loc);

    try self.renderLabelPrefix(w, lineum_width);
    try w.writeByte(' ');
    try w.writeAll(color.open);
    try w.writeAll(chars.lbot);
    try writeBytesNTimes(w, chars.hbar, 4);
    try w.writeByte(' ');
    try w.writeAll(label);
    try w.writeAll(color.close);
    try writeNewline(w);
}

/// Render the line number column and the `|` separator. Has a trailing space.
///
/// e.g. '` 1 | `'
fn renderCodeLinePrefix(self: *GraphicalFormatter, w: *io.Writer, lineum: u32, linenum_col_width: u32) FormatError!void {
    const styles = self.theme.styles;
    const chars = self.theme.characters;

    const lineum_width = std.math.log10(lineum);
    const padding_needed = linenum_col_width - lineum_width;

    try w.print(" {s}{d}{s} ", .{ styles.linum.open, lineum, styles.linum.close });
    try writeByteNTimes(w, ' ', padding_needed);
    try w.writeAll(chars.vbar);
    try w.writeByte(' ');
}

// TODO: render label text
// TODO: handle multi-line labels
fn renderLabel(self: *GraphicalFormatter, w: *io.Writer, linum_col_len: u32, loc: ContextInfo, gutter_width: u32) FormatError!void {
    const chars = self.theme.characters;
    const color = self.highlightForSpan(loc);
    const col = loc.column() + gutter_width;

    try self.renderLabelPrefix(w, linum_col_len);
    try writeByteNTimes(w, ' ', col);

    if (loc.label()) |label| {
        try w.writeAll(color.open);
        const l = loc.len();
        const odd = l % 2 == 0;
        const midway = (if (odd) l - 1 else l) / 2;
        const first_len_half = if (odd) midway + 1 else midway;

        // ───┬───
        try writeBytesNTimes(w, chars.underline, first_len_half);
        try w.writeAll(chars.underbar);
        try writeBytesNTimes(w, chars.underline, first_len_half);
        try w.writeAll(color.close);
        try writeNewline(w);
        {
            try self.renderLabelPrefix(w, linum_col_len);
            try writeByteNTimes(w, ' ', col);
            try writeByteNTimes(w, ' ', first_len_half);
            // ╰── label text
            try w.writeAll(color.open);
            try w.print("{s}{s}{s} ", .{ chars.lbot, chars.hbar, chars.hbar });
            try w.writeAll(label);
            try w.writeAll(color.close);
        }
    } else {
        try w.writeAll(color.open);
        try writeBytesNTimes(w, chars.underline, loc.span.span.len());
        try w.writeAll(color.close);
    }
    try writeNewline(w);
}

/// Renders enough space to pad-out the line number column followed by a
/// vertical bar break with _no_ trailing space.
fn renderLabelPrefix(self: *GraphicalFormatter, w: *io.Writer, linum_col_len: u32) FormatError!void {
    const chars = self.theme.characters;
    try writeByteNTimes(w, ' ', linum_col_len + 3);
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

fn highlightForSpan(self: *GraphicalFormatter, loc: ContextInfo) GraphicalTheme.Chameleon {
    const highlights = self.theme.styles.highlights;
    const idx: usize = @min(@intFromBool(!loc.span.primary), highlights.len - 1);
    return highlights[idx];
}

fn iconFor(self: *GraphicalFormatter, severity: Error.Severity) []const u8 {
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
    if (start == src.len and start > 0) start -= 1;

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
                linebuf[i] = .empty;
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
                linebuf[i] = .empty;
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

    pub const empty: Line = .{ .num = 0, .offset = 0, .contents = "" };

    pub inline fn len(self: Line) u32 {
        return @intCast(self.contents.len);
    }
};

const ContextInfo = struct {
    span: LabeledSpan,
    location: Location,
    end_location: Location,
    rendered: bool = false,

    pub fn fromSpan(contents: []const u8, span: anytype) ContextInfo {
        const labeled_span: LabeledSpan, const loc: Location = brk: {
            switch (@TypeOf(span)) {
                Span => {
                    const labeled = LabeledSpan{ .span = span };
                    break :brk .{ labeled, Location.fromSpan(contents, span) };
                },
                LabeledSpan => {
                    break :brk .{ span, Location.fromSpan(contents, span.span) };
                },
                else => @panic("`span` must be a Span or LabeledSpan"),
            }
        };
        const last_byte = if (labeled_span.span.end > labeled_span.span.start)
            labeled_span.span.end - 1
        else
            labeled_span.span.start;
        const end_loc = Location.fromSpan(contents, Span.new(last_byte, labeled_span.span.end));
        return .{ .span = labeled_span, .location = loc, .end_location = end_loc };
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
    pub inline fn endLine(self: ContextInfo) u32 {
        return self.end_location.line;
    }
    pub inline fn isMultiline(self: ContextInfo) bool {
        return self.line() != self.endLine();
    }
    pub inline fn column(self: ContextInfo) u32 {
        return self.location.column;
    }
    pub inline fn source(self: ContextInfo) []const u8 {
        return self.location.source_line;
    }
    pub inline fn label(self: ContextInfo) ?[]const u8 {
        if (self.span.label) |l| {
            const label_text = l.borrow();
            return if (label_text.len == 0) null else label_text;
        }
        return null;
    }
};

fn countLines(src: []const u8) u32 {
    var n: u32 = 1;
    for (src) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

fn nthLine(src: []const u8, line_num: u32) Line {
    var current: u32 = 1;
    var start: usize = 0;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        if (src[i] == '\n') {
            if (current == line_num) {
                return .{
                    .num = line_num,
                    .offset = @intCast(start),
                    .contents = util.trimWhitespaceRight(src[start..i]),
                };
            }
            current += 1;
            start = i + 1;
        }
    }
    if (current == line_num) {
        return .{
            .num = line_num,
            .offset = @intCast(start),
            .contents = util.trimWhitespaceRight(src[start..]),
        };
    }
    return .empty;
}

test nthLine {
    const expectLine = std.testing.expectEqualDeep;

    try expectLine(Line.empty, nthLine("", 0));
    try expectLine(Line.empty, nthLine("", 10));

    // lines are 1-indexed, so line 0 never matches
    try expectLine(Line.empty, nthLine("foo", 0));
    try expectLine(Line.empty, nthLine("foo\nbar", 0));

    // past the last line
    try expectLine(Line.empty, nthLine("foo", 2));
    try expectLine(Line.empty, nthLine("foo\nbar", 3));

    // empty sources still have one (empty) line
    try expectLine(Line{ .num = 1, .offset = 0, .contents = "" }, nthLine("", 1));

    try expectLine(Line{ .num = 1, .offset = 0, .contents = "foo" }, nthLine("foo", 1));
    try expectLine(Line{ .num = 1, .offset = 0, .contents = "foo" }, nthLine("foo\nbar", 1));
    try expectLine(Line{ .num = 2, .offset = 4, .contents = "bar" }, nthLine("foo\nbar", 2));

    // a trailing newline creates an empty last line
    try expectLine(Line{ .num = 1, .offset = 0, .contents = "foo" }, nthLine("foo\n", 1));
    try expectLine(Line{ .num = 2, .offset = 4, .contents = "" }, nthLine("foo\n", 2));

    // empty lines in the middle are preserved
    try expectLine(Line{ .num = 1, .offset = 0, .contents = "a" }, nthLine("a\n\nb", 1));
    try expectLine(Line{ .num = 2, .offset = 2, .contents = "" }, nthLine("a\n\nb", 2));
    try expectLine(Line{ .num = 3, .offset = 3, .contents = "b" }, nthLine("a\n\nb", 3));

    // trailing whitespace is trimmed, leading whitespace is not
    try expectLine(Line{ .num = 1, .offset = 0, .contents = "foo" }, nthLine("foo   \n\tbar\t\t", 1));
    try expectLine(Line{ .num = 2, .offset = 7, .contents = "\tbar" }, nthLine("foo   \n\tbar\t\t", 2));

    // CRLF endings
    try expectLine(Line{ .num = 1, .offset = 0, .contents = "a" }, nthLine("a\r\nb\r\n", 1));
    try expectLine(Line{ .num = 2, .offset = 3, .contents = "b" }, nthLine("a\r\nb\r\n", 2));
    try expectLine(Line{ .num = 3, .offset = 6, .contents = "" }, nthLine("a\r\nb\r\n", 3));
}

fn writeByteNTimes(w: *io.Writer, byte: u8, n: usize) FormatError!void {
    for (0..n) |_| {
        try w.writeByte(byte);
    }
}

fn writeBytesNTimes(w: *io.Writer, bytes: []const u8, n: usize) FormatError!void {
    for (0..n) |_| {
        try w.writeAll(bytes);
    }
}

fn writeNewline(w: *io.Writer) FormatError!void {
    try w.writeAll(util.NEWLINE);
}

const GraphicalFormatter = @This();

const std = @import("std");
const io = std.Io;
const util = @import("util");

const assert = std.debug.assert;

const GraphicalTheme = @import("GraphicalTheme.zig");
const Styles = GraphicalTheme.ThemeStyles;

const _span = @import("../../span.zig");
const Span = _span.Span;
const LabeledSpan = _span.LabeledSpan;
const Location = _span.Location;

const Error = @import("../../Error.zig");

const formatter = @import("../formatter.zig");
const FormatError = formatter.FormatError;
const Meta = formatter.Meta;

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
        var buf = [1]Line{.empty};

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
        var buf = [3]Line{ .empty, .empty, .empty };
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
        var buf = [3]Line{ .empty, .empty, .empty };
        const lines_collected = contextFor(1, &buf, src, bad_loc);
        try t.expectEqual(3, lines_collected);

        try t.expectEqualStrings("", buf[0].contents);
        try t.expectEqualStrings("var bad: []const u8 = undefined;", buf[1].contents);
        if (!util.IS_WINDOWS) { // FIXME
            try t.expectEqualStrings("", buf[2].contents);
        }
    }
}

test "ascii formatter uses ascii glyphs" {
    var ascii_formatter = GraphicalFormatter.ascii(t.allocator, false);
    var writer = std.Io.Writer.Allocating.init(t.allocator);
    defer writer.deinit();

    try ascii_formatter.format(&writer.writer, Error.newStatic("Something happened"));
    const out = try dupeLf(t.allocator, writer.writer.buffered());
    defer t.allocator.free(out);
    try t.expectEqualStrings("  x Something happened\n\n", out);
    for (out) |byte| {
        try t.expect(byte < 0x80);
    }
}

fn spanOf(src: []const u8, needle: []const u8) Span {
    const start = std.mem.indexOf(u8, src, needle) orelse @panic("needle not found");
    return Span.new(@intCast(start), @intCast(start + needle.len));
}

fn dupeLf(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const crlfs = std.mem.count(u8, s, "\r\n");
    if (crlfs == 0) return alloc.dupe(u8, s);
    const out = try alloc.alloc(u8, s.len - crlfs);
    _ = std.mem.replace(u8, s, "\r\n", "\n", out);
    return out;
}

fn formatLabeledSpans(src_text: [:0]const u8, labels: []const LabeledSpan) ![]u8 {
    var src = try Error.ArcStr.init(t.allocator, try t.allocator.dupeZ(u8, src_text));
    defer src.deinit();

    var err = Error.newStatic("Switch statement has duplicate cases");
    err.source_name = "test.zig";
    err.source = src;
    try err.labels.appendSlice(t.allocator, labels);
    defer err.labels.deinit(t.allocator);

    var graphical = GraphicalFormatter.unicode(t.allocator, false);
    var writer = std.Io.Writer.Allocating.init(t.allocator);
    defer writer.deinit();
    try graphical.format(&writer.writer, err);
    return dupeLf(t.allocator, writer.writer.buffered());
}

fn formatSpan(src_text: [:0]const u8, span: Span, comptime label: ?[]const u8) ![]u8 {
    return formatLabeledSpans(src_text, &.{.{
        .span = span,
        .primary = true,
        .label = if (label) |text| .static(text) else null,
    }});
}

test "single-line spans still use underlines" {
    const src = "const x = 1;\n";
    const out = try formatSpan(src, spanOf(src, "x"), null);
    defer t.allocator.free(out);
    try t.expectEqualStrings(
        \\  𝙭 Switch statement has duplicate cases
        \\   ╭─[test.zig:1:7]
        \\ 1 │ const x = 1;
        \\   ·       ─
        \\   ╰────
        \\
    , out);
}

test "multiline span uses left-hand arrows" {
    const src =
        \\fn foo() void {
        \\    const x = switch (1) {
        \\        1 => {
        \\            return;
        \\        },
        \\        else => {},
        \\    };
        \\}
    ;
    const body =
        \\{
        \\            return;
        \\        }
    ;
    const out = try formatSpan(src, spanOf(src, body), null);
    defer t.allocator.free(out);
    try t.expectEqualStrings(
        \\  𝙭 Switch statement has duplicate cases
        \\   ╭─[test.zig:3:14]
        \\ 2 │     const x = switch (1) {
        \\ 3 │ ╭─▶         1 => {
        \\ 4 │ │               return;
        \\ 5 │ ╰─▶         },
        \\ 6 │         else => {},
        \\   ╰────
        \\
    , out);
}

test "eight-line span does not omit middle lines" {
    const src =
        \\fn foo() void {
        \\    const x = switch (1) {
        \\        1 => {
        \\            if (true) {
        \\                const y = 1;
        \\                _ = y;
        \\                const z = 2;
        \\            }
        \\            return;
        \\        },
        \\        else => {},
        \\    };
        \\}
    ;
    const body =
        \\{
        \\            if (true) {
        \\                const y = 1;
        \\                _ = y;
        \\                const z = 2;
        \\            }
        \\            return;
        \\        }
    ;
    const out = try formatSpan(src, spanOf(src, body), null);
    defer t.allocator.free(out);
    try t.expectEqualStrings(
        \\  𝙭 Switch statement has duplicate cases
        \\    ╭─[test.zig:3:14]
        \\ 2  │     const x = switch (1) {
        \\ 3  │ ╭─▶         1 => {
        \\ 4  │ │               if (true) {
        \\ 5  │ │                   const y = 1;
        \\ 6  │ │                   _ = y;
        \\ 7  │ │                   const z = 2;
        \\ 8  │ │               }
        \\ 9  │ │               return;
        \\ 10 │ ╰─▶         },
        \\ 11 │         else => {},
        \\    ╰────
        \\
    , out);
}

test "large multiline span omits middle lines" {
    const src =
        \\fn foo() void {
        \\    const x = switch (1) {
        \\        1 => {
        \\            if (true) {
        \\                const y = 1;
        \\                _ = y;
        \\                const z = 2;
        \\                _ = z;
        \\            }
        \\            return;
        \\        },
        \\        else => {},
        \\    };
        \\}
    ;
    const body =
        \\{
        \\            if (true) {
        \\                const y = 1;
        \\                _ = y;
        \\                const z = 2;
        \\                _ = z;
        \\            }
        \\            return;
        \\        }
    ;
    const out = try formatSpan(src, spanOf(src, body), null);
    defer t.allocator.free(out);
    try t.expectEqualStrings(
        \\  𝙭 Switch statement has duplicate cases
        \\    ╭─[test.zig:3:14]
        \\ 2  │     const x = switch (1) {
        \\ 3  │ ╭─▶         1 => {
        \\ 4  │ │               if (true) {
        \\    · ┆
        \\ 10 │ │               return;
        \\ 11 │ ╰─▶         },
        \\ 12 │         else => {},
        \\    ╰────
        \\
    , out);
}

test "labeled multiline span uses lcross and label" {
    const src =
        \\fn foo() void {
        \\    const x = switch (1) {
        \\        1 => {
        \\            return;
        \\        },
        \\        else => {},
        \\    };
        \\}
    ;
    const body =
        \\{
        \\            return;
        \\        }
    ;
    const out = try formatSpan(src, spanOf(src, body), "this case");
    defer t.allocator.free(out);
    try t.expectEqualStrings(
        \\  𝙭 Switch statement has duplicate cases
        \\   ╭─[test.zig:3:14]
        \\ 2 │     const x = switch (1) {
        \\ 3 │ ╭─▶         1 => {
        \\ 4 │ │               return;
        \\ 5 │ ├─▶         },
        \\   · ╰──── this case
        \\ 6 │         else => {},
        \\   ╰────
        \\
    , out);
}

test "single-line underline on a multiline gutter line stays aligned" {
    const src =
        \\fn foo() void {
        \\    const x = switch (1) {
        \\        1 => {
        \\            return quux;
        \\        },
        \\        else => {},
        \\    };
        \\}
    ;
    const body =
        \\{
        \\            return quux;
        \\        }
    ;
    const out = try formatLabeledSpans(src, &.{
        .{ .span = spanOf(src, body), .primary = true, .label = null },
        .{ .span = spanOf(src, "quux"), .primary = false, .label = null },
    });
    defer t.allocator.free(out);
    try t.expectEqualStrings(
        \\  𝙭 Switch statement has duplicate cases
        \\   ╭─[test.zig:3:14]
        \\ 2 │     const x = switch (1) {
        \\ 3 │ ╭─▶         1 => {
        \\ 4 │ │               return quux;
        \\   ·                        ────
        \\ 5 │ ╰─▶         },
        \\ 6 │         else => {},
        \\   ╰────
        \\
    , out);
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
//     var buf = [3]Line{ .empty, .empty, .empty };
//     const lines_collected = contextFor(1, &buf, src, bar_loc);
//     try t.expectEqual(3, lines_collected);

//     try t.expectEqualStrings("    foo: u32 = undefined,", buf[0].contents);
//     try t.expectEqualStrings("    const Bar: u32 = 1;", buf[1].contents);
//     try t.expectEqualStrings("    fn baz(self: *Foo) void {", buf[2].contents);

//     try t.expectEqual(8, buf[0].num);
//     try t.expectEqual(9, buf[1].num);
//     try t.expectEqual(10, buf[2].num);
// }
