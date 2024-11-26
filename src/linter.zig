const std = @import("std");
const ptrs = @import("smart-pointers");
const _source = @import("source.zig");
const _semantic = @import("semantic.zig");

const _rule = @import("linter/rule.zig");
const Context = @import("linter/lint_context.zig");
const ErrorList = Context.ErrorList;

const Arc = ptrs.Arc;
const Error = @import("Error.zig");
const Severity = Error.Severity;
const Source = _source.Source;
const Span = _source.Span;
const LabeledSpan = _source.LabeledSpan;
const Semantic = _semantic.Semantic;
const SemanticBuilder = _semantic.SemanticBuilder;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Ast = std.zig.Ast;
const assert = std.debug.assert;
const fs = std.fs;
const print = std.debug.print;

const Rule = _rule.Rule;
const RuleSet = @import("linter/RuleSet.zig");
const NodeWrapper = _rule.NodeWrapper;
const string = @import("util").string;

const rules = @import("./linter/rules.zig");
pub const Config = @import("./linter/Config.zig");

pub const Linter = struct {
    rules: RuleSet = .{},
    gpa: Allocator,
    arena: ArenaAllocator,

    pub fn initEmpty(gpa: Allocator) Linter {
        return Linter{ .gpa = gpa, .arena = ArenaAllocator.init(gpa) };
    }

    pub fn init(gpa: Allocator, config: Config.Managed) !Linter {
        var ruleset = RuleSet{};
        var arena = config.arena;
        try ruleset.loadRulesFromConfig(arena.allocator(), &config.config.rules);
        const linter = Linter{
            .rules = ruleset,
            .gpa = gpa,
            .arena = arena,
        };
        return linter;
    }

    pub fn registerRule(self: *Linter, severity: Severity, rule: Rule) !void {
        try self.rules.rules.append(
            self.arena.allocator(),
            .{ .severity = severity, .rule = rule },
        );
    }

    pub fn deinit(self: *Linter) void {
        // NOTE: rules are arena-allocated and do not need to be deinitialized
        // directly.
        self.arena.deinit();
    }

    pub fn runOnSource(
        self: *Linter,
        source: *Source,
        errors: *?ErrorList,
    ) (LintError || Allocator.Error)!void {
        var builder = SemanticBuilder.init(self.gpa);
        defer builder.deinit();

        var semantic_result = builder.build(source.text()) catch |e| {
            errors.* = builder._errors.toManaged(self.gpa);
            return switch (e) {
                error.ParseFailed => LintError.ParseFailed,
                else => LintError.AnalysisFailed,
            };
        };
        if (semantic_result.hasErrors()) {
            errors.* = builder._errors.toManaged(self.gpa);
            semantic_result.value.deinit();
            return LintError.AnalysisFailed;
        }
        defer semantic_result.deinit();

        const semantic = semantic_result.value;
        var ctx = Context.init(self.gpa, &semantic, source);
        const nodes = ctx.semantic.ast.nodes;
        assert(nodes.len < std.math.maxInt(u32));

        // Check each node in the AST
        // Note: rules are in outer loop for better cache locality. Nodes are
        // stored in an arena, so iterating has good cache-hit characteristics.
        for (self.rules.rules.items) |rule_with_severity| {
            const rule = rule_with_severity.rule;
            ctx.updateForRule(&rule_with_severity);
            for (0..nodes.len) |i| {
                const node = nodes.get(i);
                const wrapper: NodeWrapper = .{
                    .node = &node,
                    .idx = @intCast(i),
                };
                rule.runOnNode(wrapper, &ctx) catch |e| {
                    const err = try Error.fmt(
                        self.gpa,
                        "Rule '{s}' failed to run: {s}",
                        .{ rule.meta.name, @errorName(e) },
                    );
                    try ctx.errors.append(err);
                };
            }
        }

        // Check each declared symbol
        for (self.rules.rules.items) |rule_with_severity| {
            const rule = rule_with_severity.rule;
            ctx.updateForRule(&rule_with_severity);
            var symbols = ctx.semantic.symbols.iter();
            while (symbols.next()) |symbol| {
                rule.runOnSymbol(symbol, &ctx) catch |e| {
                    const err = try Error.fmt(
                        self.gpa,
                        "Rule '{s}' failed to run: {s}",
                        .{ rule.meta.name, @errorName(e) },
                    );
                    try ctx.errors.append(err);
                };
            }
        }

        if (ctx.errors.items.len > 0) {
            errors.* = ctx.errors;
            return LintError.LintingFailed;
        }
    }

    pub const LintError = error{
        ParseFailed,
        AnalysisFailed,
        LintingFailed,
    };
};

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(@import("linter/tester.zig"));
    std.testing.refAllDeclsRecursive(rules);
}
