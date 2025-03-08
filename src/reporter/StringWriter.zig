const StringWriter = @This();
const Writer = std.io.GenericWriter(*StringWriter, Allocator.Error, write);

buf: std.ArrayList(u8),

pub fn initCapacity(capacity: usize, allocator: Allocator) Allocator.Error!StringWriter {
    const buf = try std.ArrayList(u8).initCapacity(allocator, capacity);
    return StringWriter{ .buf = buf };
}

pub inline fn slice(self: *const StringWriter) []const u8 {
    return self.buf.items;
}

pub fn writer(self: *StringWriter) Writer  {
    return Writer{ .context = self };
}

pub fn write(self: *StringWriter, bytes: []const u8) Allocator.Error!usize {
    try self.buf.appendSlice(bytes);
    return bytes.len;
}

const std = @import("std");
const io = std.io;
const Allocator = std.mem.Allocator;
