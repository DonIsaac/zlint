const RulesConfig = @This();

/// Configuration for all rules.
///
/// The bulk of this strict is auto-generated from all registered rules via
/// `tasks/confgen.zig`.
pub const Rules = @import("Rules.zig");
const all_rules = @import("../rules.zig");
const all_rule_decls = @typeInfo(all_rules).@"struct".decls;

rules: Rules,

pub const empty: RulesConfig = .{ .rules = .{} };

pub const default: RulesConfig = blk: {
    var config: RulesConfig = .{ .rules = .{} };

    for (all_rule_decls) |decl| {
        const RuleImpl = @field(all_rules, decl.name);

        // rule names are in kebab-case. RuleConfig has a snake_case field for
        // each rule.
        var config_field_name: [RuleImpl.meta.name.len]u8 = undefined;
        @memcpy(&config_field_name, RuleImpl.meta.name);
        std.mem.replaceScalar(u8, &config_field_name, '-', '_');

        @field(config.rules, &config_field_name) = .{ .severity = RuleImpl.meta.default };
    }

    break :blk config;
};

/// `RulesConfig`, but every field is nullable and defaults to `null`.
pub const Optional = struct {
    repr: Rules.Optional,

    pub const empty: RulesConfig.Optional = .{ .repr = .{} };

    /// This is a parse-time wrapper, not a schema-level type. On-disk it is
    /// just a `RulesConfig`, so point at that definition.
    pub fn jsonSchema(ctx: *Schema.Context) !Schema {
        return ctx.ref(RulesConfig);
    }

    const ParseError = json.ParseError(json.Scanner);

    /// See: `std.json.parseFromTokenSource()`
    pub fn jsonParse(
        allocator: Allocator,
        source: *json.Scanner,
        options: json.ParseOptions,
    ) !RulesConfig.Optional {
        var rules: Rules.Optional = .{};

        // eat '{'
        if (try source.next() != .object_begin) return ParseError.UnexpectedToken;

        while (try source.peekNextTokenType() != .object_end) {
            const key_tok = try source.next();
            const key = switch (key_tok) {
                .string => key_tok.string,
                else => return ParseError.UnexpectedToken,
            };

            var found = false;
            inline for (std.meta.fields(Rules.Optional)) |field| {
                const RuleConfigImpl = @typeInfo(@TypeOf(@field(rules, field.name))).optional.child;
                if (std.mem.eql(u8, key, RuleConfigImpl.name)) {
                    @field(rules, field.name) = try RuleConfigImpl.jsonParse(allocator, source, options);
                    found = true;
                    break;
                }
            }
            // Deliberately ignores `options.ignore_unknown_fields`. Unknown keys
            // elsewhere in the document are tolerated for forward compatibility,
            // but a misspelled rule name silently does nothing, which is the
            // worst way for a linter config to fail.
            if (!found) return ParseError.UnknownField;
        }

        // eat '}'
        const end = try source.next();
        if (end != .object_end) return ParseError.UnexpectedToken;

        return .{ .repr = rules };
    }
};

pub fn jsonSchema(ctx: *Schema.Context) !Schema {
    const info = @typeInfo(Rules).@"struct";
    var obj = try ctx.object(info.fields.len);
    inline for (info.fields) |field| {
        const Rule = field.type;
        var prop_schema: Schema = try Rule.jsonSchema(ctx);
        prop_schema.common().default = .{ .string = Rule.meta.default.asSlice() };
        obj.properties.putAssumeCapacityNoClobber(Rule.name, prop_schema);
    }
    obj.common.description = "Configure which rules are enabled and how.";

    return .{ .object = obj };
}

const std = @import("std");
const json = std.json;
const meta = std.meta;
const Schema = @import("../../json.zig").Schema;
const Allocator = std.mem.Allocator;
