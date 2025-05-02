// pub const FixerFn = fn (builder: Fix.Builder) anyerror!Fix;
pub fn FixerFn(Ctx: type) type {
    return fn (ctx: Ctx, builder: Fix.Builder) anyerror!Fix;
}

pub const Fix = struct {
    meta: Meta = .{},
    span: Span,
    replacement: Cow,

    pub fn isNoop(self: Fix) bool {
        return self.replacement.borrow().len == 0 and self.span.eql(Span.EMPTY);
    }

    pub const Meta = packed struct {
        kind: Kind = .fix,
        dangerous: bool = false,

        pub const disabled = Meta{ .kind = Kind.none, .dangerous = false };
        pub const dangerous_fix: Meta = .{ .kind = Kind.fix, .dangerous = true };
        pub const safe_fix: Meta = .{ .kind = Kind.fix, .dangerous = false };
        pub const dangerous_suggestion: Meta = .{ .kind = Kind.suggestion, .dangerous = true };
        pub const safe_suggestion: Meta = .{ .kind = Kind.suggestion, .dangerous = false };

        pub fn isDisabled(self: Meta) bool {
            // TODO: check output assembly, check if `@bitcast(self) == 0` is faster.
            return self.kind == Kind.none;
        }

        /// Check if a fix (`other`) may be applied based on a user-configured filter.
        /// Here, `self` does not come from a Fix, but from a linter config.
        pub fn canApply(self: Meta, other: Meta) bool {
            return self.kind != .none // not disabled
            and (self.dangerous or !other.dangerous) // fix is safe or we allow dangerous fixes
            and (self.kind == other.kind); // fix kind matches
        }
    };

    pub const Kind = enum(u2) {
        none,
        fix,
        suggestion,
    };

    pub const Builder = struct {
        meta: Meta = .{},
        allocator: Allocator,
        ctx: *const LinterContext,

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

        pub fn replacef(self: Builder, span: Span, comptime fmt: []const u8, args: anytype) Fix {
            return Fix{
                .meta = self.meta,
                .span = span,
                .replacement = Cow.fmt(self.allocator, fmt, args) catch @panic("OOM"),
            };
        }

        pub inline fn source(self: Builder) []const u8 {
            return self.ctx.semantic.ast.source;
        }

        pub const Spanned = enum { node, token };

        pub fn snippet(self: Builder, comptime kind: Spanned, id: u32) []const u8 {
            return self.spanCovering(kind, id).snippet(self.ctx.ast().source);
        }

        pub fn spanCovering(self: Builder, comptime kind: Spanned, id: u32) Span {
            return switch (kind) {
                .token => self.ctx.semantic.tokenSpan(id),
                .node => self.ctx.semantic.nodeSpan(id),
            };
        }
    };
};

pub const Fixer = struct {
    allocator: Allocator,

    const Diagnostic = @import("./lint_context.zig").Diagnostic;
    /// Take fixes in a set of diagnostics and apply them to a source file.
    ///
    /// Diagnostics list is moved. Its items will be deinitialized.
    pub fn applyFixes(
        self: *Fixer,
        source: [:0]const u8,
        diagnostics: []const Diagnostic,
    ) Allocator.Error!Fixer.Result {
        // number of fixes that can be put on the stack before a heap allocation is needed
        const STACK_SIZE = 16;

        util.assert(diagnostics.len > 0, "Caller must check if fixes is empty", .{});

        var stackfb = heap.stackFallback(STACK_SIZE * @sizeOf(Fix), self.allocator);
        const alloc = stackfb.get();

        var fixes = std.ArrayList(Diagnostic).init(alloc);
        defer fixes.deinit();
        try fixes.ensureTotalCapacityPrecise(STACK_SIZE);

        // items not allocated w stack fallback b/c error list must outlive
        // the lifetime of this function scope.
        var unfixed_errors = std.ArrayListUnmanaged(Error){}; //.init(self.allocator);
        errdefer unfixed_errors.deinit(self.allocator);

        // filter out no-ops and sort by span start
        for (diagnostics) |diagnostic| {
            const fix: Fix = diagnostic.fix orelse {
                try unfixed_errors.append(self.allocator, diagnostic.err);
                continue;
            };
            if (fix.isNoop()) {
                try unfixed_errors.append(self.allocator, diagnostic.err);
                continue;
            }
            try fixes.append(diagnostic);
        }
        if (fixes.items.len == 0) return noFixes(unfixed_errors);
        mem.sortUnstable(Diagnostic, fixes.items, {}, spanStartLessThan);

        var fixed: std.ArrayListUnmanaged(u8) = .{};
        try fixed.ensureTotalCapacity(self.allocator, source.len);
        errdefer fixed.deinit(self.allocator);

        var last_end: u32 = 0;
        for (fixes.items) |*diagnostic| {
            var fix = &diagnostic.fix.?;
            defer fix.replacement.deinit(self.allocator);
            if (fix.span.start < last_end) {
                try unfixed_errors.append(self.allocator, diagnostic.err);
                continue;
            }
            defer diagnostic.err.deinit(self.allocator);
            // append source up to the start of the fix
            try fixed.appendSlice(self.allocator, source[last_end..fix.span.start]);
            // append replacement, skipping the deleted/replaced section
            try fixed.appendSlice(self.allocator, fix.replacement.borrow());

            last_end = fix.span.end;
        }
        if (last_end < source.len) {
            try fixed.appendSlice(self.allocator, source[last_end..source.len]);
        }

        return fromFixed(fixed, unfixed_errors);
    }

    pub const Result = struct {
        /// Was at least one fix applied?
        did_fix: bool,
        /// The fixed source code. Heap-allocated. Always empty if `did_fix` is `false`.
        source: std.ArrayListUnmanaged(u8),
        /// Errors that could not be fixed.
        unfixed_errors: std.ArrayListUnmanaged(Error),

        pub fn deinit(self: *Result, allocator: Allocator) void {
            if (self.did_fix) {
                self.source.deinit(allocator);
            } else {
                util.debugAssertf(
                    self.source.items.len == 0,
                    "invariant violation: no-fix Result has non-empty fixed source.",
                    .{},
                );
            }
            self.unfixed_errors.deinit(allocator);
        }
    };

    inline fn noFixes(unfixed_errors: std.ArrayListUnmanaged(Error)) Result {
        return .{
            .did_fix = false,
            .source = .{},
            .unfixed_errors = unfixed_errors,
        };
    }

    inline fn fromFixed(fixed_source: std.ArrayListUnmanaged(u8), unfixed_errors: std.ArrayListUnmanaged(Error)) Result {
        return .{
            .did_fix = true,
            .source = fixed_source,
            .unfixed_errors = unfixed_errors,
        };
    }

    fn spanStartLessThan(_: void, a: Diagnostic, b: Diagnostic) bool {
        return a.fix.?.span.start < b.fix.?.span.start;
    }
};

test {
    _ = @import("./test/fix_test.zig");
}

const std = @import("std");
const heap = std.heap;
const mem = std.mem;
const util = @import("util");
const Semantic = @import("../semantic.zig").Semantic;

const Allocator = std.mem.Allocator;
const Span = @import("../span.zig").Span;
const Cow = util.Cow(false);

const LinterContext = @import("./lint_context.zig");
const Error = @import("../Error.zig");
