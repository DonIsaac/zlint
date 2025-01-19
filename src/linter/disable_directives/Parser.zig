//! Parses disable directives from comments.

/// Full source text
source: []const u8,

// All fields below here are private and not initialized until parse() is
// called. No touchy.

/// Cursor pointer to current char in source code. This is a u32 index
/// instead of a pointer type as a size optimization.
///
/// @internal
cursor: usize,
/// @internal
span: Span,
/// @internal
kind: DisableDirectiveComment.Kind,
/// Stack allocated. Must be copied into newly-allocated directives.
///
/// @internal
rules: std.ArrayListUnmanaged(Span) = .{},

const DisableDirectivesParser = @This();
const MIN_LEN: u32 = "//zlint-disable".len;
/// Amount of stack space to reserve when parsing.
const STACK_FALLBACK_SIZE: usize = 2048;

pub fn new(source: []const u8) DisableDirectivesParser {
    assert(source.len > 0);
    // SAFETY: initialized at beginning of parsed(). These are private fields
    // that shouldn't be accessed externally: fuck around with abstraction
    // leaks and find out.
    return .{
        .source = source,
        // SAFETY: above
        .cursor = undefined,
        // SAFETY: above
        .kind = undefined,
        // SAFETY: above
        .span = undefined,
    };
}

/// ### Examples
/// - `// zlint-disable` - disable all rules for this file
/// - `// zlint-disable -- some comment` - same as above
/// - `// zlint-disable no-undefined` - disable "no-undefined" for the entire file
/// - `// zlint-disable foo bar baz` - disable "foo", "bar", and  "baz" for entire fil
/// - `// `ZLint-disable foo, bar, baz` - let user do their thing, if they want commas and caps that's fine
///
/// Disabling only on the next line works basically the same way
/// - `// zlint-disable-next-line` - disable violations for all rules on next line
/// - `// zlint-disable-next-line  -- no-undefined` same as above. `no-undefined` is treated as a comment
/// - `// zlint-disable-next-line no-undefined`
pub fn parse(self: *DisableDirectivesParser, allocator: Allocator, line_comment: Span) Allocator.Error!?DisableDirectiveComment {
    assert(self.source.len >= line_comment.end); // ensure line comment is within source code
    defer if (comptime util.IS_DEBUG) self.reset();

    // "//zlint-disable" is the smallest possible disable directive.
    if (line_comment.len() < MIN_LEN) return null;
    self.cursor = line_comment.start;
    self.span = line_comment;

    var fb = std.heap.stackFallback(STACK_FALLBACK_SIZE, allocator);
    const alloc = fb.get();
    defer {
        self.rules.deinit(alloc);
        self.rules = .{}; // Put rules back into a valid, empty state for the next parse.
    }

    // consume /\s*//[/!]?\s*/
    self.eatWhitespace(); // "\s*"
    self.eatMany("//", false) orelse return null; // "//"
    self.eat('!') orelse {}; // maybe '!' for module doc comments
    self.eat('/') orelse {}; // maybe '/' for 'normal' doc comments
    self.eatWhitespace(); // "\s*"

    // consume /zlint-disable[-next-line]/. determines directive kind.
    self.eatMany("zlint-disable", true) orelse return null;
    // returning .build() before this line is UB.
    self.kind = if (self.eatMany("-next-line", true)) |_| .line else .global;
    const ckpt = self.cursor;
    self.eatWhitespace();
    // short-circuit for global directives that disable all rules
    if (self.cursor >= self.span.end) {
        self.cursor = ckpt;
        return self.build(allocator);
    }
    // everything past '--' is a comment
    if (self.eatMany("--", false)) |_| {
        self.cursor = ckpt;
        return self.build(allocator);
    }

    while (self.cursor < self.span.end) {
        const start = self.cursor;
        while (self.cursor < self.span.end) : (self.cursor += 1) {
            switch (self.curr()) {
                'a'...'z', 'A'...'Z', '-' => {},
                else => break,
            }
        }
        self.cursor = @min(self.cursor, self.span.end);
        try self.rules.append(alloc, Span.new(@intCast(start), @intCast(self.cursor)));
        self.eat(',') orelse {};
        self.eatWhitespace();
    }
    return self.build(allocator);
}

fn build(self: *const DisableDirectivesParser, allocator: Allocator) Allocator.Error!?DisableDirectiveComment {
    var comment: DisableDirectiveComment = .{
        .kind = self.kind,
        .span = Span.new(self.span.start, @intCast(self.cursor)),
    };
    if (self.rules.items.len > 0) {
        comment.disabled_rules = try allocator.alloc(Span, self.rules.items.len);
        @memcpy(comment.disabled_rules, self.rules.items);
    }

    return comment;
}

/// Trim leading whitespace c`haracters starting from the cursor.
fn eatWhitespace(self: *DisableDirectivesParser) void {
    const whitespace = std.ascii.whitespace;
    while (self.cursor < self.span.end and std.mem.indexOfScalar(u8, &whitespace, self.curr()) != null) : (self.cursor += 1) {}
}

