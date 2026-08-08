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

pub fn format(_: *JSONFormatter, w: *io.Writer, e: Error) FormatError!void {
    var json = std.json.Stringify{ .writer = w };
    try json.write(e);
}

test JSONFormatter {
    const Source = @import("../../source.zig").Source;
    const json = std.json;
    const Value = json.Value;
    const expect = std.testing.expect;
    const expectEqual = std.testing.expectEqual;
    const expectEqualStrings = std.testing.expectEqualStrings;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source: [:0]const u8 = "const x: u32 = 1;";
    const src = try Source.fromString(allocator, @constCast(source), "test.zig");

    var err = Error{
        .code = "code",
        .message = .static("oof"),
        .help = .static("help pls"),
        .source = src.contents,
        .source_name = src.pathname,
    };
    try err.labels.append(allocator, LabeledSpan{
        .label = .static("some label"),
        .span = .new(0, 4),
        .primary = true,
    });

    var f = JSONFormatter{};
    var w = io.Writer.Allocating.init(allocator);
    defer w.deinit();
    try f.format(&w.writer, err);

    var value = try json.parseFromSlice(json.Value, allocator, w.writer.buffered(), .{});
    defer value.deinit();
    const obj = value.value.object;

    try expectEqualStrings("oof", obj.get("message").?.string);
    try expectEqualStrings("code", obj.get("code").?.string);
    try expectEqualStrings("help pls", obj.get("help").?.string);
    const labels = obj.get("labels") orelse return error.ZigTestFailing;
    try expect(labels == .array);
    try expectEqual(1, labels.array.items.len);
    const label = labels.array.items[0].object;
    try expectEqual(Value{ .bool = true }, label.get("primary"));
    try expectEqualStrings("some label", label.get("label").?.string);
    try expect(label.get("start").? == .object);
    try expect(label.get("end").? == .object);
}

const std = @import("std");
const io = std.Io;
const formatter = @import("../formatter.zig");
const Meta = formatter.Meta;
const FormatError = formatter.FormatError;
const Error = @import("../../Error.zig");
const _span = @import("../../span.zig");
const LabeledSpan = _span.LabeledSpan;
