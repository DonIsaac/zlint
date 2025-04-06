//! Formats diagnostics in a such a way that they appear as annotations in
//! Github Actions.
//!
//! e.g.
//! ```
//! ::error file={name},line={line},endLine={endLine},title={title}::{message}
//! ```

const JSONFormatter = @This();

pub const meta: Meta = .{
    .report_statistics = false,
};

pub fn format(_: *JSONFormatter, w: *Writer, e: Error) FormatError!void {
    return std.json.stringify(e, .{}, w.*);
}

test JSONFormatter {
    const json = std.json;
    const allocator = std.testing.allocator;
    const expectEqualStrings = std.testing.expectEqualStrings;

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    var err = Error.newStatic("oof");
    defer err.deinit(allocator);
    err.help = Cow.static("help pls");
    err.code = "code";

    var f = JSONFormatter{};
    var w = buf.writer().any();
    try f.format(&w, err);

    var value = try json.parseFromSlice(json.Value, allocator, buf.items, .{});
    defer value.deinit();
    const obj = value.value.object;

    try expectEqualStrings("oof", obj.get("message").?.string);
    try expectEqualStrings("code", obj.get("code").?.string);
    try expectEqualStrings("help pls", obj.get("help").?.string);
}

const std = @import("std");
const Cow = @import("util").Cow(false);
const formatter = @import("../formatter.zig");
const Meta = formatter.Meta;
const FormatError = formatter.FormatError;
const Writer = std.io.AnyWriter;
const Error = @import("../../Error.zig");
const _span = @import("../../span.zig");
const LabeledSpan = _span.LabeledSpan;
const Location = _span.Location;
