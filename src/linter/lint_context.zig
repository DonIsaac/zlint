//! Context is only valid over the lifetime of a Source and the min lifetime of
//! all rules
semantic: *const Semantic,
gpa: Allocator,
/// Errors collected by lint rules
errors: Diagnostic.List,

/// this slice is 'static (in data segment) and should never be free'd
curr_rule_name: string = "",
curr_severity: Severity = Severity.err,
// TODO: `void` in release builds
curr_fix_capabilities: Fix.Meta = Fix.Meta.disabled,

/// Are auto fixes enabled?
// fix: bool = false,
fix: Fix.Meta = Fix.Meta.disabled,

source: *Source,

pub fn init(gpa: Allocator, semantic: *const Semantic, source: *Source) Context {
    return Context{
        .semantic = semantic,
        .gpa = gpa,
        .errors = Diagnostic.List.init(gpa),
        .source = source,
    };
}

// ========================= LIFECYCLE MANAGEMENT ==========================
// These methods are used by Linter to adjust state between rule
// invocations.

pub inline fn updateForRule(self: *Context, rule: *const Rule.WithSeverity) void {
    self.curr_rule_name = rule.rule.meta.name;
    self.curr_severity = rule.severity;
    self.curr_fix_capabilities = rule.rule.meta.fix;
}

pub fn takeDiagnostics(self: *Context) Diagnostic.List {
    const errors = self.errors;
    self.errors = Diagnostic.List.init(self.gpa);
    return errors;
}

// ============================== SHORTHANDS ===============================
// Shorthand access to data within the context. Makes writing rules easier.

pub fn ast(self: *const Context) *const Ast {
    return &self.semantic.ast;
}

pub inline fn scopes(self: *const Context) *const Semantic.ScopeTree {
    return &self.semantic.scopes;
}

pub inline fn symbols(self: *const Context) *const Semantic.SymbolTable {
    return &self.semantic.symbols;
}

pub inline fn links(self: *const Context) *const Semantic.NodeLinks {
    return &self.semantic.node_links;
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
    return LabeledSpan{
        .span = .{ .start = s.start, .end = s.end },
        .label = util.Cow(false).fmt(self.gpa, fmt, args) catch @panic("OOM"),
        .primary = false,
    };
}

pub inline fn labelT(
    self: *const Context,
    token_id: Ast.TokenIndex,
    comptime fmt: []const u8,
    args: anytype,
) LabeledSpan {
    const s = self.semantic.ast.tokenToSpan(token_id);
    return LabeledSpan{
        .span = .{ .start = s.start, .end = s.end },
        .label = util.Cow(false).fmt(self.gpa, fmt, args) catch @panic("OOM"),
        .primary = false,
    };
}

/// Create a new `Error` with a static message string.
pub fn diagnostic(
    self: *Context,
    /// error message
    comptime message: string,
    /// location(s) of the problem
    spans: anytype,
) Error {
    var e = Error.newStatic(message);
    e.labels.ensureTotalCapacityPrecise(self.gpa, spans.len) catch @panic("OOM");
    e.labels.appendSliceAssumeCapacity(&spans);
    return e;
}
/// Create a new `Error` with a formatted message
pub fn diagnosticf(self: *Context, comptime template: []const u8, args: anytype, spans: anytype) Error {
    var e = Error.fmt(self.gpa, template, args) catch @panic("OOM");
    e.labels.ensureTotalCapacityPrecise(self.gpa, spans.len) catch @panic("OOM");
    e.labels.appendSliceAssumeCapacity(&spans);
    return e;
}

/// Report a problem found in a source file.
///
/// Use `reportWithFix` to provide an automatic fix for the reported error.  It
/// is highly recommended to provide a fix if possible; this provides the best
/// user experience.
///
/// Reports should have at least one label (they _can_ be, but this is not
/// user-friendly).
///
/// When building a diagnostic, consider separating out the logic for creating
/// the error into a separate factory. This helps keep your rule logic clear and
/// makes it extremely apparent what kind of messages your rule can produce.
///
/// ## Example
/// ```zig
/// const Error = @import("../../Error.zig");
///
/// fn myDiagnostic(ctx: *LinterContext) Error {
///     var err = Error.newStatic("This is a problem");
///     err.labels.append(ctx.gpa, ctx.spanN(wrapper.idx)) catch @panic("OOM");
///     return err;
/// }
///
/// const MyRule = struct {
///   pub fn runOnNode(_: *const MyRule, wrapper: NodeWrapper, ctx: *LinterContext) void {
///     // check for a rule violation..
///     ctx.report(myDiagnostic(ctx));
///   }
/// };
/// ```
pub fn report(self: *Context, diagnostic_: Error) void {
    self._report(Diagnostic{ .err = diagnostic_ });
}

