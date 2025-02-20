// Auto-generated by `tasks/confgen.zig`. Do not edit manually.
const RuleConfig = @import("rule_config.zig").RuleConfig;
const rules = @import("../rules.zig");

pub const RulesConfig = struct {
    pub usingnamespace @import("./rules_config.methods.zig").RulesConfigMethods(@This());
    homeless_try: RuleConfig(rules.HomelessTry) = .{},
    no_catch_return: RuleConfig(rules.NoCatchReturn) = .{},
    no_return_try: RuleConfig(rules.NoReturnTry) = .{},
    no_unresolved: RuleConfig(rules.NoUnresolved) = .{},
    suppressed_errors: RuleConfig(rules.SuppressedErrors) = .{},
    unsafe_undefined: RuleConfig(rules.UnsafeUndefined) = .{},
    unused_decls: RuleConfig(rules.UnusedDecls) = .{},
    must_return_ref: RuleConfig(rules.MustReturnRef) = .{},
    useless_error_return: RuleConfig(rules.UselessErrorReturn) = .{},
};
