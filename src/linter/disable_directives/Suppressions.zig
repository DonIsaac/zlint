//! Rules disabled by directives in a single source file.
//!
//! File-wide `zlint-disable` directives are merged into `global`. Line
//! directives (`zlint-disable-line`, `zlint-disable-next-line`) each become an
//! entry in `lines` covering exactly one source line.

/// Rules disabled for the entire file.
global: RuleMask,
/// Sorted by `start`. Entries for the same line are adjacent and have equal
/// `start` and `end`. Entries for different lines never overlap.
lines: LineList.Slice,

const Suppressions = @This();

pub const empty: Suppressions = .{ .global = .empty, .lines = .empty };

/// A set of rules, indexed by `Rule.Id`.
pub const RuleMask = std.StaticBitSet(all_rules.all.len);
const LineList = std.MultiArrayList(Line);

/// Collect all disable directives in a file.
///
/// Global directives are only honored before the first non-comment token.
/// They may be in doc comments. Line directives may be anywhere, but are not
/// recognized in doc comments.
pub fn init(gpa: Allocator, semantic: *const Semantic) Allocator.Error!Suppressions {
    const source = semantic.source();
    var global: RuleMask = .empty;
    var lines: LineList = .empty;
    errdefer lines.deinit(gpa);
    var parser = Parser.new(source);

    var header_end: u32 = 0;
    {
        const tokens = &semantic.parse.ast.tokens;
        const tags: []const Semantic.Token.Tag = tokens.items(.tag);
        const starts: []const u32 = tokens.items(.start);
        const locs = semantic.tokens().items(.loc);
        for (tags, starts, 0..) |tag, start, i| switch (tag) {
            .doc_comment, .container_doc_comment => {
                const directive = parser.parse(.new(start, @intCast(locs[i].end))) orelse continue;
                if (directive.isGlobal()) global.setUnion(ruleMask(source, &directive));
            },
            else => {
                header_end = start;
                break;
            },
        };
    }

    const comments = semantic.comments();
    for (comments.items(.start), comments.items(.end)) |start, end| {
        const directive = parser.parse(.new(start, end)) orelse continue;
        switch (directive.kind) {
            .global => if (start < header_end) global.setUnion(ruleMask(source, &directive)),
            .same_line => {
                const line_start: u32 = if (mem.lastIndexOfScalar(u8, source[0..start], '\n')) |nl| @intCast(nl + 1) else 0;
                try addLine(gpa, &lines, source, line_start, end, &directive);
            },
            .next_line => {
                // Line comments end at their terminating '\n', so the next
                // line starts right after it. No newline means no next line.
                if (end >= source.len) continue;
                const line_start = end + 1;
                const line_end: u32 = @intCast(mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len);
                try addLine(gpa, &lines, source, line_start, line_end, &directive);
            },
        }
    }

    return .{ .global = global, .lines = lines.toOwnedSlice() };
}

pub fn deinit(self: *Suppressions, gpa: Allocator) void {
    self.lines.deinit(gpa);
    self.* = undefined;
}

/// Is `rule` disabled by a line directive on the line containing `offset`?
pub fn isSuppressed(self: *const Suppressions, rule: Rule.Id, offset: u32) bool {
    const starts = self.lines.items(.start);
    const ends = self.lines.items(.end);
    const rules = self.lines.items(.rules);

    // Entries for one line are adjacent and lines never overlap, so the
    // first entry ending before `offset` means no earlier entry can match.
    var i = std.sort.upperBound(u32, starts, offset, orderU32);
    while (i > 0) {
        i -= 1;
        if (offset > ends[i]) return false;
        if (rules[i].isSet(rule.int())) return true;
    }
    return false;
}

fn addLine(
    gpa: Allocator,
    lines: *LineList,
    source: []const u8,
    start: u32,
    end: u32,
    directive: *const DisableDirectiveComment,
) Allocator.Error!void {
    assert(start <= end);
    // `isSuppressed` binary searches `start`. Comments are visited in source
    // order, so appending keeps it sorted without a sort pass.
    if (lines.len > 0) util.debugAssert(
        lines.items(.start)[lines.len - 1] <= start,
        "line directives must be added in source order",
        .{},
    );
    const rules = ruleMask(source, directive);
    // Only misspelled or unknown rules were listed. Suppressing nothing is
    // safer than treating this like "all rules".
    if (rules.count() == 0) return;
    try lines.append(gpa, .{ .start = start, .end = end, .rules = rules });
}

/// Unknown rule names are ignored.
fn ruleMask(source: []const u8, directive: *const DisableDirectiveComment) RuleMask {
    if (directive.disablesAllRules()) return .full;
    var mask: RuleMask = .empty;
    var names = directive.ruleNames(source);
    while (names.next()) |name| {
        if (Rule.getIdFor(name.snippet(source))) |id| mask.set(id.int());
    }
    return mask;
}

fn orderU32(a: u32, b: u32) std.math.Order {
    return std.math.order(a, b);
}

pub const Line = struct {
    /// Byte offset of the first character on the line.
    start: u32,
    /// Byte offset of the newline ending the line, or the source length for
    /// the last line. Inclusive.
    end: u32,
    rules: RuleMask,
};

const std = @import("std");
const util = @import("util");
const mem = std.mem;
const all_rules = @import("../all_rules.zig");

const Allocator = mem.Allocator;
const Parser = @import("./Parser.zig");
const DisableDirectiveComment = @import("./Comment.zig");
const Rule = @import("../rule.zig").Rule;
const Semantic = @import("../../Semantic.zig");

const assert = std.debug.assert;

test {
    _ = @import("./Suppressions_test.zig");
}
