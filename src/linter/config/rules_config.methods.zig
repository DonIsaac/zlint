const std = @import("std");
const json = std.json;
const meta = std.meta;
const mem = std.mem;
const Schema = @import("../../json.zig").Schema;

const Allocator = std.mem.Allocator;

const assert = std.debug.assert;

const ParseError = json.ParseError(json.Scanner);

/// RulesConfig methods are separated out so that they can be easily integrated
/// with codegen'd struct definitions.
pub fn RulesConfigMethods(RulesConfig: type) type {
    return struct {
        /// See: `std.json.parseFromTokenSource()`
        pub fn jsonParse(
            allocator: Allocator,
            source: *json.Scanner,
            options: json.ParseOptions,
        ) !RulesConfig {
            var config = RulesConfig{};

            // eat '{'
            if (try source.next() != .object_begin) return ParseError.UnexpectedToken;

            while (try source.peekNextTokenType() != .object_end) {
                const key_tok = try source.next();
                const key = switch (key_tok) {
                    .string => key_tok.string,
                    else => return ParseError.UnexpectedToken,
                };

                var found = false;
                inline for (meta.fields(RulesConfig)) |field| {
                    const RuleConfigImpl = @TypeOf(@field(config, field.name));
                    if (mem.eql(u8, key, RuleConfigImpl.name)) {
                        @field(config, field.name) = try RuleConfigImpl.jsonParse(allocator, source, options);
                        found = true;
                        break;
                    }
                }
                if (!found) return ParseError.UnknownField;
            }

            // eat '}'
            const end = try source.next();
            assert(end == .object_end);

            return config;
        }

        pub fn jsonSchema(ctx: *Schema.Context) !Schema {
            const info = @typeInfo(RulesConfig).@"struct";
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
    };
}
