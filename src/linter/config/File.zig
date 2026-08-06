const File = @This();

extends: Extends = .default,
rules: ?RulesConfig.Optional = null,
ignore: ?glob.GlobSet = null,

pub const Extends = enum {
    empty,
    default,

    const prefix = "zlint:";
    pub fn jsonSchema(ctx: *Schema.Context) !Schema {
        var schema = try ctx.@"enum"(&[_][]const u8{
            prefix ++ "empty",
            prefix ++ "default",
        });
        schema.common().default = .{ .string = prefix ++ "default" };
        return schema;
    }

    pub fn jsonParse(
        allocator: Allocator,
        source: *json.Scanner,
        options: json.ParseOptions,
    ) ParseError!Extends {
        _ = allocator;
        _ = options;
        const str = switch (try source.next()) {
            .string => |tok| tok,
            else => return ParseError.UnexpectedToken,
        };
        if (str.len <= prefix.len) return ParseError.InvalidEnumTag;

        const without_namespace = str[prefix.len..];
        return if (std.mem.eql(u8, without_namespace, "empty"))
            .empty
        else if (std.mem.eql(u8, without_namespace, "default"))
            .default
        else
            ParseError.InvalidEnumTag;
    }
};

const OptionalRules = struct {
    repr: RulesConfig.Optional = .{},

    /// This is a parse-time wrapper, not a schema-level type. On-disk it is
    /// just a `RulesConfig`, so point at that definition.
    pub fn jsonSchema(ctx: *Schema.Context) !Schema {
        return ctx.ref(RulesConfig);
    }

    /// See: `std.json.parseFromTokenSource()`
    pub fn jsonParse(
        allocator: Allocator,
        source: *json.Scanner,
        options: json.ParseOptions,
    ) !OptionalRules {
        var rules = RulesConfig.Optional{};

        // eat '{'
        if (try source.next() != .object_begin) return ParseError.UnexpectedToken;

        while (try source.peekNextTokenType() != .object_end) {
            const key_tok = try source.next();
            const key = switch (key_tok) {
                .string => key_tok.string,
                else => return ParseError.UnexpectedToken,
            };

            var found = false;
            inline for (std.meta.fields(RulesConfig.Optional)) |field| {
                const RuleConfigImpl = @typeInfo(@TypeOf(@field(rules, field.name))).optional.child;
                if (std.mem.eql(u8, key, RuleConfigImpl.name)) {
                    @field(rules, field.name) = try RuleConfigImpl.jsonParse(allocator, source, options);
                    found = true;
                    break;
                }
            }
            // Deliberately ignores `options.ignore_unknown_fields`. Unknown keys
            // elsewhere in the document are tolerated for forward compatibility,
            // but a misspelled rule name silently does nothing, which is the
            // worst way for a linter config to fail.
            if (!found) return ParseError.UnknownField;
        }

        // eat '}'
        const end = try source.next();
        if (end != .object_end) return ParseError.UnexpectedToken;

        return .{ .repr = rules };
    }
};

pub fn resolve(self: *File) Config {
    var config: Config = switch (self.extends) {
        .default => .default,
        .empty => .empty,
    };
    if (self.rules) |rules| {
        inline for (std.meta.fields(Rules.Optional)) |field| {
            if (@field(rules.repr, field.name)) |rule| {
                @field(config.rules.rules, field.name) = rule;
            }
        }
    }
    if (self.ignore) |ignore| config.ignore = ignore;

    return config;
}

pub fn jsonSchema(ctx: *Schema.Context) !Schema {
    var schema = try ctx.genSchemaInner(File);

    // `rules` is `?OptionalRules = null`. The generic codegen renders that null default
    // as a JSON `null`, which is meaningless as a schema default.
    schema.object.properties.getPtr("rules").?.common().default = null;

    var ignore = schema.object.properties.getPtr("ignore").?;
    var default_ignore = try ctx.jsonArray(Config.default.ignore.patterns.len);
    for (Config.default.ignore.patterns) |pattern| {
        try default_ignore.append(.{ .string = pattern });
    }
    const common = ignore.common();
    common.default = .{ .array = default_ignore };
    common.description = "Files and folders to skip, matched using glob patterns.\n\n`zig-out`, `vendor`, and `zig-pkg` are always ignored, as well as hidden folders.";

    return schema;
}

const std = @import("std");
const json = std.json;
const glob = @import("../../walk/glob.zig");

const Config = @import("../Config.zig");
const Allocator = std.mem.Allocator;
const Schema = @import("../../json.zig").Schema;
const RulesConfig = @import("RulesConfig.zig");
const Rules = @import("Rules.zig");
const ParseError = json.ParseError(json.Scanner);

test "json parsing" {
    const allocator = std.testing.allocator;
    const expectEqualDeep = std.testing.expectEqualDeep;
    const config_source =
        \\{
        \\  "extends": "zlint:empty",
        \\  "ignore": [],
        \\  "rules": {}
        \\}
    ;

    const parsed = try json.parseFromSlice(File, allocator, config_source, .{});
    defer parsed.deinit();

    try expectEqualDeep(
        File{ .extends = .empty, .ignore = .empty, .rules = .{ .repr = .{} } },
        parsed.value,
    );
}
