//! Generates a JSON schema for `zlint.json` from all registered rules.
//!
//! Note that rules config is a subset of zlint's full config.
const std = @import("std");
const gen = @import("gen_utils.zig");
const zlint = @import("zlint");
const c = @import("constants.zig");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Schema = zlint.json.Schema;
const Config = zlint.lint.Config;

const Io = std.Io;
const panic = std.debug.panic;

var buf: [1024]u8 = undefined;

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();
    try createJsonSchema(allocator, init.io);
}

fn createJsonSchema(allocator: Allocator, task_io: Io) !void {
    var arena = ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = Schema.Context.init(allocator);
    const root = try ctx.genSchema(Config);
    const rules_config: *Schema.Object = &ctx.getSchema(Config.RulesConfig).?.object;

    var source_arena = ArenaAllocator.init(allocator);
    defer arena.deinit();

    const root_dir = Io.Dir.cwd();
    for (gen.RuleInfo.builtin_rules) |rule| {
        const alloc = source_arena.allocator();
        defer {
            _ = arena.reset(.retain_capacity);
        }

        std.log.info("Rule: {s}", .{rule.path});
        const source = try gen.readSourceFile(alloc, task_io, root_dir, rule.path);
        const rule_docs = try gen.getModuleDocs(source, alloc) orelse panic(
            "Reached EOF on rule '{s}' before finding docs and/or rule impl.",
            .{rule.name(.kebab)},
        );
        const rule_schema = rules_config.properties.getPtr(rule.name(.kebab)).?;
        const copied = try ctx.allocator.dupe(u8, rule_docs);
        var common = rule_schema.common();
        common.description = copied;
        try common.extra_values.put(ctx.allocator, "markdownDescription", .{ .string = copied });
    }

    const schema = try ctx.toJson(root);
    var out = try Io.Dir.cwd().createFile(task_io, c.@"zlint.schema.json", .{});
    defer out.close(task_io);
    var writer = out.writer(task_io, &buf);
    defer writer.interface.flush() catch @panic("failed to flush writer");
    var json = std.json.Stringify{ .writer = &writer.interface, .options = .{ .whitespace = .indent_4 } };
    try json.write(schema);
}
