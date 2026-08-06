rules: RulesConfig = .default,
ignore: glob.GlobSet = .empty,

const Config = @This();

pub const default: Config = .{
    .rules = .default,
    .ignore = .new(&[_]glob.Pattern{ "vendor/**", "zig-out/**", "zig-pkg/**" }),
};
pub const empty: Config = .{
    .rules = .empty,
    .ignore = default.ignore,
};

pub const Managed = struct {
    /// should only be set if created from an on-disk config
    path: ?[]const u8 = null,
    config: Config,
    arena: *ArenaAllocator,
    pub inline fn allocator(self: *Managed) Allocator {
        return self.arena.allocator();
    }
};
pub const File = @import("config/File.zig");

pub fn intoManaged(self: Config, arena: *ArenaAllocator, path: ?[]const u8) Managed {
    return Managed{ .config = self, .arena = arena, .path = path };
}

const std = @import("std");
const glob = @import("../walk/glob.zig");
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const Rules = @import("config/Rules.zig");

pub const RulesConfig = @import("config/RulesConfig.zig");

// =============================================================================

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(RulesConfig);
}

const t = std.testing;
const print = std.debug.print;
const json = std.json;
const Severity = @import("../Error.zig").Severity;

/// Parse `rules` as the `rules` object of a `zlint.json`, checking that each
/// rule's severity matches `expected`. Rules omitted from the document stay
/// `null`; `File.resolve` is what fills them in from the base config.
fn testConfig(rules: []const u8, expected: RulesConfig.Optional) !void {
    const source = try std.fmt.allocPrint(t.allocator, "{{ \"rules\": {s} }}", .{rules});
    defer t.allocator.free(source);

    var scanner = json.Scanner.initCompleteInput(t.allocator, source);
    defer scanner.deinit();
    var diagnostics = json.Diagnostics{};

    scanner.enableDiagnostics(&diagnostics);
    const actual = json.parseFromTokenSource(File, t.allocator, &scanner, .{}) catch |err| {
        print("[{d}:{d}] {s}\n", .{
            diagnostics.getLine(),
            diagnostics.getColumn(),
            source[diagnostics.line_start_cursor..diagnostics.cursor_pointer.*],
        });
        return err;
    };
    defer actual.deinit();

    const actual_rules = actual.value.rules.?.repr;
    inline for (@typeInfo(Rules.Optional).@"struct".fields) |field| {
        // TODO: Test that configs are the same, once rule configuration is implemented.
        const expected_severity = if (@field(expected.repr, field.name)) |rule| rule.severity else null;
        const actual_severity = if (@field(actual_rules, field.name)) |rule| rule.severity else null;
        t.expectEqual(expected_severity, actual_severity) catch |err| {
            print("Mismatched severity for rule '{s}'.\n", .{field.name});
            return err;
        };
    }
}

test "parsing a zlint.json `rules` object" {
    try testConfig("{}", .empty);
    try testConfig(
        \\{ "unsafe-undefined": "error" }
    ,
        .{ .repr = .{ .unsafe_undefined = .{ .severity = Severity.err } } },
    );
    try testConfig(
        \\{
        \\  "unsafe-undefined": "allow",
        \\  "homeless-try": "error"
        \\}
    ,
        .{ .repr = .{
            .unsafe_undefined = .{ .severity = Severity.off },
            .homeless_try = .{ .severity = Severity.err },
        } },
    );
    try testConfig(
        \\{ "unsafe-undefined": ["error"] }
    ,
        .{ .repr = .{ .unsafe_undefined = .{ .severity = Severity.err } } },
    );
    try testConfig(
        \\{ "unsafe-undefined": ["error", {}] }
    ,
        .{ .repr = .{ .unsafe_undefined = .{ .severity = Severity.err } } },
    );
    try testConfig(
        \\{ "unsafe-undefined": ["error", { "allow_arrays": true }] }
    ,
        .{ .repr = .{ .unsafe_undefined = .{ .severity = Severity.err } } },
    );
    try testConfig(
        \\{ "unsafe-undefined": ["error", { "allow_arrays": false }] }
    ,
        .{ .repr = .{ .unsafe_undefined = .{ .severity = Severity.err } } },
    );

    {
        var scanner = json.Scanner.initCompleteInput(t.allocator,
            \\{ "rules": { "no-undefined": "allow" } }
        );
        defer scanner.deinit();
        try t.expectError(error.UnknownField, json.parseFromTokenSource(
            File,
            t.allocator,
            &scanner,
            .{},
        ));
    }
}

test "File.resolve fills unspecified rules from the base config" {
    const parsed = try json.parseFromSlice(File, t.allocator,
        \\{ "rules": { "unsafe-undefined": "allow" } }
    , .{});
    defer parsed.deinit();

    var file = parsed.value;
    const resolved = file.resolve();
    try t.expectEqual(Severity.off, resolved.rules.rules.unsafe_undefined.severity);
    try t.expectEqual(
        RulesConfig.default.rules.homeless_try.severity,
        resolved.rules.rules.homeless_try.severity,
    );
}
