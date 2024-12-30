rules: RulesConfig = .{},

const Config = @This();

pub const Managed = struct {
    /// should only be set if created from an on-disk config
    path: ?[]const u8 = null,
    config: Config,
    arena: *std.heap.ArenaAllocator,
};

pub fn intoManaged(self: Config, arena: *std.heap.ArenaAllocator, path: ?[]const u8) Managed {
    return Managed{
        .config = self,
        .arena = arena,
        .path = path,
    };
}

pub const DEFAULT: Config = .{
    .rules = DEFAULT_RULES_CONFIG,
};

// default rules config lives here b/c I plan on generating rules_config.zig
// later.

const DEFAULT_RULES_CONFIG: RulesConfig = blk: {
    // var ruleset: [all_rule_decls.len]Rule = undefined;
    // var i = 0;
    var config: RulesConfig = .{};

    for (all_rule_decls) |decl| {
        const RuleImpl = @field(all_rules, decl.name);

        // rule names are in kebab-case. RuleConfig has a snake_case field for
        // each rule.
        var config_field_name: [RuleImpl.meta.name.len]u8 = undefined;
        @memcpy(&config_field_name, RuleImpl.meta.name);
        std.mem.replaceScalar(u8, &config_field_name, '-', '_');

        @field(config, &config_field_name) = .{ .severity = RuleImpl.meta.default };
    }

    break :blk config;
};

const all_rules = @import("rules.zig");
const all_rule_decls = @typeInfo(all_rules).Struct.decls;

const std = @import("std");
const util = @import("util");
const json = std.json;
const string = util.string;

const Rule = @import("rule.zig").Rule;

const RulesConfig = @import("config/rules_config.zig").RulesConfig;

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(RulesConfig);
}
