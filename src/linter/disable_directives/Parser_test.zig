const std = @import("std");
const Span = @import("../../span.zig").Span;
const DisableDirectiveComment = @import("./Comment.zig");
const DisableDirectivesParser = @import("./Parser.zig");

const t = std.testing;
const print = std.debug.print;

const Expected = struct {
    kind: DisableDirectiveComment.Kind,
    span: Span = .empty,
    /// Expected rule names. `null` means all rules are disabled.
    rules: ?[]const []const u8 = null,
};

const TestCase = struct {
    src: []const u8,
    expected: ?Expected,
    /// When `false`, `actual.span` is not compared to `expected.span`.
    check_span: bool = false,
};

fn global(span: Span) Expected {
    return .{ .kind = .global, .span = span };
}

fn nextLine(span: Span) Expected {
    return .{ .kind = .next_line, .span = span };
}

fn sameLine(span: Span) Expected {
    return .{ .kind = .same_line, .span = span };
}

fn runTests(cases: []const TestCase) !void {
    for (cases) |case| {
        runTest(case) catch |err| {
            print("\nSource: '{s}'\n", .{case.src});
            return err;
        };
    }
}

fn runTest(case: TestCase) !void {
    const source = case.src;
    var parser = DisableDirectivesParser.new(source);
    const actual = parser.parse(.new(0, @intCast(source.len)));
    const expected = case.expected orelse return t.expectEqual(null, actual);
    const a = actual orelse return error.TestExpectedDirective;

    try t.expectEqual(expected.kind, a.kind);
    if (case.check_span) try t.expectEqual(expected.span, a.span);
    const expected_rules = expected.rules orelse return t.expect(a.disablesAllRules());
    try t.expect(!a.disablesAllRules());

    var names = a.ruleNames(source);
    for (expected_rules) |expected_name| {
        const name = names.next() orelse return error.TestExpectedRuleName;
        try t.expectEqualStrings(expected_name, name.snippet(source));
    }
    try t.expectEqual(null, names.next());
}

test "global directives that disable all rules" {
    const cases = &[_]TestCase{
        .{ .src = "//zlint-disable", .expected = global(.new(0, 15)), .check_span = true },
        .{ .src = "// zlint-disable", .expected = global(.new(0, 16)), .check_span = true },
        .{ .src = "// zlint-disable            ", .expected = global(.new(0, 16)), .check_span = true },
        .{ .src = "   //     zlint-disable", .expected = global(.new(0, 23)), .check_span = true },
        .{ .src = "// ZLINT-DISABLE", .expected = global(.new(0, 16)), .check_span = true },
    };
    try runTests(cases);
}

test "next-line directives that disable all rules" {
    const cases = &[_]TestCase{
        .{ .src = "// zlint-disable-next-line", .expected = nextLine(.new(0, 26)), .check_span = true },
        .{ .src = "// zlint-disable-next-line            ", .expected = nextLine(.new(0, 26)), .check_span = true },
        .{ .src = "   //     zlint-disable-next-line", .expected = nextLine(.new(0, 33)), .check_span = true },
        .{ .src = "// zlint-disable-Next-Line", .expected = nextLine(.new(0, 26)), .check_span = true },
        .{ .src = "// zlint-disable-next-line\r", .expected = nextLine(.new(0, 26)), .check_span = true },
        .{ .src = "//!zlint-disable-next-line", .expected = nextLine(.new(0, 26)), .check_span = true },
    };
    try runTests(cases);
}

test "same-line directives that disable all rules" {
    const cases = &[_]TestCase{
        .{ .src = "// zlint-disable-line", .expected = sameLine(.new(0, 21)), .check_span = true },
        .{ .src = "// zlint-disable-line            ", .expected = sameLine(.new(0, 21)), .check_span = true },
        .{ .src = "   //     zlint-disable-line", .expected = sameLine(.new(0, 28)), .check_span = true },
        .{ .src = "// zlint-disable-line\r", .expected = sameLine(.new(0, 21)), .check_span = true },
        .{ .src = "// ZLINT-DISABLE-LINE", .expected = sameLine(.new(0, 21)), .check_span = true },
        .{ .src = "\t//\tzlint-disable-line", .expected = sameLine(.new(0, 22)), .check_span = true },
    };
    try runTests(cases);
}

