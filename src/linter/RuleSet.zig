rules: std.ArrayListUnmanaged(Rule.WithSeverity) = .empty,

const RuleSet = @This();

/// Total number of all lint rules, builtin and custom.
pub const RULES_COUNT: usize = @typeInfo(RulesConfig.Rules).@"struct".fields.len;
const ALL_RULE_IMPLS_SIZE: usize = Rule.MAX_SIZE * RULES_COUNT;
const ALL_RULES_SIZE: usize = @sizeOf(Rule.WithSeverity) * RULES_COUNT;

pub fn ensureTotalCapacityForAllRules(self: *RuleSet, arena: Allocator) Allocator.Error!void {
    try self.rules.ensureTotalCapacityPrecise(arena.allocator(), RULES_COUNT);
}

pub fn loadRulesFromConfig(self: *RuleSet, arena: Allocator, config: *const RulesConfig) !void {
    try self.rules.ensureUnusedCapacity(arena, ALL_RULES_SIZE);
    const info = @typeInfo(RulesConfig.Rules);
    inline for (info.@"struct".fields) |field| {
        const rule = @field(config.rules, field.name);
        if (rule.severity != Severity.off) {
            self.rules.appendAssumeCapacity(.{
                .severity = rule.severity,
                // FIXME: unsafe const cast
                .rule = @constCast(&rule).rule(),
            });
        }
    }
}

pub fn deinit(self: *RuleSet, arena: Allocator) void {
    self.rules.deinit(arena);
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Rule = @import("rule.zig").Rule;
const RulesConfig = @import("config/rules_config.zig").RulesConfig;
const Severity = @import("../Error.zig").Severity;
