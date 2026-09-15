rules: RulesConfig = .default,
ignore: glob.GlobSet = default_ignore,

const Config = @This();

const default_ignore: glob.GlobSet = .new(&[_]glob.Pattern{
    "**/vendor",  "**/vendor/**",
    "**/zig-out", "**/zig-out/**",
    "**/zig-pkg", "**/zig-pkg/**",
});

pub const default: Config = .{
    .rules = .default,
    .ignore = default_ignore,
};
pub const empty: Config = .{ .rules = .empty, .ignore = default.ignore };

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

pub fn jsonSchema(ctx: *Schema.Context) !Schema {
    var schema = try ctx.genSchemaInner(Config);
    var ignore = schema.object.properties.getPtr("ignore").?;

    var schemaDefault = try ctx.jsonArray(default_ignore.patterns.len);
    for (default_ignore.patterns) |pattern| {
        try schemaDefault.append(.{ .string = pattern });
    }
    var c = ignore.common();
    c.default = .{ .array = schemaDefault };
    c.description = "Files and folders to skip, as glob patterns. Patterns are anchored to your project root, so use a `**/` prefix to match at any depth and a `/**` suffix to skip a folder's contents.\n\n`.gitignore` entries are honored as well, and are translated to equivalent globs.\n\n`zig-out`, `vendor`, and `zig-pkg` are always ignored, as well as hidden folders.";

    return schema;
}

const std = @import("std");
const glob = @import("../io/glob.zig");
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const Schema = @import("../json.zig").Schema;

pub const RulesConfig = @import("config/rules_config.zig").RulesConfig;

// =============================================================================

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(RulesConfig);
}

const t = std.testing;
const builtin_rules = @import("builtin_rules.zig");
const print = std.debug.print;
const json = std.json;
const Severity = @import("../Error.zig").Severity;

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
            print("Actual:\n\n\t{any}\n", .{actual.value});
            return err;
        };
    }
}

fn withSeverities(overrides: anytype) RulesConfig {
    const builtin = @import("builtin");
    comptime std.debug.assert(builtin.is_test);

    var config: RulesConfig = .default;
    inline for (@typeInfo(@TypeOf(overrides)).@"struct".fields) |field| {
        @field(config.rules, field.name).severity = @field(overrides, field.name);
    }
    return config;
}

test "RulesConfig.jsonParse" {
    try testConfig("{}", .default);
    try testConfig(
        \\{ "unsafe-undefined": "error" }
    ,
        withSeverities(.{ .unsafe_undefined = Severity.err }),
    );
    try testConfig(
        \\{
        \\  "unsafe-undefined": "allow",
        \\  "homeless-try": "error"
        \\}
    ,
        withSeverities(.{
            .unsafe_undefined = Severity.off,
            .homeless_try = Severity.err,
        }),
    );
    try testConfig(
        \\{ "unsafe-undefined": ["error"] }
    ,
        withSeverities(.{ .unsafe_undefined = Severity.err }),
    );
    try testConfig(
        \\{ "unsafe-undefined": ["error", {}] }
    ,
        withSeverities(.{ .unsafe_undefined = Severity.err }),
    );
    try testConfig(
        \\{ "unsafe-undefined": ["error", { "allow_arrays": true }] }
    ,
        withSeverities(.{ .unsafe_undefined = Severity.err }),
    );
    var cfg = builtin_rules.UnsafeUndefined{ .allow_arrays = false };
    var expect_with_impl = withSeverities(.{ .unsafe_undefined = Severity.err });
    expect_with_impl.rules.unsafe_undefined.rule_impl = @ptrCast(&cfg);
    try testConfig(
        \\{ "unsafe-undefined": ["error", { "allow_arrays": false }] }
    ,
        expect_with_impl,
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

test "Config.jsonParse - omitted fields don't default to empty" {
    inline for ([_][]const u8{
        "{}",
        \\{ "ignore": [] }
        ,
        \\{ "rules": {} }
    }) |src| {
        var actual = try json.parseFromSlice(Config, t.allocator, src, .{});
        defer actual.deinit();
        try t.expectEqualDeep(Config.default.rules, actual.value.rules);
    }

    inline for ([_][]const u8{
        "{}",
        \\{ "rules": {} }
    }) |src| {
        var actual = try json.parseFromSlice(Config, t.allocator, src, .{});
        defer actual.deinit();
        try t.expectEqualDeep(Config.default.ignore.patterns, actual.value.ignore.patterns);
    }
    {
        var actual = try json.parseFromSlice(Config, t.allocator,
            \\{ "ignore": [] }
        , .{});
        defer actual.deinit();
        try t.expectEqual(@as(usize, 0), actual.value.ignore.patterns.len);
    }
}
