const std = @import("std");
const DisableDirectivesParser = @import("./Parser.zig");
const DisableDirectiveComment = @import("./Comment.zig");
const Span = @import("../../span.zig").Span;

const t = std.testing;
const print = std.debug.print;

const TestCase = struct {
    src: []const u8,
    expected: ?DisableDirectiveComment,
    /// When `false`, `actual.span` is not compared to `expected.span`.
    check_span: bool = false,
};

fn global(span: Span) DisableDirectiveComment {
    return .{ .kind = .global, .span = span };
}

fn line(span: Span) DisableDirectiveComment {
    return .{ .kind = .line, .span = span };
}

fn runTests(cases: []const TestCase) !void {
    for (cases) |case| {
        // const source, const expected = case;
        const source = case.src;
        const expected = case.expected;
        const check_span = case.check_span;

        var parser = DisableDirectivesParser.new(source);
        var actual = try parser.parse(t.allocator, .new(0, @intCast(source.len)));
        if (actual) |*a| {
            defer a.deinit(t.allocator);
            const e: DisableDirectiveComment = expected.?;

            t.expectEqual(e.kind, a.kind) catch |err| {
                print("\nSource: '{s}'\n", .{source});
                return err;
            };

            if (check_span) {
                t.expectEqual(e.span, a.span) catch |err| {
                    print("\nSource: '{s}'\n", .{source});
                    return err;
                };
            }

            t.expectEqualSlices(Span, e.disabled_rules, a.disabled_rules) catch |err| {
                print("\nSource: '{s}'\n", .{source});
                return err;
            };
        } else {
            t.expectEqual(expected, actual) catch |err| {
                print("\nSource: '{s}'\n", .{source});
                return err;
            };
        }
    }
}

test "global directives that disable all rules" {
    const cases = &[_]TestCase{
        .{ .src = "//zlint-disable", .expected = global(.new(0, 15)), .check_span = true },
        .{ .src = "// zlint-disable", .expected = global(.new(0, 16)), .check_span = true },
        .{ .src = "// zlint-disable            ", .expected = global(.new(0, 16)), .check_span = true },
        .{ .src = "   //     zlint-disable", .expected = global(.new(0, 23)), .check_span = true },
    };
    try runTests(cases);
}

test "line directives that disable all rules" {
    const cases = &[_]TestCase{
        .{ .src = "// zlint-disable-next-line", .expected = line(.new(0, 26)), .check_span = true },
        .{ .src = "// zlint-disable-next-line            ", .expected = line(.new(0, 26)), .check_span = true },
        .{ .src = "   //     zlint-disable-next-line", .expected = line(.new(0, 33)), .check_span = true },
    };
    try runTests(cases);
}

test "comments" {
    const cases = &[_]TestCase{
        .{ .src = "// zlint-disable -- unsafe-undefined", .expected = global(.empty) },
        .{ .src = "// zlint-disable-next-line -- unsafe-undefined", .expected = line(.empty) },
        .{ .src = "// zlint-disable --", .expected = global(.empty) },
        .{ .src = "// zlint-disable -- foo bar baz", .expected = global(.empty) },
        .{ .src = "// zlint-disable-- foo bar baz", .expected = global(.empty) },
        .{ .src = "// zlint-disable --foo bar baz", .expected = global(.empty) },
        .{ .src = "// zlint-disable     --   foo bar baz", .expected = global(.empty) },
        // space omission: rule name directly followed by '--' (no space before comment marker)
        .{
            .src = "// zlint-disable-next-line unsafe-undefined-- now heres a comment",
            .expected = .{
                .kind = .line,
                .span = .empty,
                .disabled_rules = @constCast(&[_]Span{.new(27, 43)}),
            },
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
    };
    try runTests(cases);
}

test "disable directives may be in doc comments" {
    const expected = global(.empty);
    const cases = &[_]TestCase{
        .{ .src = "//  zlint-disable", .expected = expected },
        .{ .src = "/// zlint-disable", .expected = expected },
        .{ .src = "//! zlint-disable", .expected = expected },
    };
    try runTests(cases);
}

test "disabling specific rules" {
    const cases = &[_]TestCase{
        .{
            .src = "// zlint-disable foo bar baz",
            .expected = .{
                .kind = .global,
                .span = .empty,
                .disabled_rules = @constCast(&[_]Span{
                    .new(17, 20),
                    .new(21, 24),
                    .new(25, 28),
                }),
            },
        },
        .{
            .src = "// zlint-disable foo, bar, baz",
            .expected = .{
                .kind = .global,
                .span = .empty,
                .disabled_rules = @constCast(&[_]Span{
                    .new(17, 20),
                    .new(22, 25),
                    .new(27, 30),
                }),
            },
        },
    };
    try runTests(cases);
}

test "non-letter characters in rule list do not cause infinite loop" {
    // Digits, underscores, and other non-letter/non-hyphen characters are not
    // valid in rule names. The parser must skip them rather than loop forever
    // on a zero-length token.
    const cases = &[_]TestCase{
        // pure digit token — skipped entirely, no rules parsed
        .{
            .src = "// zlint-disable 123",
            .expected = global(.empty),
        },
        // leading underscore is skipped; "foo" is still captured
        .{
            .src = "// zlint-disable _foo",
            .expected = .{
                .kind = .global,
                .span = .empty,
                .disabled_rules = @constCast(&[_]Span{.new(18, 21)}),
            },
        },
        // valid rule name preceded by digit garbage — digit skipped, rule captured
        .{
            .src = "// zlint-disable 1foo",
            .expected = .{
                .kind = .global,
                .span = .empty,
                .disabled_rules = @constCast(&[_]Span{.new(18, 21)}),
            },
        },
        // valid rule mixed with an all-digit token
        .{
            .src = "// zlint-disable foo 42 bar",
            .expected = .{
                .kind = .global,
                .span = .empty,
                .disabled_rules = @constCast(&[_]Span{
                    .new(17, 20),
                    .new(24, 27),
                }),
            },
        },
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
