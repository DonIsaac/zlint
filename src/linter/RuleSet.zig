rules: std.ArrayListUnmanaged(Rule.WithSeverity) = .{},

const RuleSet = @This();

/// Total number of all lint rules.
pub const RULES_COUNT: usize = @typeInfo(rules).Struct.decls.len;
const ALL_RULE_IMPLS_SIZE: usize = Rule.MAX_SIZE * @typeInfo(rules).Struct.decls.len;
const ALL_RULES_SIZE: usize = @sizeOf(Rule.WithSeverity) * @typeInfo(rules).Struct.decls.len;

pub fn ensureTotalCapacityForAllRules(self: *RuleSet, arena: Allocator) Allocator.Error!void {
    try self.rules.ensureTotalCapacityPrecise(arena.allocator(), ALL_RULE_IMPLS_SIZE);
}

pub fn loadRulesFromConfig(self: *RuleSet, arena: Allocator, config: *const RulesConfig) !void {
    try self.rules.ensureUnusedCapacity(arena, ALL_RULES_SIZE);
    const info = @typeInfo(RulesConfig);
    inline for (info.Struct.fields) |field| {
        const rule = @field(config, field.name);
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
const rules = @import("rules.zig");
const Severity = @import("../Error.zig").Severity;
