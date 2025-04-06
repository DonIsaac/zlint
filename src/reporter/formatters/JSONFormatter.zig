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

const std = @import("std");
const formatter = @import("../formatter.zig");
const Meta = formatter.Meta;
const FormatError = formatter.FormatError;
const Writer = std.io.AnyWriter;
const Error = @import("../../Error.zig");
const _span = @import("../../span.zig");
const LabeledSpan = _span.LabeledSpan;
const Location = _span.Location;
