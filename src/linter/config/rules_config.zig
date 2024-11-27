//! TODO: use codegen to auto-generate this file.

const std = @import("std");
const json = std.json;
const meta = std.meta;
const mem = std.mem;
const rules = @import("../rules.zig");

const Allocator = std.mem.Allocator;
const Severity = @import("../../Error.zig").Severity;
const RuleConfig = @import("rule_config.zig").RuleConfig;
const assert = std.debug.assert;

const ParseError = json.ParseError(json.Scanner);

pub const RulesConfig = struct {
    homeless_try: RuleConfig(rules.HomelessTry) = .{},
    no_catch_return: RuleConfig(rules.NoCatchReturn) = .{},
    no_undefined: RuleConfig(rules.NoUndefined) = .{},
    no_unresolved: RuleConfig(rules.NoUnresolved) = .{},

    pub fn jsonParse(allocator: Allocator, source: *json.Scanner, options: json.ParseOptions) !RulesConfig {
        var config = RulesConfig{};

        // eat '{'
        if (try source.next() != .object_begin) return ParseError.UnexpectedToken;

        while (try source.peekNextTokenType() != .object_end) {
            const key_tok = try source.next();
            const key = switch (key_tok) {
                .string => key_tok.string,
                else => return ParseError.UnexpectedToken,
            };

            inline for (meta.fields(RulesConfig)) |field| {
                const RuleConfigImpl = @TypeOf(@field(config, field.name));
                // const rule = @field(config, field.name);
                if (mem.eql(u8, key, RuleConfigImpl.name)) {
                    @field(config, field.name) = try RuleConfigImpl.jsonParse(allocator, source, options);
                    break;
                }
            }
        }

        // eat '}'
        const end = try source.next();
        assert(end == .object_end);

        return config;
    }
};

// =============================================================================

// FIXME: rule_impl pointers are not equal and I'm not sure why.
// const t = std.testing;
// const print = std.debug.print;

// fn testConfig(source: []const u8, expected: RulesConfig) !void {
//     var scanner = json.Scanner.initCompleteInput(t.allocator, source);
//     defer scanner.deinit();
//     var diagnostics = json.Diagnostics{};

//     scanner.enableDiagnostics(&diagnostics);
//     const actual = json.parseFromTokenSource(RulesConfig, t.allocator, &scanner, .{}) catch |err| {
//         print("[{d}:{d}] {s}\n", .{ diagnostics.getLine(), diagnostics.getColumn(), source[diagnostics.line_start_cursor..diagnostics.cursor_pointer.*] });
//         return err;
//     };
//     defer actual.deinit();
//     t.expectEqualDeep(expected, actual.value) catch |err| {
//         print("Expected:\n\n\t{any}\n\n", .{expected});
//         print("Actual:\n\n\t{any}\n", .{actual});
//         return err;
//     };
// }

// test "RulesConfig.jsonParse" {
//     // try testConfig("{}", RulesConfig{});
//     try testConfig(
//         \\{ "no-undefined": "error" }
//     ,
//         RulesConfig{ .no_undefined = .{ .severity = Severity.err } },
//     );
//     try testConfig(
//         \\{
//         \\  "no-undefined": "allow",
//         \\  "homeless-try": "error"
//         \\}
//     ,
//         RulesConfig{
//             .no_undefined = .{ .severity = Severity.off },
//             .homeless_try = .{ .severity = Severity.err },
//         },
//     );
// }
