//! A disable directive parsed from a comment.
//!
//! ## Examples
//! ```zig
//! // zlint-disable
//! // zlint-disable no undefined
//! // zlint-disable-next-line
//! // zlint-disable-next-line foo bar baz
//! foo(); // zlint-disable-line foo
//! ```

kind: Kind,
/// From the start of the comment through the end of the directive keyword or
/// the last rule name, whichever comes last.
span: Span,
/// Source text listing the disabled rules, up to any `--` explanation. Empty
/// when nothing is listed, which means all rules are disabled. A non-empty
/// list with no valid names disables nothing. Iterate with `ruleNames`.
rules: Span = .empty,

pub const DisableDirectiveComment = @This();

pub const Kind = enum {
    /// Disables a set of rules for an entire file.
    ///
    /// `zlint-disable`
    global,
    /// Disables a set of rules on the line after the comment.
    ///
    /// `zlint-disable-next-line`
    next_line,
    /// Disables a set of rules on the same line as the comment.
    ///
    /// `zlint-disable-line`
    same_line,
};

/// Returns `true` if this disable directive applies to an entire file.
pub inline fn isGlobal(self: *const DisableDirectiveComment) bool {
    return self.kind == .global;
}

/// Does this directive disable diagnostics for all rules?
pub inline fn disablesAllRules(self: *const DisableDirectiveComment) bool {
    return self.rules.len() == 0;
}

/// Iterate over the names of disabled rules. `source` must be the source
/// text this directive was parsed from.
pub fn ruleNames(self: *const DisableDirectiveComment, source: []const u8) RuleNameIterator {
    assert(self.rules.end <= source.len);
    return .{ .source = source, .cursor = self.rules.start, .end = self.rules.end };
}

/// Yields spans of rule names in a comma and/or whitespace separated list.
/// Characters that cannot appear in a rule name are skipped.
pub const RuleNameIterator = struct {
    source: []const u8,
    cursor: u32,
    end: u32,

    pub fn next(self: *RuleNameIterator) ?Span {
        while (self.cursor < self.end and !isNameChar(self.source[self.cursor])) : (self.cursor += 1) {}
        if (self.cursor == self.end) return null;
        const start = self.cursor;
        while (self.cursor < self.end and isNameChar(self.source[self.cursor])) : (self.cursor += 1) {}
        return .new(start, self.cursor);
    }

    inline fn isNameChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '-';
    }
};

const std = @import("std");

const assert = std.debug.assert;
const Span = @import("../../span.zig").Span;