test "comments" {
    const cases = &[_]TestCase{
        .{ .src = "// zlint-disable -- unsafe-undefined", .expected = global(.new(0, 16)), .check_span = true },
        .{ .src = "// zlint-disable-next-line -- unsafe-undefined", .expected = nextLine(.new(0, 26)), .check_span = true },
        .{ .src = "// zlint-disable-line -- unsafe-undefined", .expected = sameLine(.new(0, 21)), .check_span = true },
        .{ .src = "// zlint-disable --", .expected = global(.empty) },
        .{ .src = "// zlint-disable -- foo bar baz", .expected = global(.empty) },
        .{ .src = "// zlint-disable-- foo bar baz", .expected = global(.empty) },
        .{ .src = "// zlint-disable-line-- foo bar baz", .expected = sameLine(.empty) },
        .{ .src = "// zlint-disable --foo bar baz", .expected = global(.empty) },
        .{ .src = "// zlint-disable     --   foo bar baz", .expected = global(.empty) },
        .{ .src = "// zlint-disable , -- foo", .expected = global(.empty) },
        .{ .src = "// zlint-disable ---", .expected = global(.empty) },
        .{ .src = "// zlint-disable-line foo--bar", .expected = .{ .kind = .same_line, .rules = &.{"foo"} } },
        .{ .src = "// zlint-disable foo -- bar -- baz", .expected = .{ .kind = .global, .rules = &.{"foo"} } },
        // space omission: rule name directly followed by '--' (no space before comment marker)
        .{
            .src = "// zlint-disable-next-line unsafe-undefined-- now heres a comment",
            .expected = .{ .kind = .next_line, .span = .new(0, 43), .rules = &.{"unsafe-undefined"} },
            .check_span = true,
        },
        // everything after `--` is a comment, even if separated by other junk
        .{
            .src = "// zlint-disable foo 42 --bar",
            .expected = .{ .kind = .global, .rules = &.{ "foo", "42" } },
        },
    };

    try runTests(cases);
}

test "not a disable directive" {
    const cases = &[_]TestCase{
        .{ .src = "//", .expected = null },
        .{ .src = "// foo", .expected = null },
        .{ .src = "// foo foo foo foo foo foo foo foo foo foo", .expected = null },
        .{ .src = "// foo zlint-disable", .expected = null },
        .{ .src = "zlint-disable unsafe-undefined", .expected = null },
        // directive keywords must end at a word boundary
        .{ .src = "// zlint-disablefoo", .expected = null },
        .{ .src = "// zlint-disable-foo", .expected = null },
        .{ .src = "// zlint-disable-lines", .expected = null },
        .{ .src = "// zlint-disable-next-lines", .expected = null },
        .{ .src = "// zlint-disable-next", .expected = null },
        .{ .src = "// zlint-disable-line_foo", .expected = null },
        .{ .src = "// zlint-disable-line-", .expected = null },
        .{ .src = "// zlint-disable-next-line-foo", .expected = null },
        .{ .src = "// zlint-disable:foo", .expected = null },
        // only one extra slash is part of the comment marker
        .{ .src = "////zlint-disable", .expected = null },
    };
    try runTests(cases);
}

test "disable directives may be in doc comments" {
    const cases = &[_]TestCase{
        .{ .src = "//  zlint-disable", .expected = global(.empty) },
        .{ .src = "/// zlint-disable", .expected = global(.empty) },
        .{ .src = "//! zlint-disable", .expected = global(.empty) },
        .{ .src = "/// zlint-disable-next-line", .expected = nextLine(.empty) },
    };
    try runTests(cases);
}

