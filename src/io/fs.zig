const std = @import("std");

const Allocator = std.mem.Allocator;
const File = std.Io.File;

/// Read the remaining contents of `file`, up to `max_bytes`. Replaces
/// `std.fs.File.readToEndAlloc` from Zig <= 0.15.
pub fn readToEndAlloc(file: File, io: std.Io, allocator: Allocator, max_bytes: usize, comptime bufsize: usize) ![]u8 {
    var buf: [bufsize]u8 = undefined;
    var reader = file.reader(io, &buf);
    return reader.interface.allocRemaining(allocator, .limited(max_bytes)) catch |e| switch (e) {
        error.ReadFailed => return reader.err orelse error.InputOutput,
        else => |other| return other,
    };
}

pub const ReadLineError = error{
    /// See the `Reader` implementation for detailed diagnostics.
    ReadFailed,
    /// The line did not fit in the output buffer. The remainder of the line
    /// has been discarded, so the next call resumes at the following line.
    StreamTooLong,
};

/// Modified version of `streamUntilDelimiterOrEof` from zig v0.14.1's stdlib.
///
/// Reads from the stream until specified byte is found. If the buffer is not
/// large enough to hold the entire contents, the rest of the line is discarded
/// and `error.StreamTooLong` is returned.
/// If end-of-stream is found, returns the rest of the stream. If this
/// function is called again after that, returns null.
/// Empty lines are returned as empty slices; only end-of-stream yields null.
/// Returns a slice of the stream data, with ptr equal to `buf.ptr`. The
/// delimiter byte is not included in the returned slice.
pub fn readUntilDelimiterOrEof(
    reader: *std.Io.Reader,
    buffer: []u8,
    delimiter: u8,
) ReadLineError!?[]u8 {
    var fbw = std.Io.Writer.fixed(buffer);
    _ = reader.streamDelimiter(&fbw, delimiter) catch |err| switch (err) {
        error.EndOfStream => return if (fbw.end == 0) null else buffer[0..fbw.end],
        error.ReadFailed => return error.ReadFailed,
        error.WriteFailed => {
            _ = reader.discardDelimiterInclusive(delimiter) catch |e| switch (e) {
                error.EndOfStream => {},
                error.ReadFailed => return error.ReadFailed,
            };
            return error.StreamTooLong;
        },
    };
    reader.toss(1); // throw out the delimiter
    return buffer[0..fbw.end];
}

test readUntilDelimiterOrEof {
    const expectEqualString = std.testing.expectEqualStrings;
    const expect = std.testing.expect;

    var buffer: [1024]u8 = undefined;
    const stdin = "line1\nline2\nline3";
    var reader = std.Io.Reader.fixed(stdin);

    try expectEqualString(try readUntilDelimiterOrEof(&reader, &buffer, '\n') orelse return error.ExpectedLine, "line1");
    try expectEqualString(try readUntilDelimiterOrEof(&reader, &buffer, '\n') orelse return error.ExpectedLine, "line2");
    try expectEqualString(try readUntilDelimiterOrEof(&reader, &buffer, '\n') orelse return error.ExpectedLine, "line3");
    try expect(try readUntilDelimiterOrEof(&reader, &buffer, '\n') == null);
}

test "readUntilDelimiterOrEof: empty lines and CRLF" {
    const t = std.testing;
    var buffer: [16]u8 = undefined;
    var reader = std.Io.Reader.fixed("a\n\nb\r\n\n");
    try t.expectEqualStrings("a", (try readUntilDelimiterOrEof(&reader, &buffer, '\n') orelse return error.TestUnexpectedResult));
    try t.expectEqualStrings("", (try readUntilDelimiterOrEof(&reader, &buffer, '\n') orelse return error.TestUnexpectedResult));
    try t.expectEqualStrings("b\r", (try readUntilDelimiterOrEof(&reader, &buffer, '\n') orelse return error.TestUnexpectedResult));
    try t.expectEqualStrings("", (try readUntilDelimiterOrEof(&reader, &buffer, '\n') orelse return error.TestUnexpectedResult));
    try t.expect(try readUntilDelimiterOrEof(&reader, &buffer, '\n') == null);
}

test "readUntilDelimiterOrEof: overlong line is skipped" {
    const t = std.testing;
    var buffer: [4]u8 = undefined;
    var reader = std.Io.Reader.fixed("toolongline\nok\ntoolongtail");
    try t.expectError(error.StreamTooLong, readUntilDelimiterOrEof(&reader, &buffer, '\n'));
    try t.expectEqualStrings("ok", (try readUntilDelimiterOrEof(&reader, &buffer, '\n') orelse return error.TestUnexpectedResult));
    try t.expectError(error.StreamTooLong, readUntilDelimiterOrEof(&reader, &buffer, '\n'));
    try t.expect(try readUntilDelimiterOrEof(&reader, &buffer, '\n') == null);
}
