const std = @import("std");
const util = @import("util");
const _source = @import("../source.zig");
const Semantic = @import("../Semantic.zig");

const _rule = @import("rule.zig");
const Context = @import("lint_context.zig");
const disable_directives = @import("disable_directives.zig");
const Suppressions = disable_directives.Suppressions;

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
        io: std.Io,
        semantic: *const Semantic,
        source: *Source,
        errors: *?std.array_list.Managed(Context.Diagnostic),
    ) (LintError || Allocator.Error)!void {
        var suppressions: Suppressions = try .init(self.gpa, semantic);
        defer suppressions.deinit(self.gpa);
        // SAFETY: only the slice returned by getRulesForFile is read
        var rulebuf: [RuleSet.RULES_COUNT]Rule.WithSeverity = undefined;
        const rules = self.getRulesForFile(&rulebuf, &suppressions.global) orelse return;

        var ctx = Context.init(self.gpa, io, semantic, source);
        defer ctx.deinit();
        ctx.fix = self.options.fix;
        ctx.suppressions = &suppressions;
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
                    .idx = @fromBackingInt(@intCast(i)),
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

    /// Get the list of rules that should be run on a file, excluding rules
    /// disabled for the whole file.
    ///
    /// ## Returns
    /// - This linter's configured rules when no rules are disabled. `rulebuf`
    ///   is unmodified.
    /// - A slice of `rulebuf` holding the remaining rules when some are disabled.
    /// - `null` if all rules are disabled.
    fn getRulesForFile(
        self: *const Linter,
        rulebuf: *[RuleSet.RULES_COUNT]Rule.WithSeverity,
        disabled: *const Suppressions.RuleMask,
    ) ?[]const Rule.WithSeverity {
        const configured_rules = self.rules.rules.items;
        if (disabled.count() == 0) return configured_rules;
        util.assert(configured_rules.len <= rulebuf.len, "{d} rules are configured but at most {d} may be enabled", .{ configured_rules.len, rulebuf.len });

        var i: usize = 0;
        for (configured_rules) |rule| {
            if (disabled.isSet(rule.rule.id.int())) continue;
            rulebuf[i] = rule;
            i += 1;
        }
        return if (i == 0) null else rulebuf[0..i];
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
    std.testing.refAllDecls(disable_directives);
}
