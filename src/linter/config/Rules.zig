//! Rule configuration struct, built at comptime from `all_rules.zig`.

const std = @import("std");
const all_rules = @import("../all_rules.zig");
const RuleConfig = @import("rule_config.zig").RuleConfig;

/// A `RuleConfig` field per rule, named after the rule in snake_case.
///
/// e.g. `homeless_try: RuleConfig(rules.HomelessTry) = .{}`
pub const Rules = blk: {
    const len = all_rules.all.len;
    var names: [len][]const u8 = undefined;
    var types: [len]type = undefined;
    var attrs: [len]std.builtin.Type.StructField.Attributes = undefined;

    for (all_rules.all, 0..) |RuleImpl, i| {
        const Config = RuleConfig(RuleImpl);
        names[i] = all_rules.snakeName(RuleImpl);
        types[i] = Config;
        attrs[i] = .{ .default_value_ptr = @ptrCast(&Config{}) };
    }

    const frozen_names = names;
    const frozen_types = types;
    const frozen_attrs = attrs;
    break :blk @Struct(.auto, null, &frozen_names, &frozen_types, &frozen_attrs);
};
