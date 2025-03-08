/// A `std.io.Writer` that writes data to an internally managed, allocated
/// buffer.
const StringWriter = @This();
const Writer = io.GenericWriter(*StringWriter, Allocator.Error, write);

buf: std.ArrayList(u8),

/// Create a new, empty `StringWriter`. Does not allocate memory.
pub fn init(allocator: Allocator) StringWriter {
    return StringWriter{ .buf = .init(allocator) };
}
/// Free this `StringWriter`'s internal buffer.
pub fn deinit(self: *StringWriter) void {
    self.buf.deinit();
}

/// Create a new `StringWriter` that pre-allocates enough memory for at least
/// `capacity` bytes.
pub fn initCapacity(capacity: usize, allocator: Allocator) Allocator.Error!StringWriter {
    const buf = try std.ArrayList(u8).initCapacity(allocator, capacity);
    return StringWriter{ .buf = buf };
}

/// Get the bytes written to this `StringWriter`.
pub inline fn slice(self: *const StringWriter) []const u8 {
    return self.buf.items;
}

pub fn writer(self: *StringWriter) Writer {
    return Writer{ .context = self };
}

/// Write `bytes` to this writer. Returns the number of bytes written.
pub fn write(self: *StringWriter, bytes: []const u8) Allocator.Error!usize {
    try self.buf.appendSlice(bytes);
    return bytes.len;
}

/// Write a formatted string to this `StringWriter`.
pub fn print(self: *StringWriter, comptime format: []const u8, args: anytype) Allocator.Error!void {
    const size = math.cast(usize, fmt.count(format, args)) orelse return error.OutOfMemory;
    try self.buf.ensureUnusedCapacity(size);
    const len = self.buf.items.len;
    self.buf.items.len += size;
    _ = fmt.bufPrint(self.buf.items[len..], format, args) catch |err| switch (err) {
        error.NoSpaceLeft => unreachable, // we just counted the size above
    };
}

const std = @import("std");
const io = std.io;
const fmt = std.fmt;
const math = std.math;
const Allocator = std.mem.Allocator;

test print {
    const t = std.testing;
    var w = StringWriter.init(t.allocator);
    defer w.deinit();

    try w.print("Hello, {s}", .{"world"});
    try t.expectEqualStrings("Hello, world", w.slice());
}
