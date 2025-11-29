//! Formats diagnostics in a such a way that they appear as annotations in
//! Github Actions.
//!
//! e.g.
//! ```
//! ::error file={name},line={line},endLine={endLine},title={title}::{message}
//! ```

const GithubFormatter = @This();

pub const meta: Meta = .{
    .report_statistics = false,
};

pub fn format(_: *GithubFormatter, w: *io.Writer, e: Error) FormatError!void {
    const level: []const u8 = switch (e.severity) {
        .err => "error",
        .warning => "warning",
        .notice => "notice",
        .off => @panic("disabled error passed to formatter"),
    };

    const primary: ?LabeledSpan = blk: {
        if (e.labels.items.len == 0) break :blk null;
        for (e.labels.items) |label| {
            if (label.primary) break :blk label;
        }
        break :blk e.labels.items[0];
    };

    const line, const col = blk: {
        if (primary) |p| {
            if (e.source) |source| {
                const loc = Location.fromSpan(source.deref().*, p.span);
                break :blk .{ loc.line, loc.column };
            }
        }
        break :blk .{ 1, 1 };
    };

    // TODO: endLine, endCol
    try w.print("::{s} file={s},line={d},col={d},title={s}::{s}\n", .{
        level,
        e.source_name orelse "<unknown>",
        line,
        col,
        e.code,
        e.message,
    });
}

test GithubFormatter {
    const Cow = @import("util").Cow(false);
    const allocator = std.testing.allocator;
    const expectEqualStrings = std.testing.expectEqualStrings;

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    var f = GithubFormatter{};
    // var w = buf.writer();
    var w = std.io.Writer.Allocating.init(allocator);
    defer w.writer.flush() catch @panic("failed to flush writer");
    defer w.deinit();

    var err = Error.newStatic("Something happened");
    err.help = Cow.static("help pls");
    err.code = "code";
    err.source_name = "some/file.zig";

    try f.format(&w, err);
    try expectEqualStrings("::error file=some/file.zig,line=1,col=1,title=code::Something happened\n", buf.items);

    buf.clearRetainingCapacity();
    err.severity = .warning;
    try err.labels.append(allocator, .{
        .label = Cow.static("here it is"),
        .span = .{ .start = 5, .end = 10 },
    });
    defer err.labels.deinit(allocator);

    try f.format(&w, err);
    try expectEqualStrings("::warning file=some/file.zig,line=1,col=1,title=code::Something happened\n", buf.items);

    buf.clearRetainingCapacity();
    var src = try Error.ArcStr.init(
        allocator,
        try allocator.dupeZ(u8,
            \\
            \\foo bar baz bang
        ),
    );
    defer src.deinit();
    err.source = src;

    try f.format(&w, err);
    try expectEqualStrings("::warning file=some/file.zig,line=2,col=5,title=code::Something happened\n", buf.items);
}

const std = @import("std");
const io = std.io;
const formatter = @import("../formatter.zig");
const Meta = formatter.Meta;
const FormatError = formatter.FormatError;
const Error = @import("../../Error.zig");
const _span = @import("../../span.zig");
const LabeledSpan = _span.LabeledSpan;
const Location = _span.Location;
