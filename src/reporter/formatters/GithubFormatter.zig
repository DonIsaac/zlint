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

pub fn format(_: *GithubFormatter, w: *Writer, e: Error) FormatError!void {
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

const std = @import("std");
const formatter = @import("../formatter.zig");
const Meta = formatter.Meta;
const FormatError = formatter.FormatError;
const Writer = std.io.AnyWriter;
const Error = @import("../../Error.zig");
const _span = @import("../../span.zig");
const LabeledSpan = _span.LabeledSpan;
const Location = _span.Location;
