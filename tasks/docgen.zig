//! Generates rule documentation markdown files from all registered rules.
//!
//! Rules are read from the rules module (src/linter/rules.zig) and saved to
//! `docs/rules`.

const std = @import("std");
const zlint = @import("zlint");
const fs = std.fs;
const log = std.log;
const math = std.math;
const mem = std.mem;
const meta = std.meta;
const path = fs.path;
const panic = std.debug.panic;
const assert = std.debug.assert;

const Allocator = mem.Allocator;
const Ast = std.zig.Ast;
const Node = Ast.Node;

const Rule = zlint.lint.Rule;

const RULES_DIR = "src/linter/rules";
const OUT_DIR = "docs/rules";
/// Zig assumes files are less than 2^32 (~4GB) in size.
const MAX = std.math.maxInt(u32);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    var stack_fallback = std.heap.stackFallback(512, alloc);
    const stackalloc = stack_fallback.get();
    const root = fs.cwd();

    // rules are found using relative paths from the root directory. This check
    // makes sure relative path joining works as expected.
    _ = root.statFile("build.zig") catch |err| {
        log.err("build.zig not found. Make sure you run docgen from the repo root.", .{});
        return err;
    };

    const rules = comptime blk: {
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
            };
            i += 1;
        }
        break :blk rule_infos;
    };

    try root.makePath(OUT_DIR);

    for (rules) |rule| {
        log.info("Rule: {s}", .{rule.meta.name});
        const source: [:0]u8 = try root.readFileAllocOptions(alloc, rule.path, MAX, null, @alignOf(u8), 0);
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
        try generateDocFile(stackalloc, rule, rule_docs);
    }

    log.info("Done.", .{});
}

fn generateDocFile(alloc: Allocator, rule: RuleInfo, docs: []const u8) !void {
    const outfile: fs.File = b: {
        const name = try mem.concat(alloc, u8, &[_][]const u8{ rule.meta.name, ".md" });
        defer alloc.free(name);
        const outpath = try path.join(alloc, &[_][]const u8{ OUT_DIR, name });
        defer alloc.free(outpath);
        log.info("outpath: {s}", .{outpath});
        break :b try fs.cwd().createFile(outpath, .{});
    };
    log.info("Writing docs for rule '{s}'\n", .{rule.meta.name});
    try renderDocs(outfile.writer(), rule, docs);
}

fn renderDocs(writer: fs.File.Writer, rule: RuleInfo, docs: []const u8) !void {
    try writer.print("# `{s}`\n\n", .{rule.meta.name});
    try writer.print(
        \\Category: {s}
        \\Enabled by default?: {s}
    ,
        .{
            @tagName(rule.meta.category),
            if (rule.meta.default) "Yes" else "No",
        },
    );
    try writer.writeByteNTimes('\n', 2);

    var lines = mem.splitScalar(u8, docs, '\n');
    const DOC_COMMENT_PREFIX = "//! ";
    while (lines.next()) |line| {
        // happens when there's a newline in the docs. The line will be `//!`
        // (note no trailing whitespace). Like I said, these are just newlines,
        // so that's what we'll write.
        const clean = if (line.len < DOC_COMMENT_PREFIX.len) "" else line[DOC_COMMENT_PREFIX.len..];
        try writer.print("{s}\n", .{clean});
    }
}

const RuleInfo = struct {
    meta: Rule.Meta,
    path: []const u8,
};