pub fn reportWithFix(
    self: *Context,
    ctx: anytype,
    diagnostic_: Error,
    fixer: *const FixerFn(@TypeOf(ctx)),
) void {
    if (self.fix.isDisabled()) return self._report(Diagnostic{ .err = diagnostic_ });

    if (comptime util.IS_DEBUG and @import("builtin").is_test) {
        util.assert(
            !self.curr_fix_capabilities.isDisabled(),
            "Rule '{s}' just provided an auto-fix without advertising auto-fix capabilities in its `Meta`. Please update your rule's `meta.fix` field.",
            .{self.curr_rule_name},
        );
    }

    const fix_builder = Fix.Builder{
        .allocator = self.gpa,
        .meta = .{ .kind = .fix },
        .ctx = self,
    };
    const fix: Fix = @call(.never_inline, fixer, .{ ctx, fix_builder }) catch |e| {
        std.debug.panic("Fixer for rule \"{s}\" failed: {s}", .{ self.curr_rule_name, @errorName(e) });
    };

    self._report(Diagnostic{ .err = diagnostic_, .fix = fix });
}

fn _report(self: *Context, diagnostic_: Diagnostic) void {
    var d = diagnostic_;
    var e = &d.err;
    e.code = self.curr_rule_name;
    e.source_name = if (self.source.pathname) |p| self.gpa.dupe(u8, p) catch @panic("OOM") else null;
    e.source = self.source.contents.clone();
    e.severity = self.curr_severity;
    // TODO: handle errors better
    self.errors.append(d) catch @panic("Cannot add new error: Out of memory");
}

/// Find the comment block ending on the line before the given token.
pub fn commentsBefore(self: *const Context, token: Ast.TokenIndex) ?[]const u8 {
    const source = self.ast().source;
    var line_start = self.ast().tokenToSpan(token).start;
    while (line_start > 0) : (line_start -= 1) {
        if (source[line_start] == '\n') {
            line_start += 1;
            break;
        }
    }
    if (line_start == 0) return null;
    const comment_end = line_start;
    var comment_start = line_start;

    const source_before = util.trimWhitespaceRight(source[0..comment_end]);
    var lines = mem.splitBackwardsScalar(u8, source_before, '\n');
    while (lines.next()) |line| {
        comment_start -|= @as(u32, @intCast(line.len)) + 1; // 1 for the newline
        if (line.len == 0) continue;
        const curr_snippet = util.trimWhitespace(source[comment_start..comment_end]);
        if (comment_start == 0 or !mem.startsWith(u8, curr_snippet, "//")) break;
    }

    std.debug.assert(comment_start <= comment_end);
    return if (comment_start == comment_end) null else source[comment_start..comment_end];
}

pub fn deinit(self: *Context) void {
    self.errors.deinit();
    // SAFETY: todo: allow undefined in deinit()
    self.* = undefined;
}

pub const Diagnostic = struct {
    err: Error,
    fix: ?Fix = null,

    pub fn deinit(self: *Diagnostic, allocator: Allocator) void {
        self.err.deinit(allocator);
        self.* = undefined;
    }
    // TODO: add comptime check to use `std.ArrayList(Error)` when not fixing
    pub const List = std.ArrayList(Diagnostic);
};

const Context = @This();

const std = @import("std");
const mem = std.mem;
const util = @import("util");
const _rule = @import("rule.zig");
const _source = @import("../source.zig");
const _semantic = @import("../semantic.zig");

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Error = @import("../Error.zig");
const Severity = Error.Severity;
const LabeledSpan = @import("../span.zig").LabeledSpan;
const Rule = _rule.Rule;
const Semantic = _semantic.Semantic;
const Source = _source.Source;
const string = util.string;

const Fix = @import("./fix.zig").Fix;
const FixerFn = @import("./fix.zig").FixerFn;
