rules: std.ArrayListUnmanaged(Rule.WithSeverity) = .{},

const RuleSet = @This();

/// Total number of all lint rules.
pub const BUILTIN_RULES_COUNT: usize = @typeInfo(rules).Struct.decls.len;
const BUILTIN_RULE_IMPLS_SIZE: usize = Rule.MAX_SIZE * @typeInfo(rules).Struct.decls.len;
const BUILTIN_RULES_SIZE: usize = @sizeOf(Rule.WithSeverity) * @typeInfo(rules).Struct.decls.len;

pub fn ensureTotalCapacityForAllRules(self: *RuleSet, arena: Allocator) Allocator.Error!void {
    try self.rules.ensureTotalCapacityPrecise(arena.allocator(), BUILTIN_RULE_IMPLS_SIZE);
}

pub fn loadRulesFromConfig(self: *RuleSet, arena: Allocator, config: *const RulesConfig) !void {
    try self.rules.ensureUnusedCapacity(arena, BUILTIN_RULES_SIZE + config._user_rules.count());

    const info = @typeInfo(RulesConfig);
    inline for (info.Struct.fields) |field| {
        if (std.mem.startsWith(u8, field.name, "_")) {
            continue;
        }
        const rule = @field(config, field.name);
        if (rule.severity != Severity.off) {
            self.rules.appendAssumeCapacity(.{
                .severity = rule.severity,
                // FIXME: unsafe const cast
                .rule = @constCast(&rule).rule(),
            });
        }
    }

    {
        var user_rule_iter = config._user_rules.iterator();
        while (user_rule_iter.next()) |user_rule_entry| {
            const path = user_rule_entry.value_ptr.path;
            const rule = Rule.initUserDefined(path) catch |err| {
                std.log.err("Failed with {} loading custom rule at '{s}'", .{ err, path });
                continue;
            };

            self.rules.appendAssumeCapacity(.{
                // FIXME:
                .severity = .err,
                .rule = rule,
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

const meta = std.meta;
const Type = std.builtin.Type;
