const std = @import("std");
const Allocator = std.mem.Allocator;

const assert = @import("../util.zig").assert;
const IS_DEBUG = @import("../util.zig").IS_DEBUG;
const DebugOnly = @import("./debug_only.zig").DebugOnly;
const debugOnly = @import("./debug_only.zig").debugOnly;

/// A clone-on-write type monomorphized for strings.
///
/// I tried adding this to smart-pointers but it turned out to be a pain to
/// generalize.  I need this structure _right now_; we should go back and
/// move+generalize this code later.
pub fn Cow(comptime sentinel: bool) type {
    const MutSlice = if (sentinel) [:0]u8 else []u8;
    const Slice = if (sentinel) [:0]const u8 else []const u8;

    const null_alloc = debugOnly(?Allocator, null);

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
        __alloc: DebugAlloc = null_alloc,

        const Self = @This();

        /// Create a `Cow` from a static string.
        ///
        /// Static `Cow`s are valid for the entire lifetime of the program (
        /// that is, their lifetime is `'static`). `str` will point to somewhere
        /// in the data segment. Attempts to mutate it will trigger a segfault.
        ///
        /// ## Example
        /// ```zig
        /// const message = "Hello, world!";
        /// const cow = Cow(false).static(message);
        ///
        /// // `cow` stores _exactly_ `message`.
        /// try expectEqualStrings("Hello, world!", cow.borrow());
        /// try expectEqual(message.ptr, cow.borrow().ptr);
        /// ```
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
                .__alloc = debugOnly(?Allocator, allocator),
            };
        }

        /// Create a `Cow` that borrows its data.
        pub fn initBorrowed(str: Slice) Self {
            return .{ .borrowed = true, .str = str };
        }

        /// Create an owned `Cow` by printing a format string.
        pub fn fmt(allocator: Allocator, comptime format_str: []const u8, args: anytype) Allocator.Error!Self {
            const print = if (sentinel) std.fmt.allocPrintZ else std.fmt.allocPrint;
            const str = try print(allocator, format_str, args);
            return .{ .borrowed = false, .str = str, .__alloc = debugOnly(?Allocator, allocator) };
        }

        /// Create a new `Cow` storing the same string as `self`.
        ///
        /// This is a "clone" in the Rust sense. The new `Cow` borrows from
        /// the current one. No allocations are performed.
        pub fn clone(self: Self) Self {
            return .{
                .borrowed = true,
                .str = self.str,
                .__alloc = null_alloc,
            };
        }

        /// Immutably borrow the string stored by this `Cow` without allocating.
        pub fn borrow(self: Self) Slice {
            return self.str;
        }

        /// Borrow a mutable reference to this `Cow`'s string data. This method
        /// allocates if the `Cow` is borrowed.
        pub fn borrowMut(self: *Self, allocator: Allocator) Allocator.Error!MutSlice {
            if (self.borrowed) {
                try self.toOwnedImpl(allocator);
                self.setAlloc(allocator);
            }
            return @constCast(self.str);
        }

        /// Mutably borrow the string stored in `self`, asserting that `self` is
        /// owned.
        pub fn borrowMutUnchecked(self: *Self) MutSlice {
            assert(!self.borrowed, "This Cow is borrowing its data.");
            return @constCast(self.str);
        }

        /// Update this `Cow` in-place so that it owns its string.
        ///
        /// If you are just trying to obtain a mutable reference, use
        /// `borrowMut` instead.
        ///
        /// ## Example
        /// ```zig
        /// const cow = Cow(false).static("Hello, world!");
        /// const owned = try cow.toOwned(allocator);
        /// const string_mut: []u8 = cow.borrowMutUnchecked();
        /// ```
        pub fn toOwned(self: *Self, allocator: Allocator) Allocator.Error!void {
            if (self.borrowed) try self.toOwnedImpl(allocator);
        }

        fn toOwnedImpl(self: *Self, allocator: Allocator) Allocator.Error!void {
            @branchHint(.cold);
            assert(self.borrowed, "This Cow is already owned.", .{});
            const owned_data: MutSlice = try (if (comptime sentinel)
                allocator.allocSentinel(u8, self.str.len, 0)
            else
                allocator.alloc(u8, self.str.len));
            @memcpy(owned_data, self.str);
            self.* = .{
                .str = owned_data,
                .borrowed = false,
                .__alloc = debugOnly(?Allocator, allocator),
            };
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

        /// Destroy this `Cow`. The underlying string will only be deallocated
        /// if it is owned.
        ///
        /// All `Cow`s borrowing this string will become invalidated. Consumers
        /// are responsible for ensuring that borrowing `Cow`s have a lifetime
        /// that is less than or equal to the `Cow` being deinitialized.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            if (self.borrowed) return;

            if (comptime IS_DEBUG) {
                // All constructors/methods defined in Cow set __alloc when the
                // allocation is owned. If its missing, its most likely due to
                // someone constructing a Cow with struct initialization syntax.
                // In order to maintain internal invariants, Cows should not be
                // constructed this way.
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

const DebugAlloc = DebugOnly(?Allocator);

const t = std.testing;
test Cow {
    var cow = try Cow(false).fmt(t.allocator, "Hello, {s}!", .{"world"});
    defer cow.deinit(t.allocator);

    try t.expect(!cow.borrowed);
    try t.expectEqualStrings("Hello, world!", cow.borrow());

    var borrowed = cow.clone();
    defer borrowed.deinit(t.allocator);
    try t.expect(borrowed.borrowed);
    try t.expectEqual(cow.borrow().ptr, borrowed.borrow().ptr);

    std.mem.replaceScalar(u8, try borrowed.borrowMut(t.allocator), 'w', 'W');
    try t.expectEqualStrings("Hello, world!", cow.borrow());
    try t.expectEqualStrings("Hello, World!", borrowed.borrow());
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
    try t.expectEqualStrings("Hello, world!", str);
}

test "Cow.toOwned" {
    const s = "Hello, world!";
    var cow = Cow(false).static(s);
    defer cow.deinit(t.allocator);

    try t.expectEqualStrings(s, cow.borrow());
    try t.expectEqual(s.ptr, cow.borrow().ptr);

    // Same string data, different allocation.
    try cow.toOwned(t.allocator);
    try t.expectEqualStrings(s, cow.borrow());
    try t.expect(s.ptr != cow.borrow().ptr);
}
