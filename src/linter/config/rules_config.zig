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

pub const UserRuleConfig = struct {
    // TODO: get default severity from rule dll
    severity: Severity = Severity.err,
    path: []const u8,
    options: ?struct {
        _inner: ?*anyopaque = null,

        pub fn jsonParse(allocator: Allocator, source: *json.Scanner, options: json.ParseOptions) !@This() {
            _ = allocator;
            _ = options;
            if (try source.next() != .object_begin) return ParseError.UnexpectedToken;
            if (try source.next() != .object_end) return ParseError.UnexpectedToken;
            return .{};
        }
    } = null,
};

pub const RulesConfig = struct {
    homeless_try: RuleConfig(rules.HomelessTry) = .{},
    no_catch_return: RuleConfig(rules.NoCatchReturn) = .{},
    no_return_try: RuleConfig(rules.NoReturnTry) = .{},
    no_undefined: RuleConfig(rules.NoUndefined) = .{},
    no_unresolved: RuleConfig(rules.NoUnresolved) = .{},
    suppressed_errors: RuleConfig(rules.SuppressedErrors) = .{},
    unused_decls: RuleConfig(rules.UnusedDecls) = .{},
    _user_rules: std.json.ArrayHashMap(UserRuleConfig) = .{},

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

            // REPORTME: would be nice if inline for supported an else clause
            var handled = false;

            inline for (meta.fields(RulesConfig)) |field| {
                if (comptime mem.startsWith(u8, field.name, "_")) continue;
                const RuleConfigImpl = @TypeOf(@field(config, field.name));
                // TODO: use comptime prefix-tree of known rules
                if (mem.eql(u8, key, RuleConfigImpl.name)) {
                    @field(config, field.name) = try RuleConfigImpl.jsonParse(allocator, source, options);
                    handled = true;
                    break;
                }
            }

            if (!handled) {
                const user_rule_config = try json.innerParse(UserRuleConfig, allocator, source, options);
                try config._user_rules.map.put(allocator, key, user_rule_config);
            }
        }

        // eat '}'
        const end = try source.next();
        assert(end == .object_end);

        return config;
    }
};

// =============================================================================

const t = std.testing;
const print = std.debug.print;

fn testConfig(source: []const u8, expected: RulesConfig) !void {
    var scanner = json.Scanner.initCompleteInput(t.allocator, source);
    defer scanner.deinit();
    var diagnostics = json.Diagnostics{};

    scanner.enableDiagnostics(&diagnostics);
    const actual = json.parseFromTokenSource(RulesConfig, t.allocator, &scanner, .{}) catch |err| {
        print("[{d}:{d}] {s}\n", .{ diagnostics.getLine(), diagnostics.getColumn(), source[diagnostics.line_start_cursor..diagnostics.cursor_pointer.*] });
        return err;
    };
    defer actual.deinit();
    const info = @typeInfo(RulesConfig);
    inline for (info.Struct.fields) |field| {
        if (comptime std.mem.startsWith(u8, field.name, "_")) continue;
        const expected_rule_config = @field(expected, field.name);
        const actual_rule_config = @field(actual.value, field.name);
        // TODO: Test that configs are the same, once rule configuration is implemented.
        t.expectEqual(expected_rule_config.severity, actual_rule_config.severity) catch |err| {
            print("Mismatched severity for rule '{s}':\n", .{field.name});
            print("Expected:\n\n\t{any}\n\n", .{expected});
            print("Actual:\n\n\t{any}\n", .{actual});
            return err;
        };
    }
}

test "RulesConfig.jsonParse" {
    try testConfig("{}", RulesConfig{});
    try testConfig(
        \\{ "no-undefined": "error" }
    ,
        RulesConfig{ .no_undefined = .{ .severity = Severity.err } },
    );
    // FIXME: add user rule parse test
    try testConfig(
        \\{
        \\  "no-undefined": "allow",
        \\  "homeless-try": "error",
        \\}
    ,
        RulesConfig{
            .no_undefined = .{ .severity = Severity.off },
            .homeless_try = .{ .severity = Severity.err },
        },
    );
}
