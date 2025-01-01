pub const FixerFn = fn (builder: Fix.Builder) anyerror!Fix;

pub const Fix = struct {
    meta: Meta = .{},
    span: Span,
    replacement: Cow,

    pub fn isNoop(self: Fix) bool {
        return self.replacement.borrow().len == 0 and self.span.eql(Span.EMPTY);
    }

    pub const Meta = packed struct {
        kind: Kind = .fix,
        safe: bool = true,
    };

    pub const Kind = enum(u1) {
        fix,
        suggestion,
    };

    pub const Builder = struct {
        meta: Meta = .{},
        allocator: Allocator,

        const EMPTY = Cow.static("");

        pub fn noop(_: Builder) Fix {
            return Fix{
                // SAFETY: noop fixes never have their meta field accessed
                .meta = undefined,
                .span = Span.EMPTY,
                .replacement = EMPTY,
            };
        }
        pub fn delete(self: Builder, span: Span) Fix {
            return Fix{
                .meta = self.meta,
                .span = span,
                .replacement = EMPTY,
            };
        }

        pub fn replace(self: Builder, span: Span, replacement: Cow) Fix {
            return Fix{
                .meta = self.meta,
                .span = span,
                .replacement = replacement,
            };
        }

        pub fn replaceFmt(self: Builder, span: Span, comptime fmt: []const u8, args: anytype) Fix {
            return Fix{
                .meta = self.meta,
                .span = span,
                .replacement = Cow.fmt(self.allocator, fmt, args) catch @panic("OOM"),
            };
        }
    };
};

pub const Fixer = struct {
    allocator: Allocator,

    pub fn applyFixes(
        self: *Fixer,
        source: [:0]const u8,
        reported_fixes: []const Fix,
    ) Allocator.Error!Fixer.Result {
        // number of fixes that can be put on the stack before a heap allocation is needed
        const STACK_SIZE = 16;

        util.assert(reported_fixes.len > 0, "Caller must check if fixes is empty", .{});

        var stackfb = heap.stackFallback(STACK_SIZE * @sizeOf(Fix), self.allocator);
        const alloc = stackfb.get();

        var fixes = std.ArrayList(Fix).init(alloc);
        defer fixes.deinit();
        try fixes.ensureTotalCapacityPrecise(STACK_SIZE);

        // filter out no-ops and sort by span start
        for (reported_fixes) |fix| {
            if (fix.isNoop()) continue;
            try fixes.append(fix);
        }
        if (fixes.items.len == 0) return noFixes();
        mem.sortUnstable(Fix, fixes.items, {}, spanStartLessThan);

        var fixed: std.ArrayListUnmanaged(u8) = .{};
        try fixed.ensureTotalCapacity(self.allocator, source.len);
        errdefer fixed.deinit(self.allocator);

        var last_end: u32 = 0;
        for (fixes.items) |fix| {
            if (fix.span.start < last_end) continue;
            // append source up to the start of the fix
            try fixed.appendSlice(self.allocator, source[last_end..fix.span.start]);
            // append replacement, skipping the deleted/replaced section
            try fixed.appendSlice(self.allocator, fix.replacement.borrow());

            last_end = fix.span.end;
        }
        if (last_end < source.len) {
            try fixed.appendSlice(self.allocator, source[last_end..source.len]);
        }

        return fromFixed(fixed);
    }

    pub const Result = struct {
        did_fix: bool,
        source: std.ArrayListUnmanaged(u8),

        pub fn deinit(self: *Result, allocator: Allocator) void {
            if (!self.did_fix) {
                util.debugAssert(
                    self.source.items.len == 0,
                    "invariant violation: no-fix Result has non-empty fixed source.",
                    .{},
                );
                return;
            }

            self.source.deinit(allocator);
        }
    };

    inline fn noFixes() Result {
        return .{ .did_fix = false, .source = .{} };
    }

    inline fn fromFixed(fixed_source: std.ArrayListUnmanaged(u8)) Result {
        return .{ .did_fix = true, .source = fixed_source };
    }

    fn spanStartLessThan(_: void, a: Fix, b: Fix) bool {
        return a.span.start < b.span.start;
    }
};

test {
    _ = @import("./test/fix_test.zig");
}

const std = @import("std");
const heap = std.heap;
const mem = std.mem;
const util = @import("util");

const Allocator = std.mem.Allocator;
const Span = @import("../span.zig").Span;
const Cow = util.Cow(false);
