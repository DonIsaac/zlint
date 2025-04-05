//! Generates rule documentation markdown files from all registered rules.
//!
//! Rules are read from the rules module (src/linter/rules.zig) and saved to
//! `docs/rules`.

const std = @import("std");
const gen = @import("./gen_utils.zig");
const zlint = @import("zlint");
const fs = std.fs;
const log = std.log;
const mem = std.mem;
const path = fs.path;

const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Writer = fs.File.Writer;
const Config = zlint.lint.Config;
const Schema = zlint.json.Schema;

const panic = std.debug.panic;
const assert = std.debug.assert;

const OUT_DIR = "docs/rules";

const Context = struct {
    alloc: Allocator,
    ctx: *Schema.Context,
    schemas: *gen.SchemaMap,
    writer: Writer,
    depth: u32 = 0,
};

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
        const source: [:0]u8 = try root.readFileAllocOptions(alloc, rule.path, gen.MAX, null, @alignOf(u8), 0);
        defer alloc.free(source);

        const rule_docs = docs: {
            var tokens = std.zig.Tokenizer.init(source);
            const start: usize = 0;
            var end: usize = 0;
            while (true) {
                const tok = tokens.next();
                switch (tok.tag) {
                    .eof => panic(
                        "Reached EOF on rule '{s}' before finding docs and/or rule impl.",
                        .{rule.meta.name},
                    ),
                    .container_doc_comment, .doc_comment => end = tok.loc.end,
                    else => break :docs source[start..end],
                }
            }
        };
        if (rule_docs.len == 0) panic("No docs found for rule '{s}'.", .{rule.meta.name});
        try generateDocFile(&ctx, rule, rule_docs);
    }

    log.info("Done.", .{});
}

fn generateDocFile(ctx: *Context, rule: gen.RuleInfo, docs: []const u8) !void {
    const outfile: fs.File = b: {
        const name = try mem.concat(ctx.alloc, u8, &[_][]const u8{ rule.meta.name, ".md" });
        defer ctx.alloc.free(name);
        const outpath = try path.join(ctx.alloc, &[_][]const u8{ OUT_DIR, name });
        defer ctx.alloc.free(outpath);
        log.info("outpath: {s}", .{outpath});
        break :b try fs.cwd().createFile(outpath, .{});
    };
    defer outfile.close();
    log.info("Writing docs for rule '{s}'\n", .{rule.meta.name});
    ctx.writer = outfile.writer();
    // safety: no longer valid once file closes
    defer ctx.writer = undefined;
    try renderDocs(ctx, rule, docs);
}

fn renderDocs(ctx: *Context, rule: gen.RuleInfo, docs: []const u8) !void {
    try ctx.writer.print("# `{s}`\n\n", .{rule.meta.name});
    const enabled_message = switch (rule.meta.default) {
        .off => "No",
        .err => "Yes (error)",
        .warning => "Yes (warning)",
        .notice => "Yes (notice)",
    };
    try ctx.writer.print(
        \\> Category: {s}
        \\> 
        \\> Enabled by default?: {s}
        \\
    ,
        .{
            @tagName(rule.meta.category),
            enabled_message,
        },
    );
    try ctx.writer.writeByteNTimes('\n', 2);

    var lines = mem.splitScalar(u8, docs, '\n');
    const DOC_COMMENT_PREFIX = "//! ";
    while (lines.next()) |line| {
        // happens when there's a newline in the docs. The line will be `//!`
        // (note no trailing whitespace). Like I said, these are just newlines,
        // so that's what we'll write.
        const clean = if (line.len < DOC_COMMENT_PREFIX.len) "" else line[DOC_COMMENT_PREFIX.len..];
        try ctx.writer.print("{s}\n", .{clean});
    }
    try renderConfigSection(ctx, rule);
}

fn renderConfigSection(ctx: *Context, rule: gen.RuleInfo) !void {
    var schema: ?Schema = ctx.schemas.get(rule.meta.name).?;
    while (true) {
        const s: Schema = schema orelse break;
        switch (s) {
            .object => break,
            .@"$ref" => |ref| {
                schema = ref.resolve(ctx.ctx).*;
            },
            .compound => |c| {
                schema = c.kind.one_of[1].array.prefixItems.?[1];
            },
            else => {
                schema = null;
            }
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
