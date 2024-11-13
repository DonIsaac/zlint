const std = @import("std");
const ptrs = @import("smart-pointers");
const _source = @import("source.zig");
const _semantic = @import("semantic.zig");

const _rule = @import("linter/rule.zig");
const Context = @import("linter/lint_context.zig");
const ErrorList = Context.ErrorList;

const Arc = ptrs.Arc;
const Error = @import("Error.zig");
const Source = _source.Source;
const Span = _source.Span;
const LabeledSpan = _source.LabeledSpan;
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
const NoUndefined = @import("linter/rules/no_undefined.zig").NoUndefined;

pub const Linter = struct {
    rules: std.ArrayList(Rule),
    gpa: Allocator,

    pub fn init(gpa: Allocator) Linter {
        var linter = Linter{
            .rules = std.ArrayList(Rule).init(gpa),
            .gpa = gpa,
        };
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
                    const err = Error.fmt(
                        self.gpa,
                        "Rule '{s}' failed to run: {s}",
                        .{ rule.name, @errorName(e) },
                    ) catch @panic("OOM");
                    ctx.errors.append(err) catch @panic("OOM");
                };
            }
            i += 1;
        }
        return ctx.errors;
    }
};
