const std = @import("std");
const DisableDirectivesParser = @import("./Parser.zig");
const DisableDirectiveComment = @import("./Comment.zig");
const Span = @import("../../span.zig").Span;

const Tuple = std.meta.Tuple;
const t = std.testing;
const print = std.debug.print;

const TestCase = struct {
    src: []const u8,
    expected: ?DisableDirectiveComment,
    /// When `false`, `actual.span` is not compared to `expected.span`.
    check_span: bool = false,
};

/// For when you don't care about the parsed comment's span
const NULL_SPAN = Span{ .start = 0, .end = 0 };

fn runTests(cases: []const TestCase) !void {
    for (cases) |case| {
        // const source, const expected = case;
        const source = case.src;
        const expected = case.expected;
        const check_span = case.check_span;

        var parser = DisableDirectivesParser.new(source);
        var actual = try parser.parse(t.allocator, Span.new(0, @intCast(source.len)));
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
        .{ .src = "//zlint-disable", .expected = .{ .kind = .global, .span = .{ .start = 0, .end = 15 } }, .check_span = true },
        .{ .src = "// zlint-disable", .expected = .{ .kind = .global, .span = .{ .start = 0, .end = 16 } }, .check_span = true },
        .{ .src = "// zlint-disable            ", .expected = .{ .kind = .global, .span = .{ .start = 0, .end = 16 } }, .check_span = true },
        .{ .src = "   //     zlint-disable", .expected = .{ .kind = .global, .span = .{ .start = 0, .end = 23 } }, .check_span = true },
    };
    try runTests(cases);
}

test "line directives that disable all rules" {
    const cases = &[_]TestCase{
        .{ .src = "// zlint-disable-next-line", .expected = .{ .kind = .line, .span = .{ .start = 0, .end = 26 } }, .check_span = true },
        .{ .src = "// zlint-disable-next-line            ", .expected = .{ .kind = .line, .span = .{ .start = 0, .end = 26 } }, .check_span = true },
        .{ .src = "   //     zlint-disable-next-line", .expected = .{ .kind = .line, .span = .{ .start = 0, .end = 33 } }, .check_span = true },
    };
    try runTests(cases);
}

test "comments" {
    const global: DisableDirectiveComment = .{ .kind = .global, .span = NULL_SPAN };
    const line: DisableDirectiveComment = .{ .kind = .line, .span = NULL_SPAN };

    const cases = &[_]TestCase{
        .{ .src = "// zlint-disable -- no-undefined", .expected = global },
        .{ .src = "// zlint-disable-next-line -- no-undefined", .expected = line },
        .{ .src = "// zlint-disable --", .expected = global },
        .{ .src = "// zlint-disable -- foo bar baz", .expected = global },
        .{ .src = "// zlint-disable     --   foo bar baz", .expected = global },
    };

    try runTests(cases);
}

test "not a disable directive" {
    const cases = &[_]TestCase{
        .{ .src = "//", .expected = null },
        .{ .src = "// foo", .expected = null },
        .{ .src = "// foo foo foo foo foo foo foo foo foo foo", .expected = null },
        .{ .src = "// foo zlint-disable", .expected = null },
        .{ .src = "zlint-disable no-undefined", .expected = null },
    };
    try runTests(cases);
}

test "disable directives may be in doc comments" {
    const cases = &[_]TestCase{
        .{ .src = "//  zlint-disable", .expected = .{ .kind = .global, .span = NULL_SPAN } },
        .{ .src = "/// zlint-disable", .expected = .{ .kind = .global, .span = NULL_SPAN } },
        .{ .src = "//! zlint-disable", .expected = .{ .kind = .global, .span = NULL_SPAN } },
    };
    try runTests(cases);
}

test "disabling specific rules" {
    const cases = &[_]TestCase{
        .{
            .src = "// zlint-disable foo bar baz",
            .expected = .{
                .kind = .global,
                .span = NULL_SPAN,
                .disabled_rules = @constCast(&[_]Span{
                    Span.new(17, 21),
                    Span.new(21, 25),
                    Span.new(25, 28),
                }),
            },
        },
        .{
            .src = "// zlint-disable foo, bar, baz",
            .expected = .{
                .kind = .global,
                .span = NULL_SPAN,
                .disabled_rules = @constCast(&[_]Span{
                    Span.new(17, 21),
                    Span.new(22, 26),
                    Span.new(27, 30),
                }),
            },
        },
    };
    try runTests(cases);
}
