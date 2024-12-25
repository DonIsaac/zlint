//! A disable directive parsed from a comment.
//!
//! ## Examples
//! ```zig
//! // zlint-disable
//! // zlint-disable no undefined
//! // zlint-disable-next-line
//! // zlint-disable-next-line foo bar baz
//! ```

/// An empty set means all rules are disabled.
disabled_rules: []Span = ALL_RULES_DISABLED,
/// I'm not really sure what this should be the span _of_. The entire comment?
/// Just the directive? Which is more useful?
span: Span,
kind: Kind,

pub const DisableDirectiveComment = @This();
const ALL_RULES_DISABLED = &[_]Span{};

pub const Kind = enum {
    /// Disables a set of rules for an entire file.
    ///
    /// `zlint-disable`
    global,
    /// Just disable the next line.
    ///
    /// `zlint-disable-next-line`
    line,
};

pub fn eql(self: DisableDirectiveComment, other: DisableDirectiveComment) bool {
    if (self.kind != other.kind or !self.span.eql(other.span)) return false;
    if (self.disabled_rules == other.disabled_rules) return true;
    if (self.disabled_rules.len != other.disabled_rules.len) return false;

    for (self.disabled_rules, 0..) |rule, i| {
        if (!rule.eql(other.disabled_rules[i])) return false;
    }

    return true;
}

pub fn deinit(self: *DisableDirectiveComment, allocator: Allocator) void {
    if (self.disabled_rules.len > 0) allocator.free(self.disabled_rules);
    self.disabled_rules.ptr = undefined;
    self.* = undefined;
}

const std = @import("std");

const Allocator = std.mem.Allocator;
const Span = @import("../../span.zig").Span;
