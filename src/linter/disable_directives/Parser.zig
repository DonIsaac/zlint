//! Parses disable directives from comments.

/// Full source text
source: []const u8,

// All fields below here are private and not initialized until parse() is
// called. No touchy.

/// Cursor pointer to current char in source code.
///
/// @internal
cursor: usize,
/// @internal
span: Span,

const DisableDirectivesParser = @This();
const MIN_LEN: u32 = "//zlint-disable".len;

pub fn new(source: []const u8) DisableDirectivesParser {
    return .{
        .source = source,
        // SAFETY: initialized at the beginning of parse(). These are private
        // fields that shouldn't be accessed externally.
        .cursor = undefined,
        // SAFETY: above
        .span = undefined,
    };
}

/// Parse a line comment into a disable directive. Returns `null` if the
/// comment is not a directive. Does not allocate.
///
/// ### Examples
/// - `// zlint-disable` - disable all rules for this file
/// - `// zlint-disable -- some comment` - same as above
/// - `// zlint-disable unsafe-undefined` - disable "unsafe-undefined" for the entire file
/// - `// zlint-disable foo bar baz` - disable "foo", "bar", and  "baz" for entire file
/// - `// ZLint-disable foo, bar, baz` - let user do their thing, if they want commas and caps that's fine
///
/// Disabling only on the next line or the current line works the same way
/// - `// zlint-disable-next-line` - disable violations for all rules on next line
/// - `// zlint-disable-next-line  -- unsafe-undefined` same as above. `unsafe-undefined` is treated as a comment
/// - `// zlint-disable-next-line unsafe-undefined`
/// - `foo(); // zlint-disable-line unsafe-undefined`
pub fn parse(self: *DisableDirectivesParser, line_comment: Span) ?DisableDirectiveComment {
    assert(self.source.len >= line_comment.end); // ensure line comment is within source code

    // "//zlint-disable" is the smallest possible disable directive.
    if (line_comment.len() < MIN_LEN) return null;
    self.cursor = line_comment.start;
    self.span = line_comment;

    // consume /\s*//[/!]?\s*/
    self.eatWhitespace(); // "\s*"
    if (self.cursor == self.span.end or (self.span.end - self.cursor) < MIN_LEN) {
        @branchHint(.unlikely);
        return null;
    }
    self.eatMany("//", false) orelse return null; // "//"
    switch (self.curr()) {
        // never out of bounds b/c of len check after whitespace
        '!', // maybe a module doc comment
        '/', // maybe a container/fn doc comment
        => self.cursor += 1,
        else => {},
    }
    self.eatWhitespace(); // "\s*"

    // consume /zlint-disable(-next-line|-line)?/. determines directive kind.
    self.eatMany("zlint-disable", true) orelse return null;
    const kind: DisableDirectiveComment.Kind = if (self.eatMany("-next-line", true)) |_|
        .next_line
    else if (self.eatMany("-line", true)) |_|
        .same_line
    else
        .global;

    // The keyword must end at a word boundary. This rejects things like
    // `zlint-disable-lines` and `zlint-disablefoo`.
    if (self.cursor < self.span.end) switch (self.curr()) {
        ',' => {},
        '-' => if (self.peek() != '-') return null,
        else => |c| if (!std.ascii.isWhitespace(c)) return null,
    };

    const keyword_end: u32 = @intCast(self.cursor);
    // Rule names can't contain `--`, so the first one starts the explanation.
    const list_end: u32 = if (mem.indexOfPos(u8, self.source[0..self.span.end], keyword_end, "--")) |i| @intCast(i) else self.span.end;
    // Any text in the list, even if it has no valid rule names, means the user
    // meant to disable specific rules. Treating it as "all rules" would hide
    // far more than intended.
    const separators = ascii.whitespace ++ ",";
    const list = mem.trim(u8, self.source[keyword_end..list_end], separators);
    if (list.len == 0) return .{ .kind = kind, .span = .new(self.span.start, keyword_end) };

    const list_start: u32 = @intCast(list.ptr - self.source.ptr);
    const rules: Span = .new(list_start, list_start + @as(u32, @intCast(list.len)));
    return .{ .kind = kind, .span = .new(self.span.start, rules.end), .rules = rules };
}

/// Trim leading whitespace characters starting from the cursor.
fn eatWhitespace(self: *DisableDirectivesParser) void {
    while (self.cursor < self.span.end and std.ascii.isWhitespace(self.curr())) : (self.cursor += 1) {}
}

/// Safely read the next character. Returns `null` if we're at the end of the
/// source slice.
inline fn peek(self: *const DisableDirectivesParser) ?u8 {
    const next_pos = self.cursor + 1;
    if (next_pos >= self.span.end) {
        @branchHint(.unlikely);
        return null;
    }
    return self.source[next_pos];
}

/// Try to consume a slice. If found, the cursor is moved past `expected`,
/// otherwise returns `null`.
fn eatMany(self: *DisableDirectivesParser, comptime expected: []const u8, comptime ignore_case: bool) ?void {
    if (self.cursor + expected.len > self.span.end) return null;

    const actual = self.source[self.cursor..(self.cursor + expected.len)];
    const is_match = if (comptime ignore_case) ascii.eqlIgnoreCase(actual, expected) else mem.eql(u8, actual, expected);
    return if (is_match) {
        self.cursor += expected.len;
    } else null;
}

inline fn curr(self: *const DisableDirectivesParser) u8 {
    return self.source[self.cursor];
}

const t = std.testing;
test {
    t.refAllDecls(DisableDirectivesParser);
    _ = @import("./Parser_test.zig");
}

test eatWhitespace {
    const TestCase = struct { []const u8, []const u8 };
    const cases: []const TestCase = &[_]TestCase{
        .{ "", "" },
        .{ " ", "" },
        .{ "\n", "" },
        .{ "foo", "foo" },
        .{ "bar  ", "bar  " },
        .{ "\n\tbaz", "baz" },
        .{ "    baz", "baz" },
        .{ "foo bar", "foo bar" },
    };

    for (cases) |case| {
        const source, const expected = case;

        var p: DisableDirectivesParser = .new(source);
        p.span = Span.new(0, @intCast(source.len));
        p.cursor = 0;
        p.eatWhitespace();
        try t.expect(p.cursor <= p.span.end);
        try t.expectEqualStrings(expected, p.source[p.cursor..p.span.end]);
    }
}

const std = @import("std");
const ascii = std.ascii;
const mem = std.mem;

const Span = @import("../../span.zig").Span;

const assert = std.debug.assert;

const DisableDirectiveComment = @import("./Comment.zig");
