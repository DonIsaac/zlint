const std = @import("std");
const zlint = @import("zlint");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Schema = zlint.json.Schema;
const Rule = zlint.lint.Rule;
const Config = zlint.lint.Config;
const RulesConfig = Config.RulesConfig;
const assert = std.debug.assert;

pub const RULES_DIR = "src/linter/rules";
/// ZLint assumes files are less than 2^32 (~4GB) in size.
pub const MAX = std.math.maxInt(u32);

pub const RuleInfo = struct {
    meta: Rule.Meta,
    /// Path to rule source code file
    path: []const u8,
    /// `SomeRule`. Name used by rule struct.
    name_pascale: []const u8,
    pub const all_rules = blk: {
        const rule_decls: []const std.builtin.Type.Declaration = @typeInfo(zlint.lint.rules).@"struct".decls;
        var rule_infos: [rule_decls.len]RuleInfo = undefined;
        var i = 0;
        for (rule_decls) |rule_decl| {
            const rule = @field(zlint.lint.rules, rule_decl.name);
            const rule_meta: Rule.Meta = rule.meta;
            var snake_case_name: [rule_meta.name.len]u8 = undefined;
            @memcpy(&snake_case_name, rule_meta.name);
            mem.replaceScalar(u8, &snake_case_name, '-', '_');
            rule_infos[i] = RuleInfo{
                .meta = rule_meta,
                .path = RULES_DIR ++ "/" ++ snake_case_name ++ ".zig",
                .name_pascale = rule_decl.name,
            };
            i += 1;
        }
        break :blk rule_infos;
    };

    pub fn snakeName(self: *const RuleInfo, alloc: Allocator) ![]const u8 {
        const snake = try alloc.dupe(u8, self.meta.name);
        mem.replaceScalar(u8, snake, '-', '_');
        return snake;
    }
};

pub const SchemaMap = std.StringHashMap(Schema);
/// Map is key'd by `rule-name`.
///
/// This leaks memory, and a lot of it.
pub fn ruleSchemaMap(allocator: Allocator) !struct { *Schema.Context, *SchemaMap } {
    const info = @typeInfo(RulesConfig).@"struct";

    var map = try allocator.create(SchemaMap);
    map.* = SchemaMap.init(allocator);
    try map.ensureTotalCapacity(info.fields.len);

    // create and pre-warm arena. Must be on the heap so returned context
    // does not contain a stack pointer.
    // _ = try arena.allocator().alloc(u8, 4096);
    // assert(arena.reset(.retain_capacity));

    var ctx = try allocator.create(Schema.Context);
    ctx.* = Schema.Context.init(allocator);
    inline for (info.fields) |rule_config| {
        const RuleConfig = @FieldType(RulesConfig, rule_config.name);
        const rule_schema = try ctx.addSchema(RuleConfig);
        std.debug.print("{s}: {any}\n", .{ RuleConfig.name, rule_schema });
        try map.put(RuleConfig.name, rule_schema.*);
    }

    return .{ ctx, map };
}
