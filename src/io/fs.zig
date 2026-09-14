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

// Reader.StreamError without EndOfStream
pub const ReadWriteError = error{
    /// See the `Reader` implementation for detailed diagnostics.
    ReadFailed,
    /// See the `Writer` implementation for detailed diagnostics.
    WriteFailed,
};

/// Modified version of `streamUntilDelimiterOrEof` from zig v0.14.1's stdlib.
///
/// Reads from the stream until specified byte is found. If the buffer is not
/// large enough to hold the entire contents, `error.StreamTooLong` is returned.
/// If end-of-stream is found, returns the rest of the stream. If this
/// function is called again after that, returns null.
/// Returns a slice of the stream data, with ptr equal to `buf.ptr`. The
/// delimiter byte is written to the output buffer but is not included
/// in the returned slice.
pub fn readUntilDelimiterOrEof(
    reader: *std.Io.Reader,
    buffer: []u8,
    delimiter: u8,
) ReadWriteError!?[]u8 {
    var fbw = std.Io.Writer.fixed(buffer);
    const bytes_read = reader.streamDelimiter(&fbw, delimiter) catch |err| switch (err) {
        error.EndOfStream => if (fbw.end == 0) {
            return null;
        } else {
            // Partial data at EOF (e.g. last line without trailing newline)
            return buffer[0..fbw.end];
        },

        else => |e| return e,
    };
    if (bytes_read == 0) return null;
    reader.toss(1); // throw out the delimiter
    return buffer[0..bytes_read];
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
