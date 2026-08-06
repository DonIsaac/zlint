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

/// See: `std.json.parseFromTokenSource()`
pub fn jsonParse(
    allocator: Allocator,
    source: *json.Scanner,
    options: json.ParseOptions,
) !RulesConfig {
    var rules = Rules{};

    // eat '{'
    if (try source.next() != .object_begin) return ParseError.UnexpectedToken;

    while (try source.peekNextTokenType() != .object_end) {
        const key_tok = try source.next();
        const key = switch (key_tok) {
            .string => key_tok.string,
            else => return ParseError.UnexpectedToken,
        };

        var found = false;
        inline for (meta.fields(Rules)) |field| {
            const RuleConfigImpl = @TypeOf(@field(rules, field.name));
            if (mem.eql(u8, key, RuleConfigImpl.name)) {
                @field(rules, field.name) = try RuleConfigImpl.jsonParse(allocator, source, options);
                found = true;
                break;
            }
        }
        if (!found) return ParseError.UnknownField;
    }

    // eat '}'
    const end = try source.next();
    assert(end == .object_end);

    return .{ .rules = rules };
}

pub fn jsonSchema(ctx: *Schema.Context) !Schema {
    const info = @typeInfo(RulesConfig.Rules).@"struct";
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
const mem = std.mem;
const Schema = @import("../../json.zig").Schema;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const ParseError = json.ParseError(json.Scanner);
