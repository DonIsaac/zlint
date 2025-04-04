const std = @import("std");
const json = std.json;
const Severity = @import("../../Error.zig").Severity;
const Allocator = std.mem.Allocator;
const Rule = @import("../rule.zig").Rule;
const Schema = @import("../../json.zig").Schema;

const ParseError = json.ParseError(json.Scanner);

// TODO: per-rule configuration objects.
pub fn RuleConfig(RuleImpl: type) type {
    const DEFAULT: RuleImpl = .{};
    return struct {
        severity: Severity = .off,
        // FIXME: unsafe const cast
        rule_impl: *anyopaque = @ptrCast(@constCast(&DEFAULT)),

        pub const name = RuleImpl.meta.name;
        const Self = @This();

        pub fn jsonParse(allocator: Allocator, source: *json.Scanner, options: json.ParseOptions) ParseError!Self {
            const severity = try Severity.jsonParse(allocator, source, options);
            const rule_impl = try allocator.create(RuleImpl);
            rule_impl.* = .{};
            return Self{ .severity = severity, .rule_impl = rule_impl };
        }

        pub fn jsonSchema(ctx: *Schema.Root) !Schema {
            return ctx.ref(Severity);
        }

        pub fn rule(self: *Self) Rule {
            const rule_impl: *RuleImpl = @ptrCast(@alignCast(@constCast(self.rule_impl)));
            return rule_impl.rule();
        }
    };
}

// TODO: per-rule configuration objects.
// pub fn RuleConfig(Rule: type) type {
//     if (!@hasDecl(Rule, "Config") or Rule.Config == void) {
//         return RuleConfigWithDefault(Rule, void, {});
//     } else {
//         return RuleConfigWithDefault(Rule, Rule.Config, .{});
//     }
// }

// fn RuleConfigWithDefault(TRule: type, Config: type, default: @TypeOf(Config)) type {
//     return struct {
//         severity: Severity,
//         config: Config = default,

//         pub const Rule = TRule;
//         const Self = @This();

//         pub fn jsonParse(allocator: Allocator, source: *json.Scanner, options: json.ParseOptions) !Self {
//             switch (try source.peekNextTokenType()) {
//                 .string, .number => {
//                     const severity = try json.parseFromTokenSourceLeaky(Severity, allocator, source, options);
//                     return Self{ .severity = severity };
//                 },
//                 .array_begin => {
//                     @Todo("handle configs")
//                 }
//             }
//         }
//     };
// }
