rules: RulesConfig = .{},

const Config = @This();

pub const Managed = struct {
    /// should only be set if created from an on-disk config
    path: ?[]const u8 = null,
    config: Config,
    arena: *ArenaAllocator,
};

pub fn intoManaged(self: Config, arena: *ArenaAllocator, path: ?[]const u8) Managed {
    return Managed{
        .config = self,
        .arena = arena,
        .path = path,
    };
}

pub const DEFAULT: Config = .{
    .rules = DEFAULT_RULES_CONFIG,
};

// default rules config lives here b/c RulesConfig is auto-generated
const DEFAULT_RULES_CONFIG: RulesConfig = blk: {
    var config: RulesConfig = .{};

    for (all_rule_decls) |decl| {
        const RuleImpl = @field(all_rules, decl.name);

        // rule names are in kebab-case. RuleConfig has a snake_case field for
        // each rule.
        var config_field_name: [RuleImpl.meta.name.len]u8 = undefined;
        @memcpy(&config_field_name, RuleImpl.meta.name);
        std.mem.replaceScalar(u8, &config_field_name, '-', '_');

        @field(config, &config_field_name) = .{ .severity = RuleImpl.meta.default };
    }

    break :blk config;
};

const all_rules = @import("rules.zig");
const all_rule_decls = @typeInfo(all_rules).@"struct".decls;

const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;

const RulesConfig = @import("config/rules_config.zig").RulesConfig;

// =============================================================================

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(RulesConfig);
}

const t = std.testing;
const print = std.debug.print;
const json = std.json;
const Severity = @import("../Error.zig").Severity;

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
    inline for (info.@"struct".fields) |field| {
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
        \\{ "unsafe-undefined": "error" }
    ,
        RulesConfig{ .unsafe_undefined = .{ .severity = Severity.err } },
    );
    try testConfig(
        \\{
        \\  "unsafe-undefined": "allow",
        \\  "homeless-try": "error"
        \\}
    ,
        RulesConfig{
            .unsafe_undefined = .{ .severity = Severity.off },
            .homeless_try = .{ .severity = Severity.err },
        },
    );
    {
        var scanner = json.Scanner.initCompleteInput(t.allocator,
            \\{ "no-undefined": "allow" }
        );
        defer scanner.deinit();
        try t.expectError(error.UnknownField, json.parseFromTokenSource(
            RulesConfig,
            t.allocator,
            &scanner,
            .{},
        ));
    }
}
