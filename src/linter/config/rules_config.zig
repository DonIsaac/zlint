const RuleConfig = @import("rule_config.zig").RuleConfig;
const rules = @import("../rules.zig");

pub const RulesConfig = struct {
    pub usingnamespace @import("./rules_config.methods.zig").RulesConfigMethods(@This());
    homeless_try: RuleConfig(rules.HomelessTry) = .{},
    no_catch_return: RuleConfig(rules.NoCatchReturn) = .{},
    unsafe_undefined: RuleConfig(rules.UnsafeUndefined) = .{},
    no_unresolved: RuleConfig(rules.NoUnresolved) = .{},
    unused_decls: RuleConfig(rules.UnusedDecls) = .{},
    suppressed_errors: RuleConfig(rules.SuppressedErrors) = .{},
    no_return_try: RuleConfig(rules.NoReturnTry) = .{},
};
