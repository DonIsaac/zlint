//! Incrementally print JSON data to a writer.
//!
//! Printer exposes utility functions for printing JSON-formatted data to a
//! writer. It is used by print commands to build up JSON output.

/// Nested arrays and objects. Pushing into a container prints the opening token
//(e.g. `[` or `{`) and popping prints the closing token (e.g. `]` or `}`).
container_stack: ContainerStack,
/// Allocator for container stack.
alloc: Allocator,
/// Where JSON data is written to.
writer: Writer,
shiftwidth: usize = 2,
indent: u8 = ' ',
_newline: []const u8 = "\n",

pub const Writer = std.io.Writer;
const ContainerKind = enum { object, array };
const ContainerStack = std.ArrayList(ContainerKind);
const NEWLINE = if (builtin.target.os.tag == .windows) "\r\n" else "\n";

pub fn init(alloc: Allocator, writer: Writer) Printer {
    const stack = ContainerStack.initCapacity(alloc, 16) catch @panic("failed to allocate memory for printer's container stack");
    return Printer{
        .container_stack = stack,
        .alloc = alloc,
        .writer = writer,
    };
}

pub inline fn usePlatformNewline(self: *Printer) void {
    self._newline = NEWLINE;
}

pub fn deinit(self: *Printer) void {
    self.container_stack.deinit(self.alloc);
}

pub fn print(self: *Printer, comptime fmt: []const u8, value: anytype) !void {
    try self.writer.print(fmt, value);
}

/// Print a `"key": value` pair with a trailing comma. Value is formatted
/// using `fmt` as a format string.
pub fn pProp(self: *Printer, key: []const u8, comptime fmt: []const u8, value: anytype) !void {
    try self.pPropName(key);
    try self.writer.print(fmt, .{value});
    self.pComma();
    try self.pIndent();
}

pub inline fn pPropStr(self: *Printer, key: []const u8, value: anytype) !void {
    const T = @TypeOf(value);

    if (T == []const u8) {
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            return self.pProp(key, "{s}", value);
        }
        return self.pProp(key, "\"{s}\"", value);
    } else {
        return self.pProp(key, "\"{any}\"", value);
    }
}

/// Print a `"key": value` pair with a trailing comma. Value is stringified
/// into JSON before printing.
pub fn pPropJson(self: *Printer, key: []const u8, value: anytype) !void {
    try self.pPropName(key);
    var json = std.json.Stringify{ .writer = &self.writer };
    try json.write(value);
    self.pComma();
    try self.pIndent();
}

pub fn pJson(self: *Printer, value: anytype) !void {
    var json = std.json.Stringify{ .writer = &self.writer };
    try json.write(value);
}

/// Print an object property key with a trailing `:`, without printing a value.
pub fn pPropName(self: *Printer, key: []const u8) !void {
    try self.pString(key);
    try self.writer.writeAll(": ");
}

/// Print a `"key": "value"` object property pair where `value` is a
/// `dot.separated.namespaced.value`.  Only the last part of the value is
/// printed.
pub fn pPropWithNamespacedValue(self: *Printer, key: []const u8, value: anytype) !void {
    var value_buf: [256]u8 = undefined;
    const value_str = try std.fmt.bufPrintZ(&value_buf, "{any}", .{value});

    // Get the last part of the dot-separated value string.
    var iter = std.mem.splitScalar(u8, value_str, '.');
    // Always the previous result from `iter.next()`. Stop once we've
    // reached the end, then `segment` will contain the last part.
    var segment = iter.next();
    while (iter.peek()) |part| {
        segment = part;
        _ = iter.next();
    }
    if (segment == null) @panic("tag should have at least one '.'");
    return self.pProp(key, "\"{s}\"", segment.?);
}

/// Print a `null` literal.
pub inline fn pNull(self: *Printer) void {
    self.writer.writeAll("null") catch @panic("failed to write null");
}

/// Print a string literal.
pub inline fn pString(self: *Printer, s: []const u8) !void {
    try self.writer.writeAll("\"");
    try self.writer.writeAll(s);
    try self.writer.writeAll("\"");
}

/// Print a comma with a trailing space (`, `).
pub inline fn pComma(self: *Printer) void {
    self.writer.writeAll(", ") catch @panic("failed to write comma");
}

/// Enter into an object container. When exited (i.e. `pop()`), a closing curly brace will
/// be printed.
pub fn pushObject(self: *Printer) !void {
    try self.container_stack.append(self.alloc, ContainerKind.object);
    _ = try self.writer.write("{");
    try self.pIndent();
}

/// Enter into an array container. When exited (i.e. `pop()`), a closing square bracket will
/// be printed.
pub fn pushArray(self: *Printer, comptime indent: bool) !void {
    try self.container_stack.append(self.alloc, ContainerKind.array);
    _ = try self.writer.write("[");
    if (indent) {
        try self.pIndent();
    }
}

/// Exit out of an object or array container, printing the correspodning
/// closing token.
pub fn pop(self: *Printer) void {
    const kind = self.container_stack.pop() orelse @panic("container stack is empty");
    self.pIndent() catch @panic("failed to write indent after container end");
    const res = switch (kind) {
        ContainerKind.object => self.writer.write("}"),
        ContainerKind.array => self.writer.write("]"),
    };
    if (self.container_stack.items.len > 0) {
        self.pComma();
    }
    _ = res catch @panic("failed to write container end");
}

pub fn popIndent(self: *Printer) void {
    self.pop();
    self.pIndent() catch @panic("failed to write indent after container end");
}
pub fn pIndent(self: *Printer) !void {
    try self.writer.writeAll(self._newline);
    for (0..self.shiftwidth * self.container_stack.items.len) |_| {
        try self.writer.writeByte(self.indent);
    }
}

const Printer = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const stringify = std.json.stringify;
