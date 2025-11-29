//! Generates rule documentation markdown files from all registered rules.
//!
//! Rules are read from the rules module (src/linter/rules.zig) and saved to
//! the docs folder (`OUT_DIR`).

const std = @import("std");
const io = std.io;
const gen = @import("./gen_utils.zig");
const zlint = @import("zlint");
const RULE_DOCS_DIR = @import("./constants.zig").@"docs/rules";
const fs = std.fs;
const log = std.log;
const mem = std.mem;
const path = fs.path;

const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Writer = fs.File.Writer;
const Schema = zlint.json.Schema;

const panic = std.debug.panic;
const assert = std.debug.assert;

const OUT_DIR = "apps/site/docs/rules";
const OUT_KIND = MdKind.mdx;
const MdKind = enum {
    md,
    mdx,
    fn ext(self: MdKind) []const u8 {
        return switch (self) {
            .md => ".md",
            .mdx => ".mdx",
        };
    }
};

const Context = struct {
    alloc: Allocator,
    ctx: *Schema.Context,
    schemas: *gen.SchemaMap,
    writer: io.Writer,
    depth: u32 = 0,
};

var buf: [1024]u8 = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    const root = fs.cwd();

    var arena = ArenaAllocator.init(alloc);
    const schema_ctx, const schema_map = try gen.ruleSchemaMap(arena.allocator());
    var ctx = Context{
        .alloc = alloc,
        .ctx = schema_ctx,
        .schemas = schema_map,
        // safety: initialized when rendering a rule's docs, not used before.
        .writer = undefined,
    };

    // rules are found using relative paths from the root directory. This check
    // makes sure relative path joining works as expected.
    _ = root.statFile("build.zig") catch |err| {
        log.err("build.zig not found. Make sure you run docgen from the repo root.", .{});
        return err;
    };

    try root.makePath(OUT_DIR);

    for (gen.RuleInfo.all_rules) |rule| {
        log.info("Rule: {s}", .{rule.meta.name});
        const source = try gen.readSourceFile(alloc, root, rule.path);
        defer alloc.free(source);

        const rule_docs = try gen.getModuleDocs(source, alloc) orelse panic(
            "Reached EOF on rule '{s}' before finding docs and/or rule impl.",
            .{rule.meta.name},
        );
        if (rule_docs.len == 0) panic("No docs found for rule '{s}'.", .{rule.meta.name});
        defer alloc.free(rule_docs);
        try generateDocFile(&ctx, rule, rule_docs);
    }

    log.info("Done.", .{});
}

fn generateDocFile(ctx: *Context, rule: gen.RuleInfo, docs: []const u8) !void {
    const outfile: fs.File = b: {
        const name = try mem.concat(ctx.alloc, u8, &[_][]const u8{ rule.meta.name, comptime OUT_KIND.ext() });
        defer ctx.alloc.free(name);
        const outpath = try path.join(ctx.alloc, &[_][]const u8{ OUT_DIR, name });
        defer ctx.alloc.free(outpath);
        log.info("outpath: {s}", .{outpath});
        break :b try fs.cwd().createFile(outpath, .{});
    };
    defer outfile.close();
    log.info("Writing docs for rule '{s}'\n", .{rule.meta.name});
    ctx.writer = outfile.writer(&buf).interface;
    defer ctx.writer.flush() catch @panic("failed to flush writer");
    // safety: no longer valid once file closes
    defer ctx.writer = undefined;
    try renderDocs(ctx, rule, docs);
}

fn renderDocs(ctx: *Context, rule: gen.RuleInfo, docs: []const u8) !void {
    try ctx.writer.writeAll(
        \\---
        \\rule: '
    );
    var json = std.json.Stringify{ .writer = &ctx.writer };
    try json.write(rule.meta);
    try ctx.writer.writeAll("'\n---\n\n");
    try ctx.writer.print("# `{s}`\n\n", .{rule.name(.kebab)});
    try ctx.writer.print(
        \\<RuleBanner category="{s}" default="{s}" 
    , .{
        @tagName(rule.meta.category),
        @tagName(rule.meta.default),
    });
    if (rule.meta.fix.kind != .none) {
        try ctx.writer.writeAll("fix={");
        defer ctx.writer.writeByte('}') catch unreachable;
        try json.write(rule.meta.fix);
    }
    try ctx.writer.writeAll(" />");
    try ctx.writer.writeAll("\n\n");
    try ctx.writer.writeAll(docs);
    try ctx.writer.writeAll("\n\n");
    try renderConfigSection(ctx, rule);
}

fn renderConfigSection(ctx: *Context, rule: gen.RuleInfo) !void {
    // SAFETY: allocator only used
    var schema: ?Schema = ctx.schemas.get(rule.name(.kebab)) orelse {
        panic("Could not find schema for rule '{s}'", .{rule.meta.name});
    };
    while (true) {
        const s: Schema = schema orelse break;
        switch (s) {
            .object => break,
            .@"$ref" => |ref| {
                schema = ref.resolve(ctx.ctx).?.*;
            },
            .compound => |c| {
                schema = c.kind.one_of[1].array.prefixItems.?[1];
            },
            else => {
                schema = null;
            },
        }
    }

    try ctx.writer.writeAll("## Configuration\n");
    const schema_ = schema orelse {
        return ctx.writer.writeAll("This rule has no configuration.\n");
    };
    const obj = schema_.object;

    if (obj.properties.count() == 0) {
        return ctx.writer.writeAll("This rule has no configuration.\n");
    } else {
        try ctx.writer.writeAll("This rule accepts the following options:\n");
    }

    assert(ctx.depth == 0);
    var it = obj.properties.iterator();
    while (it.next()) |prop| {
        ctx.depth += 1;
        defer ctx.depth -= 1;
        const key = prop.key_ptr.*;
        const required = obj.isRequired(key);
        try renderObjectProperty(ctx, key, prop.value_ptr, required);
    }
}

fn renderObjectProperty(ctx: *Context, name: []const u8, value: *const Schema, required: bool) !void {
    // TODO: render value and other stuff
    try ctx.writer.print("- {s}: {s}\n", .{ name, @tagName(std.meta.activeTag(value.*)) });
    _ = required;
    // @panic("todo");
}
