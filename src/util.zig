const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const string = []const u8;
pub const stringSlice = [:0]const u8;
pub const stringMut = []u8;

pub const RUNTIME_SAFETY = builtin.mode != .ReleaseFast;
pub const IS_DEBUG = builtin.mode == .Debug;
pub const IS_WINDOWS = builtin.target.os.tag == .windows;
pub const NEWLINE = if (IS_WINDOWS) "\r\n" else "\n";

const WHITESPACE = [4]u8{ ' ', '\t', '\n', '\r' };
pub fn trimWhitespace(s: string) string {
    return std.mem.trim(u8, s, &WHITESPACE);
}

pub fn trimWhitespaceRight(s: string) string {
    return std.mem.trimRight(u8, s, &WHITESPACE);
}

/// Assert that `condition` is true, panicking if it is not.
///
/// Behaves identically to `std.debug.assert`, except that assertions will fail
/// with a formatted message in debug builds. `fmt` and `args` follow the same
/// formatting conventions as `std.debug.print` and `std.debug.panic`.
///
/// Similarly to `std.debug.assert`, undefined behavior is invoked if
/// `condition` is false. In `ReleaseFast` mode, `unreachable` is stripped and
/// assumed to be true by the compiler, which will lead to strange program
/// behavior.
pub inline fn assert(condition: bool, comptime fmt: string, args: anytype) void {
    if (comptime IS_DEBUG) {
        if (!condition) {
            std.debug.panic(fmt, args);
        }
    } else {
        std.debug.assert(condition);
    }
}

pub inline fn debugAssert(condition: bool, comptime fmt: string, args: anytype) void {
    if (comptime IS_DEBUG) {
        if (!condition) std.debug.panic(fmt, args);
    }
}

pub inline fn assertUnsafe(condition: bool) void {
    if (comptime IS_DEBUG) {
        if (!condition) @panic("assertion failed");
    } else {
        @setRuntimeSafety(IS_DEBUG);
        unreachable;
    }
}

pub fn Boo(T: type) type {
    const info = @typeInfo(T);
    return switch (info) {
        .Pointer => if (info.Pointer.size == .Slice) BooSlice(info.Pointer.child) else BooGeneric(T),
        else => BooGeneric(T),
    };
}

fn BooGeneric(T: type) type {
    const Borrow = union(enum) {
        borrowed: *const T,
        owned: T,
    };
    return struct {
        alloc: ?Allocator = null,
        value: Borrow,

        const Self = @This();

        pub fn borrowed(ptr: *const T) Self {
            return Self{ .value = .{ .borrowed = ptr } };
        }

        pub fn owned(value: T) Self {
            return Self{ .value = .{ .owned = value } };
        }
    };
}

fn BooSlice(T: type) type {
    const Borrow = union(enum) {
        borrowed: []const T,
        owned: []T,
    };

    return struct {
        alloc: ?Allocator = null,
        value: Borrow,

        const Self = @This();

        pub fn borrowed(ptr: []const T) Self {
            return Self{ .value = .{ .borrowed = ptr } };
        }

        pub fn owned(value: []T) Self {
            return Self{ .value = .{ .owned = value } };
        }

        pub fn fmt(alloc: Allocator, comptime format: []const u8, args: anytype) Allocator.Error!Self {
            const value = try std.fmt.allocPrint(alloc, format, args);
            return Self{ .value = .{ .owned = value }, .alloc = alloc };
        }

        pub fn borrow(self: *const Self) []const T {
            return switch (self.value) {
                .borrowed => self.value.borrowed,
                .owned => self.value.owned,
            };
        }

        pub fn deinit(self: *Self) void {
            switch (self.value) {
                .borrowed => {},
                .owned => if (self.alloc) |a| {
                    a.free(self.value.owned);
                },
            }
        }
    };
}
