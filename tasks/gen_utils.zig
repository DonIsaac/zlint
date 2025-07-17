const std = @import("std");
const zlint = @import("zlint");
const mem = std.mem;
const Allocator = mem.Allocator;
const c = @import("constants.zig");

const Schema = zlint.json.Schema;
const Rule = zlint.lint.Rule;
const Config = zlint.lint.Config;
const RulesConfig = Config.RulesConfig;

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
                .path = c.@"linter/rules" ++ "/" ++ snake_case_name ++ ".zig",
                .name_pascale = rule_decl.name,
            };
            i += 1;
        }
        break :blk rule_infos;
    };

    const Case = enum {
        /// PascaleCase
        pascale,
        /// lower-kebab-case
        kebab,
    };
    pub fn name(self: *const RuleInfo, comptime case: Case) []const u8 {
        return switch (case) {
            .kebab => self.meta.name,
            .pascale => self.name_pascale,
        };
    }

    pub fn snakeName(self: *const RuleInfo, alloc: Allocator) ![]const u8 {
        const snake = try alloc.dupe(u8, self.meta.name);
        mem.replaceScalar(u8, snake, '-', '_');
        return snake;
    }
};

/// Fully read the contents of a zig source file into an allocated buffer.
/// Caller owns the returned allocation.
pub fn readSourceFile(alloc: Allocator, root: std.fs.Dir, path: []const u8) ![:0]u8 {
    return root.readFileAllocOptions(alloc, path, MAX, null, @alignOf(u8), 0);
}

pub const SchemaMap = std.StringHashMap(Schema);

/// Map is key'd by `rule-name`.
///
/// This leaks memory, and a lot of it.
pub fn ruleSchemaMap(allocator: Allocator) !struct { *Schema.Context, *SchemaMap } {
    const info = @typeInfo(RulesConfig).@"struct";

    var map = try allocator.create(SchemaMap);
    map.* = SchemaMap.init(allocator);
    try map.ensureTotalCapacity(info.fields.len);

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

const DOC_COMMENT_PREFIX = "//! ";

pub fn getModuleDocs(
    source: [:0]const u8,
    allocator: Allocator,
) !?[]const u8 {
    var tokens = std.zig.Tokenizer.init(source);
    const start: usize = 0;
    var end: usize = 0;
    while (true) {
        const tok = tokens.next();
        switch (tok.tag) {
            .eof => return null,
            .container_doc_comment, .doc_comment => end = tok.loc.end,
            else => break,
        }
    }
    const docs = source[start..end];
    var buf = try std.ArrayList(u8).initCapacity(allocator, docs.len);
    var lines = mem.splitScalar(u8, docs, '\n');

    while (lines.next()) |line| {
        // happens when there's a newline in the docs. The line will be `//!`
        // (note no trailing whitespace). Like I said, these are just newlines,
        // so that's what we'll write.
        const clean = if (line.len < DOC_COMMENT_PREFIX.len) "" else line[DOC_COMMENT_PREFIX.len..];
        try buf.appendSlice(clean);
        try buf.append('\n');
    }

    // trim trailing whitespace
    while (buf.items.len > 0 and std.ascii.isWhitespace(buf.items[buf.items.len - 1])) {
        buf.items.len -= 1;
    }

    return try buf.toOwnedSlice();
}
