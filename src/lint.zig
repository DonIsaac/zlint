const std = @import("std");
const ptrs = @import("smart-pointers");
const _rule = @import("rule.zig");
const _source = @import("source.zig");
const _semantic = @import("semantic.zig");

const Arc = ptrs.Arc;
const Error = @import("Error.zig");
const Source = _source.Source;
const Span = _source.Span;
const Semantic = _semantic.Semantic;
const SemanticBuilder = _semantic.SemanticBuilder;

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const assert = std.debug.assert;
const fs = std.fs;
const print = std.debug.print;

const Rule = _rule.Rule;
const NodeWrapper = _rule.NodeWrapper;
const string = @import("util").string;

// rules
const NoUndefined = @import("rules/no_undefined.zig").NoUndefined;

// pub const Error = struct {
//     // line break
//     message: []const u8,
//     span: Span,
//     rule_name: []const u8,
//     source: *const Source,
// };

const ErrorList = std.ArrayList(Error);

/// Context is only valid over the lifetime of a Source and the min lifetime of all rules
pub const Context = struct {
    semantic: *const Semantic,
    gpa: Allocator,
    /// Errors collected by lint rules
    errors: ErrorList,
    /// this slice is 'static (in data segment) and should never be free'd
    curr_rule_name: string = "",
    source: *Source,

    fn init(gpa: Allocator, semantic: *const Semantic, source: *Source) Context {
        return Context{
            .semantic = semantic,
            .gpa = gpa,
            .errors = ErrorList.init(gpa),
            .source = source,
        };
    }

    fn deinit(self: *Context) void {
        self.errors.deinit();
        self.* = undefined;
    }

    pub fn ast(self: *const Context) *const Ast {
        return &self.semantic.ast;
    }

    pub inline fn updateForRule(self: *Context, rule: *const Rule) void {
        self.curr_rule_name = rule.name;
    }

    pub fn diagnosticAlloc(self: *Context, message: string, span: Span) void {
        return self._diagnostic(Error.new(message), span);
    }

    pub fn diagnostic(self: *Context, message: string, span: Span) void {
        return self._diagnostic(Error.newStatic(message), span);
    }

    fn _diagnostic(self: *Context, err: Error, _: Span) void {
        var e = err;
        const a = self.gpa;
        // var e = Error.newStatic(message);
        e.source_name = if (self.source.pathname) |p| a.dupe(u8, p) catch @panic("OOM") else null;
        e.source = self.source.contents.clone();
        // TODO: handle errors better
        self.errors.append(e) catch @panic("Cannot add new error: Out of memory");
    }
};

pub const Linter = struct {
    rules: std.ArrayList(Rule),
    gpa: Allocator,

    pub fn init(gpa: Allocator) Linter {
        var linter = Linter{ .rules = std.ArrayList(Rule).init(gpa), .gpa = gpa };
        var no_undef = NoUndefined{};
        // TODO: handle OOM
        linter.rules.append(no_undef.rule()) catch @panic("Cannot add new lint rule: Out of memory");
        return linter;
    }

    pub fn deinit(self: *Linter) void {
        self.rules.deinit();
    }

    pub fn runOnSource(self: *Linter, source: *Source) !ErrorList {
        var semantic_result = try SemanticBuilder.build(self.gpa, source.text());
        defer semantic_result.deinit();
        // TODO
        if (semantic_result.hasErrors()) {
            @panic("semantic analysis failed");
        }
        const semantic = semantic_result.value;
        var ctx = Context.init(self.gpa, &semantic, source);
        print("running linter on source with {d} rules\n", .{self.rules.items.len});

        var i: usize = 0;
        while (i < ctx.semantic.ast.nodes.len) {
            assert(i < std.math.maxInt(u32));
            const node = ctx.semantic.ast.nodes.get(i);
            const wrapper: NodeWrapper = .{
                .node = &node,
                .idx = @intCast(i),
            };
            for (self.rules.items) |rule| {
                ctx.updateForRule(&rule);
                rule.runOnNode(wrapper, &ctx) catch |e| {
                    const err = Error.fmt(self.gpa, "Rule '{s}' failed to run: {s}", .{ rule.name, @errorName(e) }) catch @panic("OOM");
                    ctx.errors.append(err) catch @panic("OOM");
                };
            }
            i += 1;
        }
        return ctx.errors;
    }
};
