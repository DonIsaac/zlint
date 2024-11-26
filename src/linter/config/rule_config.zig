const std = @import("std");
const json = std.json;
const Severity = @import("../../Error.zig").Severity;
const Tuple = std.meta.Tuple;
const Allocator = std.mem.Allocator;

const ParseError = json.ParseError(json.Scanner);

// TODO: per-rule configuration objects.
pub fn RuleConfig(Rule: type) type {
    return struct {
        severity: Severity = .off,

        pub const name = Rule.meta.name;
        const Self = @This();

        pub fn jsonParse(allocator: Allocator, source: *json.Scanner, options: json.ParseOptions) ParseError!Self {
            const severity = try Severity.jsonParse(allocator, source, options);
            return Self{ .severity = severity };
        }
    };
}

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