/// Move the cursor forward if the next character is `expected`. Otherwise
/// the cursor is not modified and `null` is returned.
fn eat(self: *DisableDirectivesParser, expected: u8) ?void {
    if (self.cursor >= self.span.end) return null;

    if (self.curr() == expected) {
        self.cursor += 1;
        return;
    } else {
        return null;
    }
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

fn remaining(self: *const DisableDirectivesParser) []const u8 {
    self.assertInRange();
    return self.source[self.cursor..self.span.end];
}

/// Inlined so LLVM can optimize away bounds-related safety checks.
inline fn assertInRange(self: *const DisableDirectivesParser) void {
    assert(self.cursor < self.source.len);
    assert(self.cursor < self.span.end);
}

fn reset(self: *DisableDirectivesParser) void {
    self.cursor = undefined;
    // SAFETY: this is a destructor
    self.kind = undefined;
    // SAFETY: this is a destructor
    self.span = undefined;
}

const t = std.testing;
const Tuple = std.meta.Tuple;
test {
    t.refAllDecls(DisableDirectivesParser);
}

test parse {
    const ExpectedDisableDisableDirectives = []const []const u8;
    const TestCase = Tuple(&[_]type{ []const u8, ?DisableDirectiveComment, ExpectedDisableDisableDirectives });
    const cases = &[_]TestCase{
        // global directives
        TestCase{ "//zlint-disable", .{ .kind = .global, .span = .{ .start = 0, .end = 15 } }, &[_][]const u8{} },
        TestCase{ "// zlint-disable", .{ .kind = .global, .span = .{ .start = 0, .end = 16 } }, &[_][]const u8{} },
        TestCase{ "// zlint-disable -- no-undefined", .{ .kind = .global, .span = .{ .start = 0, .end = 16 } }, &[_][]const u8{} },
        TestCase{ "// zlint-disable no-undefined", .{
            .kind = .global,
            .span = .{ .start = 0, .end = 29 },
            .disabled_rules = @constCast(&[_]Span{Span.new(17, 29)}),
        }, &[_][]const u8{
            "no-undefined",
        } },
        TestCase{ "// zlint-disable foo bar baz", .{
            .kind = .global,
            .span = .{ .start = 0, .end = 28 },
            .disabled_rules = @constCast(&[_]Span{
                Span.new(17, 20),
                Span.new(21, 24),
                Span.new(25, 28),
            }),
        }, &[_][]const u8{ "foo", "bar", "baz" } },
    };

    for (cases) |case| {
        const source, const expected, const expected_disabled_directives = case;
        var parser = DisableDirectivesParser.new(source);
        var actual = try parser.parse(t.allocator, Span.new(0, @intCast(source.len)));
        if (actual) |*a| {
            defer a.deinit(t.allocator);
            const e: DisableDirectiveComment = expected.?;
            try t.expectEqual(e.kind, a.kind);
            try t.expectEqual(e.span, a.span);
            try t.expectEqualSlices(Span, e.disabled_rules, a.disabled_rules);

            for (0.., expected_disabled_directives) |idx, expected_disabled_directive| {
                try t.expectEqualStrings(
                    expected_disabled_directive,
                    source[a.disabled_rules[idx].start..a.disabled_rules[idx].end],
                );
            }

            // try t.expectEqual(expected, a);
        } else {
            try t.expectEqual(expected, actual);
        }
        // defer if (actual) |*a| a.deinit(t.allocator);
        // try t.expectEqual(expected.kind, actual.k);
        // try t.expectEqual(expected, actual);
    }
}

test {
    _ = @import("./Parser_test.zig");
}

test eatWhitespace {
    const TestCase = Tuple(&[_]type{ []const u8, []const u8 });
    const cases: []const TestCase = &[_]TestCase{
        TestCase{ "", "" },
        TestCase{ " ", "" },
        TestCase{ "\n", "" },
        TestCase{ "foo", "foo" },
        TestCase{ "bar  ", "bar  " },
        TestCase{ "\n\tbaz", "baz" },
        TestCase{ "    baz", "baz" },
        TestCase{ "foo bar", "foo bar" },
    };

    for (cases) |case| {
        const source, const expected = case;

        var p: DisableDirectivesParser = undefined;
        p.source = source;
        p.span = Span.new(0, @intCast(source.len));
        p.cursor = 0;
        p.eatWhitespace();
        try t.expect(p.cursor <= p.span.end);
        try t.expectEqualStrings(expected, p.source[p.cursor..p.span.end]);
    }
}

const std = @import("std");
const util = @import("util");
const ascii = std.ascii;
const mem = std.mem;

const Span = @import("../../span.zig").Span;
const Allocator = mem.Allocator;

const assert = std.debug.assert;

pub const DisableDirectiveComment = @import("./Comment.zig");
