//! Context is only valid over the lifetime of a Source and the min lifetime of
//! all rules
semantic: *const Semantic,
gpa: Allocator,
/// Errors collected by lint rules
errors: ErrorList,
/// this slice is 'static (in data segment) and should never be free'd
curr_rule_name: string = "",
source: *Source,

pub fn init(gpa: Allocator, semantic: *const Semantic, source: *Source) Context {
    return Context{
        .semantic = semantic,
        .gpa = gpa,
        .errors = ErrorList.init(gpa),
        .source = source,
    };
}

// ========================= LIFECYCLE MANAGEMENT ==========================
// These methods are used by Linter to adjust state between rule
// invocations.

pub inline fn updateForRule(self: *Context, rule: *const Rule) void {
    self.curr_rule_name = rule.name;
}

// ============================== SHORTHANDS ===============================
// Shorthand access to data within the context. Makes writing rules easier.

pub fn ast(self: *const Context) *const Ast {
    return &self.semantic.ast;
}

// ============================ ERROR REPORTING ============================

pub fn spanN(self: *const Context, node_id: Ast.Node.Index) LabeledSpan {
    // TODO: inline
    const s = self.semantic.ast.nodeToSpan(node_id);
    return LabeledSpan.unlabeled(s.start, s.end);
}

pub fn spanT(self: *const Context, token_id: Ast.TokenIndex) LabeledSpan {
    // TODO: inline
    const s = self.semantic.ast.tokenToSpan(token_id);
    // return .{ .start = s.start, .end = s.end };
    return LabeledSpan.unlabeled(s.start, s.end);
}

pub inline fn labelN(
    self: *const Context,
    node_id: Ast.Node.Index,
    comptime fmt: []const u8,
    args: anytype,
) LabeledSpan {
    const s = self.semantic.ast.nodeToSpan(node_id);
    const label = std.fmt.allocPrint(self.gpa, fmt, args) catch @panic("OOM");
    return LabeledSpan{
        .span = .{ .start = s.start, .end = s.end },
        .label = label,
        .primary = false,
    };
}

pub fn diagnosticAlloc(self: *Context, message: string, spans: anytype) void {
    // TODO: inline
    return self._diagnostic(Error.new(message), &spans);
}

/// Report a Rule violation.
///
/// Takes a short summary of the problem (a static string) and a set of
/// [`Span`]s (anything that can be coerced into `[]const Span`)highlighting
/// the problematic code. `spans` should not be empty (they _can_ be, but
/// this is not user-friendly.).
///
/// `spans` is anytype for more flexible coercion into a `[]const Span`
pub fn diagnostic(self: *Context, message: string, spans: anytype) void {
    // TODO: inline
    return self._diagnostic(Error.newStatic(message), &spans);
}

fn _diagnostic(self: *Context, err: Error, spans: []const LabeledSpan) void {
    var e = err;
    const a = self.gpa;
    // var e = Error.newStatic(message);
    e.code = self.curr_rule_name;
    e.source_name = if (self.source.pathname) |p| a.dupe(u8, p) catch @panic("OOM") else null;
    e.source = self.source.contents.clone();

    if (spans.len > 0) {
        e.labels.appendSlice(a, spans) catch @panic("OOM");
    }
    // TODO: handle errors better
    self.errors.append(e) catch @panic("Cannot add new error: Out of memory");
}

pub fn deinit(self: *Context) void {
    self.errors.deinit();
    self.* = undefined;
}

pub const ErrorList = std.ArrayList(Error);

const Context = @This();

const std = @import("std");
const util = @import("util");
const _rule = @import("rule.zig");
const _source = @import("../source.zig");
const _semantic = @import("../semantic.zig");

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Error = @import("../Error.zig");
const LabeledSpan = _source.LabeledSpan;
const Rule = _rule.Rule;
const Semantic = _semantic.Semantic;
const Source = _source.Source;
const string = util.string;
