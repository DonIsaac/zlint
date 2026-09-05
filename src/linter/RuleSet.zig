rules: std.ArrayListUnmanaged(Rule.WithSeverity) = .empty,

const RuleSet = @This();

/// Total number of all lint rules, builtin and custom.
pub const RULES_COUNT: usize = @typeInfo(RulesConfig.Rules).@"struct".fields.len;

pub fn loadRulesFromConfig(self: *RuleSet, arena: Allocator, config: *const RulesConfig) !void {
    try self.rules.ensureUnusedCapacity(arena, RULES_COUNT);
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
    self.* = undefined;
}

/// Check if at least 1 enabled rule requires control flow analysis to run.
pub fn needsCfg(self: *const RuleSet) bool {
    for (self.rules.items) |rule| {
        if (rule.severity != .off and rule.rule.meta.needs_cfg) return true;
    }
    return false;
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Rule = @import("rule.zig").Rule;
const RulesConfig = @import("config/rules_config.zig").RulesConfig;
const Severity = @import("../Error.zig").Severity;