test "disabling specific rules" {
    const cases = &[_]TestCase{
        .{
            .src = "// zlint-disable unsafe-undefined",
            .expected = .{ .kind = .global, .span = .new(0, 33), .rules = &.{"unsafe-undefined"} },
            .check_span = true,
        },
        .{
            .src = "// zlint-disable foo bar baz",
            .expected = .{ .kind = .global, .span = .new(0, 28), .rules = &.{ "foo", "bar", "baz" } },
            .check_span = true,
        },
        .{
            .src = "// zlint-disable foo, bar, baz",
            .expected = .{ .kind = .global, .rules = &.{ "foo", "bar", "baz" } },
        },
        .{
            .src = "// zlint-disable,foo,bar",
            .expected = .{ .kind = .global, .rules = &.{ "foo", "bar" } },
        },
        .{
            .src = "// zlint-disable-next-line foo, bar -- because",
            .expected = .{ .kind = .next_line, .span = .new(0, 35), .rules = &.{ "foo", "bar" } },
            .check_span = true,
        },
        .{
            .src = "// zlint-disable-line no-unresolved unused-decls",
            .expected = .{ .kind = .same_line, .rules = &.{ "no-unresolved", "unused-decls" } },
        },
        .{
            .src = "// zlint-disable-line\tfoo,\t bar ,,baz\r",
            .expected = .{ .kind = .same_line, .rules = &.{ "foo", "bar", "baz" } },
        },
        .{
            // the span ends at the last rule name, not at trailing separators
            .src = "// zlint-disable foo, ",
            .expected = .{ .kind = .global, .span = .new(0, 20), .rules = &.{"foo"} },
            .check_span = true,
        },
    };
    try runTests(cases);
}

test "characters that cannot be in a rule name are skipped" {
    const cases = &[_]TestCase{
        .{ .src = "// zlint-disable-line #123 -- see issue", .expected = .{ .kind = .same_line, .rules = &.{"123"} } },
        .{ .src = "// zlint-disable _foo", .expected = .{ .kind = .global, .rules = &.{"foo"} } },
        .{ .src = "// zlint-disable foo_bar", .expected = .{ .kind = .global, .rules = &.{ "foo", "bar" } } },
        .{ .src = "// zlint-disable #", .expected = .{ .kind = .global, .rules = &.{} } },
    };
    try runTests(cases);
}

test "rule names may contain digits" {
    const cases = &[_]TestCase{
        .{ .src = "// zlint-disable no-u8-cast", .expected = .{ .kind = .global, .rules = &.{"no-u8-cast"} } },
        .{ .src = "// zlint-disable foo 42 bar", .expected = .{ .kind = .global, .rules = &.{ "foo", "42", "bar" } } },
    };
    try runTests(cases);
}

test "empty comments" {
    const cases = &[_]TestCase{
        .{ .src = "//", .expected = null },
        .{ .src = "///", .expected = null },
        .{ .src = "//!", .expected = null },
        .{ .src = "// ", .expected = null },
        .{ .src = "/// ", .expected = null },
        .{ .src = "//! ", .expected = null },
    };
    try runTests(cases);
}

test "parsing a comment within a larger source" {
    const source = "const x = 1; // zlint-disable-line foo\nconst y = 2;";
    const comment_start = std.mem.indexOf(u8, source, "//").?;
    const comment_end = std.mem.indexOfScalar(u8, source, '\n').?;
    var parser = DisableDirectivesParser.new(source);
    const directive = parser.parse(.new(@intCast(comment_start), @intCast(comment_end))).?;
    try t.expectEqual(.same_line, directive.kind);
    try t.expectEqualStrings("// zlint-disable-line foo", directive.span.snippet(source));
    try t.expectEqualStrings("foo", directive.rules.snippet(source));
}
