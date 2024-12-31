const std = @import("std");
const Allocator = std.mem.Allocator;

const assert = @import("../util.zig").assert;
const debugAssert = @import("../util.zig").debugAssert;
const IS_DEBUG = @import("../util.zig").IS_DEBUG;

/// A clone-on-write type monomorphized for strings.
///
/// I tried adding this to smart-pointers but it turned out to be a pain to
/// generalize.  I need this structure _right now_; we should go back and
/// move+generalize this code later.
pub fn Cow(comptime sentinel: bool) type {
    const MutSlice = if (sentinel) [:0]u8 else []u8;
    const Slice = if (sentinel) [:0]const u8 else []const u8;

    return struct {
        /// Does this `Cow` own its data, or is it borrowing it from someone
        /// else? `true` if borrowed.
        ///
        /// **HEY YOU**. Yeah, you. Are you using this struct externally? If so,
        /// _DON'T MUTATE THIS FIELD_!
        borrowed: bool,
        /// The string data itself.
        ///
        /// Do _not_ directly mutate `str` on borrowed `Cow`s. In the best case
        /// this may cause business-level corruption, in the worst case it will
        /// trigger a segfalt.
        ///
        /// Implementation notes:
        /// - Whether this is mutable or not depends on `borrowed`. Storing this
        ///   as a const slice variant make the safer thing the default.
        /// - I really, _really_ wish Zig had private container members...
        str: Slice,
        /// For runtime safety checks only. Do not use. Removed in any release
        /// build.
        __alloc: DebugAlloc = if (IS_DEBUG) null else {},

        const Self = @This();

        /// Create a `Cow` from a static string.
        ///
        /// Static `Cow`s are valid for the entire lifetime of the program (
        /// that is, their lifetime is `'static`). `str` will point to somewhere
        /// in the data segment. Attempts to mutate it will trigger a segfault.
        pub fn static(comptime str: anytype) Self {
            return .{
                .borrowed = true,
                .str = @constCast(str),
            };
        }

        /// Create a `Cow` that owns its data.
        ///
        /// `str` must be an owned allocation whose lifetime is at least as long
        /// as this `Cow`. It is moved into the new `Cow`.
        pub fn owned(str: MutSlice, allocator: Allocator) Self {
            return .{
                .borrowed = false,
                .str = str,
                .__alloc = asDebug(allocator),
            };
        }

        /// Create an owned `Cow` by printing a format string.
        pub fn fmt(allocator: Allocator, comptime format_str: []const u8, args: anytype) Allocator.Error!Self {
            const print = if (sentinel) std.fmt.allocPrintZ else std.fmt.allocPrint;
            const str = try print(allocator, format_str, args);
            return .{ .borrowed = false, .str = str, .__alloc = asDebug(allocator) };
        }

        pub fn clone(self: Self) Self {
            return .{ .borrowed = true, .str = self.str, .__alloc = null };
        }

        /// Immutably borrow the string stored by this `Cow` without allocating.
        pub fn borrow(self: Self) Slice {
            return self.str;
        }

        /// Borrow a mutable reference to this `Cow`'s string data. This method
        /// allocates if the `Cow` is borrowed.
        pub fn borrowMut(self: *Self, allocator: Allocator) Allocator.Error!MutSlice {
            if (self.borrowed) {
                // self.str = try allocator.alloc
                try self.toOwned(allocator);
                self.setAlloc(allocator);
            }
            return @constCast(self.str);
        }

        pub fn borrowMutUnchecked(self: *Self) MutSlice {
            assert(!self.borrowed, "This Cow is borrowing its data.");
            return @constCast(self.str);
        }

        pub fn toOwned(self: *Self, allocator: Allocator) Allocator.Error!void {
            assert(self.borrowed);
            const owned_data: MutSlice = try (if (comptime sentinel)
                allocator.allocSentinel(u8, self.str.len, 0)
            else
                allocator.alloc(u8, self.str.len));
            self.str = owned_data;
            self.borrowed = false;
        }

        /// Use a `{s}` specifier to print the contained string. Use `{}` or
        /// `{any}` for debug printing.
        pub fn format(self: Self, comptime _fmt: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            if (_fmt.len == 1 and _fmt[0] == 's') {
                return writer.writeAll(self.str);
            }

            return writer.print("Cow<{}>({s}, \"{s}\")", .{
                sentinel,
                if (self.borrowed) "borrowed" else "owned",
                self.str,
            });
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            if (self.borrowed) return;

            if (comptime IS_DEBUG) {
                assert(self.__alloc != null, "Do not create ad-hoc Cows; use one of the constructor APIs instead.", .{});

                assert(
                    self.__alloc.?.ptr == allocator.ptr,
                    "Cannot deinit() a cow with a different allocator than it was created with.",
                    .{},
                );
            }

            allocator.free(self.str);
            // SAFETY: `self` is unusable after deinit().
            self.* = undefined;
        }

        inline fn setAlloc(self: *Self, allocator: Allocator) void {
            if (comptime IS_DEBUG) self.__alloc = allocator;
        }
    };
}

const DebugAlloc = if (IS_DEBUG) ?Allocator else void;

/// Should be completely eliminiated in release binaries.
inline fn asDebug(allocator: Allocator) DebugAlloc {
    return if (comptime IS_DEBUG) allocator else {};
}

const t = std.testing;
test Cow {
    var cow = try Cow(false).fmt(t.allocator, "Hello, {s}!", .{"world"});
    defer cow.deinit(t.allocator);

    try t.expect(!cow.borrowed);
    try t.expect(false);
    try t.expectEqualStrings("Hello, world!", cow.borrow());

    var borrowed = cow.clone();
    defer borrowed.deinit(t.allocator);
    try t.expect(borrowed.borrowed);
    try t.expectEqual(cow.borrow().ptr, borrowed.borrow().ptr);

    std.mem.replaceScalar(u8, try borrowed.borrowMut(t.allocator), 'w', 'W');
    try t.expectEqualStrings(cow.borrow(), "Hello, world!");
    try t.expectEqualStrings(borrowed.borrow(), "Hello, World!");
}

test "Cow.format" {
    const no_specifier = try std.fmt.allocPrint(t.allocator, "{}", .{Cow(false).static("Hello, world!")});
    defer t.allocator.free(no_specifier);
    try t.expectEqualStrings("Cow<false>(borrowed, \"Hello, world!\")", no_specifier);

    const any = try std.fmt.allocPrint(t.allocator, "{any}", .{Cow(false).static("Hello, world!")});
    defer t.allocator.free(any);
    try t.expectEqualStrings("Cow<false>(borrowed, \"Hello, world!\")", any);

    const str = try std.fmt.allocPrint(t.allocator, "{s}", .{Cow(false).static("Hello, world!")});
    defer t.allocator.free(str);
    try t.expectEqualStrings("Hello, world!)", str);
}
