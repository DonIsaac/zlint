const std = @import("std");
const json = std.json;
const meta = std.meta;
const mem = std.mem;
const Schema = @import("../../json.zig").Schema;

const Allocator = std.mem.Allocator;

const assert = std.debug.assert;

const ParseError = json.ParseError(json.Scanner);

/// Configuration for all rules.
///
/// The bulk of this strict is auto-generated from all registered rules via
/// `tasks/confgen.zig`.
pub const RulesConfig = struct {
    pub const Rules = @import("Rules.zig").Rules;

    rules: Rules,

    /// Config with all rules turned off
    pub const empty: RulesConfig = .{ .rules = .{} };
    /// Config with rule respecting default severities
    pub const default: RulesConfig = blk: {
        var config: RulesConfig = .empty;

        const info = @typeInfo(RulesConfig.Rules).@"struct";
        for (info.field_names, info.field_types) |field_name, field_type| {
            @field(config.rules, field_name) = .{ .severity = field_type.meta.default };
        }

        break :blk config;
    };

    /// See: `std.json.parseFromTokenSource()`
    pub fn jsonParse(
        allocator: Allocator,
        source: *json.Scanner,
        options: json.ParseOptions,
    ) !RulesConfig {
        var rules = RulesConfig.default.rules;

        // eat '{'
        if (try source.next() != .object_begin) return ParseError.UnexpectedToken;

        while (try source.peekNextTokenType() != .object_end) {
            const key_tok = try source.next();
            const key = switch (key_tok) {
                .string => key_tok.string,
                else => return ParseError.UnexpectedToken,
            };

            var found = false;
            inline for (@typeInfo(Rules).@"struct".field_names) |field_name| {
                const RuleConfigImpl = @FieldType(Rules, field_name);
                if (mem.eql(u8, key, RuleConfigImpl.name)) {
                    @field(rules, field_name) = try RuleConfigImpl.jsonParse(allocator, source, options);
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
        var obj = try ctx.object(info.field_types.len);
        inline for (info.field_types) |Rule| {
            var prop_schema: Schema = try Rule.jsonSchema(ctx);
            prop_schema.common().default = .{ .string = Rule.meta.default.asSlice() };
            obj.properties.putAssumeCapacityNoClobber(Rule.name, prop_schema);
        }
        obj.common.description = "Configure which rules are enabled and how.";

        return .{ .object = obj };
    }
};
