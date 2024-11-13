context_lines: u32 = 1,

pub fn format(self: *GraphicalFormatter, w: *Writer, e: Error) !void {
    if (e.code.len > 0) {
        try w.print("{s}: ", .{e.code});
    }
    try w.print("{s}", .{e.message.str});

    if (e.labels.len > 0 and e.source != null) {
        const l = e.labels[0];
        const src: []const u8 = e.source.?.deref().*;
        // const lineNo, const colNo = getLineAndCol(src, l);
        const loc = Location.fromSpan(src, l);
        try w.print("\n[{s}:{d}:{d}]\n", .{
            if (e.source_name) |s| s else "<anonymous>",
            loc.line,
            loc.column,
        });
        const line = self.contextFor(src, l);
        try w.print("\n\n{s}\n\n", .{line});
    }
}

fn contextFor(self: *const GraphicalFormatter, src: []const u8, span: Span) []const u8 {
    var start = span.start;
    var end = span.end;
    std.debug.assert(src.len < std.math.maxInt(u32));
    const len: u32 = @intCast(src.len);

    {
        var lines_left = self.context_lines + 1;
        while (lines_left > 0 and start > 0) {
            while (start != 0) {
                if (src[start] == '\n') break;
                start -= 1;
            }
            lines_left -= 1;

            if (start > 0 and lines_left > 0) {
                eatNewlineBefore(src, &start);
            }
        }
    }

    {
        var lines_left = self.context_lines + 1;
        while (lines_left > 0 and end < len) {
            while (end != src.len) {
                switch (src[end]) {
                    '\n' => break,
                    '\r' => {
                        end += 1;
                        std.debug.assert(src[end] == '\n');
                        break;
                    },
                    else => end += 1,
                }
            }

            lines_left -= 1;
            if (end < len and lines_left > 0) {
                eatNewlineBefore(src, &end);
            }
        }
    }

    return src[start..end];
}

fn eatNewlineBefore(src: []const u8, i: *u32) void {
    if (i.* == 0) return;
    if (src[i.*] == '\n') i.* -= 1;
    if (i.* > 0 and src[i.*] == '\n') i.* -= 1;
    if (IS_WINDOWS and i.* > 0) {
        assert(src[i.*] == '\r');
        i.* -= 1;
    }
}

fn eatNewlineAfter(src: []const u8, i: *u32) void {
    if (comptime IS_WINDOWS) {
        if (@as(u32, @intCast(src.len)) - i.* > 2) i.* += 2 else i.* = @intCast(src.len);
    } else {
        i.* = @min(@as(u32, @intCast(src.len)), i.* + 1);
    }
}

fn getLineAndCol(src: []const u8, span: Span) struct { u32, u32 } {
    var line: u32 = 1;
    var col: u32 = 0;
    var cursor: u32 = 0;

    while (cursor < span.start) {
        switch (src[cursor]) {
            // todo: windows
            '\n' => {
                line += 1;
                col = 0;
            },
            else => col += 1,
        }
        cursor += 1;
    }
    return .{ line, col };
}

const GraphicalFormatter = @This();

const IS_WINDOWS = builtin.target.os.tag == .windows;

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Writer = std.fs.File.Writer; // TODO: use std.io.Writer?

const _source = @import("../../source.zig");
const Span = _source.Span;
const Location = _source.Location;

const Error = @import("../../Error.zig");
