rules: RulesConfig = .{},
ignore: []const []const u8 = &[_][]const u8{},

const Config = @This();

pub const Managed = struct {
    /// should only be set if created from an on-disk config
    path: ?[]const u8 = null,
    config: Config,
    arena: *ArenaAllocator,
    pub inline fn allocator(self: *Managed) Allocator {
        return self.arena.allocator();
    }
    pub inline fn deinit(self: *Managed) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn intoManaged(self: Config, arena: *ArenaAllocator, path: ?[]const u8) Managed {
    return Managed{ .config = self, .arena = arena, .path = path };
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

        @field(config.rules, &config_field_name) = .{ .severity = RuleImpl.meta.default };
    }

    break :blk config;
};

const NamedSeverity = struct { []const u8, Severity };

/// Every rule's `(name, default severity)`, sorted by name.
const default_rule_severities: [all_rule_decls.len]NamedSeverity = blk: {
    var entries: [all_rule_decls.len]NamedSeverity = undefined;
    for (all_rule_decls, 0..) |decl, i| {
        const RuleImpl = @field(all_rules, decl.name);
        entries[i] = .{ RuleImpl.meta.name, RuleImpl.meta.default };
    }
    std.mem.sort(NamedSeverity, &entries, {}, struct {
        fn lessThan(_: void, a: NamedSeverity, b: NamedSeverity) bool {
            return std.mem.order(u8, a[0], b[0]) == .lt;
        }
    }.lessThan);
    break :blk entries;
};

/// Write the default configuration to `writer` as JSON.
///
/// Every rule is listed at its default severity — including rules that are
/// off by default — so the output doubles as a list of all available rules.
/// The result is a valid `zlint.json` that preserves default behavior.
pub fn writeDefaultConfigJson(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("{\n  \"rules\": {\n");
    for (default_rule_severities, 0..) |entry, i| {
        try writer.print("    \"{s}\": \"{s}\"", .{ entry[0], entry[1].asSlice() });
        if (i + 1 < default_rule_severities.len) try writer.writeByte(',');
        try writer.writeByte('\n');
    }
    try writer.writeAll("  }\n}\n");
}

pub fn jsonSchema(ctx: *Schema.Context) !Schema {
    var schema = try ctx.genSchemaInner(Config);
    var ignore = schema.object.properties.getPtr("ignore").?;

    var default = try ctx.jsonArray(2);
    try default.appendSlice(&[_]json.Value{
        .{ .string = "vendor" },
        .{ .string = "zig-out" },
    });
    var c = ignore.common();
    c.default = .{ .array = default };
    c.description = "Files and folders to skip. Uses `startsWith` to check if files are ignored.\n\n`zig-out` and `vendor` are always ignored, as well as hidden folders.";

    return schema;
}

const all_rules = @import("rules.zig");
const all_rule_decls = @typeInfo(all_rules).@"struct".decls;

const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const Schema = @import("../json.zig").Schema;
const Severity = @import("../Error.zig").Severity;

pub const RulesConfig = @import("config/rules_config.zig").RulesConfig;

// =============================================================================

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(RulesConfig);
}

const t = std.testing;
const print = std.debug.print;
const json = std.json;

fn testConfig(source: []const u8, expected: RulesConfig) !void {
    var scanner = json.Scanner.initCompleteInput(t.allocator, source);
    defer scanner.deinit();
    var diagnostics = json.Diagnostics{};

    scanner.enableDiagnostics(&diagnostics);
    const actual = json.parseFromTokenSource(RulesConfig, t.allocator, &scanner, .{}) catch |err| {
        print("[{d}:{d}] {s}\n", .{
            diagnostics.getLine(),
            diagnostics.getColumn(),
            source[diagnostics.line_start_cursor..diagnostics.cursor_pointer.*],
        });
        return err;
    };
    defer actual.deinit();
    const info = @typeInfo(RulesConfig.Rules);
    inline for (info.@"struct".fields) |field| {
        const expected_rule_config = @field(expected.rules, field.name);
        const actual_rule_config = @field(actual.value.rules, field.name);
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
    try testConfig("{}", RulesConfig{ .rules = .{} });
    try testConfig(
        \\{ "unsafe-undefined": "error" }
    ,
        RulesConfig{ .rules = .{ .unsafe_undefined = .{ .severity = Severity.err } } },
    );
    try testConfig(
        \\{
        \\  "unsafe-undefined": "allow",
        \\  "homeless-try": "error"
        \\}
    ,
        RulesConfig{
            .rules = .{
                .unsafe_undefined = .{ .severity = Severity.off },
                .homeless_try = .{ .severity = Severity.err },
            },
        },
    );
    try testConfig(
        \\{ "unsafe-undefined": ["error"] }
    ,
        RulesConfig{ .rules = .{ .unsafe_undefined = .{ .severity = Severity.err } } },
    );
    try testConfig(
        \\{ "unsafe-undefined": ["error", {}] }
    ,
        RulesConfig{ .rules = .{ .unsafe_undefined = .{ .severity = Severity.err } } },
    );
    try testConfig(
        \\{ "unsafe-undefined": ["error", { "allow_arrays": true }] }
    ,
        RulesConfig{ .rules = .{ .unsafe_undefined = .{ .severity = Severity.err } } },
    );
    var cfg = all_rules.UnsafeUndefined{ .allow_arrays = false };
    try testConfig(
        \\{ "unsafe-undefined": ["error", { "allow_arrays": false }] }
    ,
        RulesConfig{ .rules = .{ .unsafe_undefined = .{ .severity = Severity.err, .rule_impl = @ptrCast(&cfg) } } },
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

test writeDefaultConfigJson {
    var out = std.Io.Writer.Allocating.init(t.allocator);
    defer out.deinit();
    try writeDefaultConfigJson(&out.writer);
    const source = out.written();

    // Every rule is listed exactly once.
    try t.expectEqual(all_rule_decls.len, std.mem.count(u8, source, "\n    \""));

    // The output parses back into a config equivalent to the default one.
    const parsed = try json.parseFromSlice(Config, t.allocator, source, .{});
    defer parsed.deinit();
    const fields = @typeInfo(RulesConfig.Rules).@"struct".fields;
    try t.expectEqual(fields.len, all_rule_decls.len);
    inline for (fields) |field| {
        t.expectEqual(
            @field(DEFAULT_RULES_CONFIG.rules, field.name).severity,
            @field(parsed.value.rules.rules, field.name).severity,
        ) catch |err| {
            print("Mismatched severity for rule '{s}'\n", .{field.name});
            return err;
        };
    }
}
