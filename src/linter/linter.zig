const std = @import("std");
const _source = @import("../source.zig");
const Semantic = @import("../Semantic.zig");

const _rule = @import("rule.zig");
const Context = @import("lint_context.zig");
const disable_directives = @import("disable_directives.zig");

const Fix = @import("fix.zig").Fix;

const Error = @import("../Error.zig");
const Severity = Error.Severity;
const Source = _source.Source;

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const assert = std.debug.assert;

const Rule = _rule.Rule;
const RuleSet = @import("RuleSet.zig");
const NodeWrapper = _rule.NodeWrapper;

pub const Config = @import("Config.zig");

pub const Linter = struct {
    rules: RuleSet = .{},
    gpa: Allocator,
    arena: ArenaAllocator,
    options: Options = .{},

    // TODO: move diagnostic definition here or just somewhere better
    pub const Diagnostic = Context.Diagnostic;

    pub fn initEmpty(gpa: Allocator) Linter {
        return Linter{ .gpa = gpa, .arena = ArenaAllocator.init(gpa) };
    }

    pub fn init(gpa: Allocator, config: Config.Managed) !Linter {
        return initWithOptions(gpa, config, .{});
    }
    pub fn initWithOptions(gpa: Allocator, config: Config.Managed, options: Options) !Linter {
        var arena = ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        var ruleset = RuleSet{};
        try ruleset.loadRulesFromConfig(arena.allocator(), &config.config.rules);
        const linter = Linter{
            .rules = ruleset,
            .gpa = gpa,
            .arena = arena,
            .options = options,
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
        self.rules.deinit(self.arena.allocator());
        self.arena.deinit();
    }

    /// Lint a Zig source file.
    ///
    /// ## Diagnostics
    /// Parse, semantic, and lint errors are stored in `errors`. Callers should
    /// pass a reference to a `null`-initialized error list. If any errors
    /// occur, that `null` value will be replaced with a list of errors, and a
    /// `LintError` will be returned to indicate what stage the linter got to
    /// before exiting.
    pub fn runOnSource(
        self: *Linter,
        semantic: *const Semantic,
        source: *Source,
        errors: *?std.ArrayList(Context.Diagnostic),
    ) (LintError || Allocator.Error)!void {
        var rulebuf: [RuleSet.RULES_COUNT]Rule.WithSeverity = undefined;
        const rules = try self.getRulesForFile(&rulebuf, semantic) orelse return;

        var ctx = Context.init(self.gpa, semantic, source);
        defer ctx.deinit();
        ctx.fix = self.options.fix;
        const nodes = ctx.semantic.nodes();
        assert(nodes.len < std.math.maxInt(u32));

        // Some rules do special checks and just need access to the source once.
        for (rules) |rule_with_severity| {
            const rule = rule_with_severity.rule;
            ctx.updateForRule(&rule_with_severity);
            rule.runOnce(&ctx) catch |e| {
                const err = try Error.fmt(
                    self.gpa,
                    "Rule '{s}' failed to run: {s}",
                    .{ rule.meta.name, @errorName(e) },
                );
                ctx.report(err);
            };
        }

        // Check each node in the AST
        // Note: rules are in outer loop for better cache locality. Nodes are
        // stored in an arena, so iterating has good cache-hit characteristics.
        for (rules) |rule_with_severity| {
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
                    ctx.report(err);
                };
            }
        }

        // Check each declared symbol
        for (rules) |rule_with_severity| {
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
                    ctx.report(err);
                };
            }
        }
        if (ctx.diagnostics.items.len == 0) return;
        errors.* = ctx.takeDiagnostics();
        return error.LintingFailed;
    }

    /// Get the list of rules that should be run on a file. Rules disabled
    /// globally are filtered out.
    ///
    /// ## Returns
    /// - When filtering occurs, remaining rules are stored in `rulebuf`, and
    ///   the slice of that buffer storing rules is returned.
    /// - A slice over `rulebuf` when at least one rule is filtered out. It contains
    ///   the rules that were not filtered.
    /// - `null` if all rules are filtered out;
    /// - A pointer to this linter's owned ruleset when no rules are filtered out.
    ///   `rulebuf` will be unmodified.
    fn getRulesForFile(
        self: *Linter,
        rulebuf: *[RuleSet.RULES_COUNT]Rule.WithSeverity,
        semantic: *const Semantic,
    ) Allocator.Error!?[]const Rule.WithSeverity {
        const configured_rules = self.rules.rules.items;
        const alloc = self.arena.allocator();
        var parser = disable_directives.Parser.new(semantic.source());
        // global disable directives may be placed anywhere before the first
        // non-doc comment token. Doc comments may have global disable directives.
        var start_of_first_non_doc_tok: u32 = 0;

        {
            var toks = semantic.parse.ast.tokens;
            const tok_starts: []const u32 = toks.items(.start);
            const tok_tags: []const Semantic.Token.Tag = toks.items(.tag);
            for (0..toks.len) |i| {
                switch (tok_tags[i]) {
                    .doc_comment, .container_doc_comment => {
                        const end: u32 = @truncate(semantic.tokens().items(.loc)[i].end);
                        if (try parser.parse(alloc, .{ .start = tok_starts[i], .end = end })) |comment| {
                            // TODO: support next-line diagnostics
                            if (!comment.isGlobal()) continue;
                            return if (comment.disablesAllRules()) null else filterDisabledRules(
                                semantic.source(),
                                rulebuf,
                                configured_rules,
                                &comment,
                            );
                        }
                    },
                    else => {
                        start_of_first_non_doc_tok = tok_starts[i];
                        break;
                    },
                }
            }
        }

        // Look for global disable directives in normal comments by parsing
        // comments up to the first non-comment token.
        for (0..semantic.comments().len) |i| {
            const comment = semantic.comments().get(i);
            if (comment.start >= start_of_first_non_doc_tok) break;
            const dd = try parser.parse(alloc, comment) orelse continue;
            // TODO: support next-line diagnostics
            if (!dd.isGlobal()) continue;
            return if (dd.disablesAllRules()) null else filterDisabledRules(
                semantic.source(),
                rulebuf,
                configured_rules,
                &dd,
            );
        }

        return configured_rules;
    }

    /// Filter out configured rules based on a disable directive that
    /// _definitely_ has at least one named rule disabled.
    fn filterDisabledRules(
        source: []const u8,
        rulebuf: *[RuleSet.RULES_COUNT]Rule.WithSeverity,
        configured_rules: []const Rule.WithSeverity,
        dd: *const disable_directives.Comment,
    ) ?[]const Rule.WithSeverity {
        assert(dd.disabled_rules.len > 0);
        var disabled_rules_buf: [RuleSet.RULES_COUNT]Rule.Id = undefined;
        const disabled_rules: []const Rule.Id = blk: {
            var i: usize = 0;
            for (dd.disabled_rules) |rule_span| {
                const rule_name = source[rule_span.start..rule_span.end];
                if (Rule.getIdFor(rule_name)) |id| {
                    disabled_rules_buf[i] = id;
                    i += 1;
                }
            }

            if (i == 0) return configured_rules;
            break :blk disabled_rules_buf[0..i];
        };
        assert(disabled_rules.len > 0); // for LLVM optimizations. TODO: check if needed.

        var i: usize = 0;
        for (configured_rules) |rule| {
            if (std.mem.indexOfScalar(Rule.Id, disabled_rules, rule.rule.id) == null) {
                rulebuf[i] = rule;
                i += 1;
            }
        }
        // no rules will be matched if disable directives are misused or rule
        // names are misspelled (e.g. `zlint-disable not-a-rule`). In this case,
        // no rules are disabled so we just run them all.
        return rulebuf[0..i];
    }

    pub const LintError = error{
        ParseFailed,
        AnalysisFailed,
        LintingFailed,
    };

    pub const Options = struct {
        fix: Fix.Meta = Fix.Meta.disabled,
    };
};

test {
    std.testing.refAllDecls(@This());
}
