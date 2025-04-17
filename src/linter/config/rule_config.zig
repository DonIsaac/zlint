const std = @import("std");
const json = std.json;
const Severity = @import("../../Error.zig").Severity;
const Allocator = std.mem.Allocator;
const Rule = @import("../rule.zig").Rule;
const Schema = @import("../../json.zig").Schema;

const ParseError = json.ParseError(json.Scanner);

pub fn RuleConfig(RuleImpl: type) type {
    return struct {
        severity: Severity = .off,
        // FIXME: unsafe const cast
        rule_impl: *anyopaque = @ptrCast(@constCast(&default)),

        pub const name = RuleImpl.meta.name;
        pub const meta: Rule.Meta = RuleImpl.meta;
        pub const default: RuleImpl = .{};
        const Self = @This();

        pub fn jsonParse(allocator: Allocator, source: *json.Scanner, options: json.ParseOptions) ParseError!Self {
            switch (try source.peekNextTokenType()) {
                .string, .number => {
                    @branchHint(.likely);
                    const severity = try Severity.jsonParse(allocator, source, options);
                    const rule_impl = try allocator.create(RuleImpl);
                    rule_impl.* = .{};
                    return Self{ .severity = severity, .rule_impl = rule_impl };
                },
                .array_begin => {
                    _ = try source.next();
                    const severity = try Severity.jsonParse(allocator, source, options);
                    const rule_impl = try allocator.create(RuleImpl);
                    if (try source.peekNextTokenType() == .array_end) {
                        _ = try source.next();
                        rule_impl.* = .{};
                    } else {
                        rule_impl.* = try json.innerParse(RuleImpl, allocator, source, options);
                        const tok = try source.next();
                        if (tok != .array_end) {
                            @branchHint(.cold);
                            return ParseError.UnexpectedToken;
                        }
                    }
                    return Self{ .severity = severity, .rule_impl = rule_impl };
                },
                else => return ParseError.UnexpectedToken,
            }
        }

        pub fn jsonSchema(ctx: *Schema.Context) !Schema {
            const severity = try ctx.ref(Severity);
            var rule_config = try ctx.ref(RuleImpl);
            rule_config.@"$ref".resolve(ctx).?.common().title = try std.fmt.allocPrint(ctx.allocator, "{s} config", .{RuleImpl.meta.name});

            const schema = if (rule_config == .object and rule_config.object.properties.count() == 0)
                severity
            else compound: {
                var config_schema = try ctx.tuple([_]Schema{ severity, rule_config });
                var common = config_schema.common();
                try common.extra_values.put(ctx.allocator, "items", json.Value{ .bool = false });

                break :compound try ctx.oneOf(&[_]Schema{ severity, config_schema });
            };

            return schema;
        }

        pub fn rule(self: *Self) Rule {
            const rule_impl: *RuleImpl = @ptrCast(@alignCast(@constCast(self.rule_impl)));
            return rule_impl.rule();
        }
    };
}
