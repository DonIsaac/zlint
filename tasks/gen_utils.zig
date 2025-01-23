const std = @import("std");
const zlint = @import("zlint");
const fs = std.fs;
const log = std.log;
const mem = std.mem;
const path = fs.path;
const panic = std.debug.panic;

const Allocator = mem.Allocator;
const Rule = zlint.lint.Rule;

pub const RULES_DIR = "src/linter/rules";
/// ZLint assumes files are less than 2^32 (~4GB) in size.
pub const MAX = std.math.maxInt(u32);

pub const RuleInfo = struct {
    meta: Rule.Meta,
    path: []const u8,
    /// `SomeRule`. Name used by rule struct.
    name_pascale: []const u8,
    // /// `some_rule`. Used for file paths, and container properties in other data
    // /// types.
    // name_snake: []const u8,
    pub const all_rules = blk: {
        const rule_decls: []const std.builtin.Type.Declaration = @typeInfo(zlint.lint.rules).Struct.decls;
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
                // .name_snake = snake_case_name[0..snake_case_name.len],
                .name_pascale = rule_decl.name,
            };
            i += 1;
        }
        break :blk rule_infos;
    };
};
