//! Renders a `Cfg` as a Graphviz DOT digraph.
//!
//! Each control-flow container becomes a cluster; blocks list their
//! instructions as (truncated) source snippets, prefixed with line numbers.
//! Fill color tells you a block's role, border color tells you its state, and
//! edge color tells you how control got there. Pipe the output into `dot -Tsvg`
//! to visualize it.

const max_snippet_len = 40;

/// Block fills, by role.
const fill = struct {
    const entry = "#e8f5e9";
    const exit = "#fdecea";
    const loop = "#e3f2fd";
    const cleanup = "#fff8e1";
    const @"comptime" = "#f3e5f5";
    const @"unreachable" = "#f5f5f5";
    const plain = "white";
};

/// Borders and edges, by state / edge kind.
const ink = struct {
    const @"error" = "#c62828";
    const dead = "#9e9e9e";
    const branch = "#1565c0";
    const back = "#6a1b9a";
    const jump = "#00838f";
    const @"return" = "#2e7d32";
    const cleanup = "#ef6c00";
};

pub const RenderOptions = struct {
    /// Include top-level decl initializer containers. Off by default: most
    /// are trivial `entry -> body -> exit` chains that drown out the
    /// interesting graphs.
    decls: bool = false,
    /// Draw the color key.
    legend: bool = true,
    /// Shown above the graph, alongside block and container counts.
    title: ?[]const u8 = null,
};

pub const Error = Allocator.Error || Writer.Error;

pub fn render(
    alloc: Allocator,
    semantic: *const Semantic,
    writer: *Writer,
    opts: RenderOptions,
) Error!void {
    const cfg = &semantic.cfg;
    const container_flags: []const Container.Flags = cfg.containers.items(.flags);

    var lines: LineIndex = try .init(alloc, semantic.source());
    defer lines.deinit(alloc);
    const ctx: Ctx = .{ .semantic = semantic, .lines = &lines };

    try writer.writeAll("digraph cfg {\n");
    try writer.writeAll("  graph [fontname=\"sans-serif\", fontsize=11, labelloc=\"t\"];\n");
    try writer.writeAll("  node [shape=box, style=filled, fillcolor=\"white\", fontname=\"monospace\", fontsize=10];\n");
    try writer.writeAll("  edge [fontname=\"sans-serif\", fontsize=9];\n");
    try writer.writeAll("  label=\"");
    if (opts.title) |title| {
        try writeFull(writer, title);
        try writer.writeAll("  ");
    }
    try writer.print("{d} blocks in {d} containers\";\n", .{ cfg.len(), cfg.containers.len });

    const block_containers: []const Container.Id = cfg.blocks.items(.container);
    var grouped: BlocksByContainer = try .init(alloc, block_containers, cfg.containers.len);
    defer grouped.deinit(alloc);

    for (0..cfg.containers.len) |i| {
        if (!opts.decls and container_flags[i].c_decl) continue;
        const blocks = grouped.blocksIn(i);
        try writer.print("  subgraph cluster_{d} {{\n", .{i});
        try writer.print("    style=rounded; color=\"{s}\";\n", .{clusterColor(container_flags[i])});
        try writer.writeAll("    label=\"");
        try writeContainerLabel(ctx, cfg.getContainer(.from(i)), @intCast(blocks.len), writer);
        try writer.writeAll("\";\n");
        for (blocks) |b| {
            try renderBlock(ctx, b, writer);
        }
        try writer.writeAll("  }\n");
    }

    for (0..cfg.len()) |b| {
        const container = block_containers[b];
        if (!opts.decls and container_flags[container.int()].c_decl) continue;
        const from: BasicBlock.Id = .from(b);
        for (cfg.successorsOf(from)) |edge| {
            try renderEdge(from, edge, writer);
        }
    }

    if (opts.legend) try renderLegend(writer);
    try writer.writeAll("}\n");
}

/// Everything the label writers need to turn a node into text.
const Ctx = struct {
    semantic: *const Semantic,
    lines: *const LineIndex,
};

/// Maps a byte offset to a 1-based line number without rescanning the file.
const LineIndex = struct {
    /// Byte offset of the start of each line. Always begins with 0.
    starts: std.ArrayList(u32),

    fn init(alloc: Allocator, source: []const u8) Allocator.Error!LineIndex {
        var starts: std.ArrayList(u32) = .empty;
        errdefer starts.deinit(alloc);
        try starts.append(alloc, 0);
        for (source, 0..) |ch, i| {
            if (ch == '\n') try starts.append(alloc, @intCast(i + 1));
        }
        return .{ .starts = starts };
    }

    fn deinit(self: *LineIndex, alloc: Allocator) void {
        self.starts.deinit(alloc);
    }

    fn lineOf(self: *const LineIndex, offset: u32) u32 {
        const S = struct {
            fn order(key: u32, start: u32) std.math.Order {
                return std.math.order(key, start);
            }
        };
        // the number of line starts at or before `offset` is its 1-based line
        return @intCast(std.sort.upperBound(u32, self.starts.items, offset, S.order));
    }
};

/// Blocks bucketed by owning container, counting-sorted so rendering a cluster
/// costs its own blocks instead of a scan over every block in the file.
const BlocksByContainer = struct {
    ids: []BasicBlock.Id,
    offsets: []u32,

    fn init(
        alloc: Allocator,
        block_containers: []const Container.Id,
        container_count: usize,
    ) Allocator.Error!BlocksByContainer {
        const offsets = try alloc.alloc(u32, container_count + 1);
        errdefer alloc.free(offsets);
        const ids = try alloc.alloc(BasicBlock.Id, block_containers.len);
        errdefer alloc.free(ids);

        @memset(offsets, 0);
        for (block_containers) |container| offsets[container.int()] += 1;
        var total: u32 = 0;
        for (offsets) |*offset| {
            const count = offset.*;
            offset.* = total;
            total += count;
        }

        for (block_containers, 0..) |container, b| {
            const i = container.int();
            ids[offsets[i]] = .from(b);
            offsets[i] += 1;
        }
        std.mem.copyBackwards(u32, offsets[1..], offsets[0 .. offsets.len - 1]);
        offsets[0] = 0;

        return .{ .ids = ids, .offsets = offsets };
    }

    fn deinit(self: *BlocksByContainer, alloc: Allocator) void {
        alloc.free(self.ids);
        alloc.free(self.offsets);
    }

    fn blocksIn(self: *const BlocksByContainer, container: usize) []const BasicBlock.Id {
        return self.ids[self.offsets[container]..self.offsets[container + 1]];
    }
};

fn clusterColor(flags: Container.Flags) []const u8 {
    if (flags.c_fn) return ink.branch;
    if (flags.c_test) return ink.@"return";
    if (flags.c_comptime) return ink.back;
    return ink.dead;
}

fn writeContainerLabel(ctx: Ctx, container: Container, blocks: u32, writer: *Writer) Writer.Error!void {
    const symbols = ctx.semantic.symbols.symbols;
    if (container.symbol.unwrap()) |symbol| {
        if (symbols.items(.visibility)[symbol.int()] == .public) try writer.writeAll("pub ");
    }

    const kind: []const u8 = if (container.flags.c_fn)
        "fn"
    else if (container.flags.c_test)
        "test"
    else if (container.flags.c_comptime)
        "comptime"
    else
        "decl";
    try writer.writeAll(kind);

    if (container.symbol.unwrap()) |symbol| {
        const name = symbols.items(.name)[symbol.int()];
        if (name.len > 0) {
            try writer.writeByte(' ');
            try writeSnippet(writer, name);
        }
    }
    try writer.print("  L{d}  {d} blocks", .{ lineOf(ctx, container.node), blocks });
}

fn renderBlock(ctx: Ctx, id: BasicBlock.Id, writer: *Writer) Writer.Error!void {
    const cfg = &ctx.semantic.cfg;
    const block = cfg.getBlock(id);

    try writer.print("    b{d} [label=\"b{d}", .{ id.int(), id.int() });
    inline for (.{
        .{ "b_entry", "entry" },
        .{ "b_exit", "exit" },
        .{ "b_loop_header", "loop" },
        .{ "b_cleanup", "cleanup" },
        .{ "b_error", "error" },
        .{ "b_comptime", "comptime" },
        .{ "b_unreachable", "unreachable" },
    }) |flag| {
        if (@field(block.flags, flag[0])) try writer.writeAll(" " ++ flag[1]);
    }
    if (block.node != .root) try writer.print("  L{d}", .{lineOf(ctx, block.node)});
    const predecessors = cfg.predecessorsOf(id).len;
    if (predecessors > 1) try writer.print("  {d} preds", .{predecessors});
    try writer.writeAll("\\l");

    const instructions = cfg.instructionsOf(id);
    for (0..instructions.len) |i| {
        const instruction = instructions.get(i);
        try writer.print("{d}: {s}  ", .{ lineOf(ctx, instruction.node), @tagName(instruction.kind) });
        try writeSnippet(writer, ctx.semantic.nodeSlice(instruction.node));
        try writer.writeAll("\\l");
    }
    if (block.terminator.kind != .goto) {
        try writer.print("-> {s}", .{@tagName(block.terminator.kind)});
        if (block.terminator.node != .root) {
            try writer.writeAll("  ");
            try writeSnippet(writer, ctx.semantic.nodeSlice(block.terminator.node));
        }
        try writer.writeAll("\\l");
    }
    try writer.writeAll("\"");

    if (block.flags.b_entry or block.flags.b_exit) try writer.writeAll(", shape=oval");
    try writer.print(", fillcolor=\"{s}\"", .{blockFill(block.flags)});
    if (block.flags.b_cleanup) try writer.writeAll(", style=\"filled,dashed\"");
    if (block.flags.b_unreachable) {
        try writer.print(", color=\"{s}\", fontcolor=\"{s}\"", .{ ink.dead, ink.dead });
    } else if (block.flags.b_error) {
        try writer.print(", color=\"{s}\"", .{ink.@"error"});
    }
    try writer.writeAll("];\n");
}

fn blockFill(flags: BasicBlock.Flags) []const u8 {
    if (flags.b_unreachable) return fill.@"unreachable";
    if (flags.b_cleanup) return fill.cleanup;
    if (flags.b_loop_header) return fill.loop;
    if (flags.b_entry) return fill.entry;
    if (flags.b_exit) return fill.exit;
    if (flags.b_comptime) return fill.@"comptime";
    return fill.plain;
}

fn renderEdge(from: BasicBlock.Id, edge: Edge, writer: *Writer) Writer.Error!void {
    try writer.print("  b{d} -> b{d} [", .{ from.int(), edge.dest.int() });
    switch (edge.kind) {
        .normal => {},
        .true_branch => try writer.print("label=\"true\", color=\"{s}\"", .{ink.branch}),
        .false_branch => try writer.print("label=\"false\", color=\"{s}\"", .{ink.branch}),
        .back => try writer.print("label=\"back\", color=\"{s}\"", .{ink.back}),
        .jump => try writer.print("label=\"jump\", color=\"{s}\"", .{ink.jump}),
        .@"return" => try writer.print("label=\"return\", color=\"{s}\"", .{ink.@"return"}),
        .@"error" => try writer.print("label=\"error\", color=\"{s}\"", .{ink.@"error"}),
        .cleanup => try writer.print("label=\"cleanup\", color=\"{s}\", style=dashed", .{ink.cleanup}),
        .@"unreachable", .unreachable_implicit => try writer.print(
            "label=\"unreachable\", style=dotted, color=\"{s}\"",
            .{ink.dead},
        ),
    }
    try writer.writeAll("];\n");
}

/// Color key. Disconnected from the graph, so it cannot perturb layout.
fn renderLegend(writer: *Writer) Writer.Error!void {
    try writer.writeAll("  subgraph cluster_legend {\n");
    try writer.print("    style=rounded; color=\"{s}\"; label=\"legend\"; fontsize=10;\n", .{ink.dead});
    inline for (.{
        .{ "entry", fill.entry },
        .{ "exit", fill.exit },
        .{ "loop header", fill.loop },
        .{ "cleanup", fill.cleanup },
        .{ "comptime", fill.@"comptime" },
        .{ "unreachable", fill.@"unreachable" },
    }) |role| {
        try writer.writeAll("    legend_" ++ comptime underscored(role[0]) ++
            " [label=\"" ++ role[0] ++ "\", fillcolor=\"" ++ role[1] ++ "\"];\n");
    }
    // Sample edges, drawn for real so the colors speak for themselves.
    inline for (.{
        .{ "branch", ink.branch, "" },
        .{ "back", ink.back, "" },
        .{ "jump", ink.jump, "" },
        .{ "return", ink.@"return", "" },
        .{ "error", ink.@"error", "" },
        .{ "cleanup", ink.cleanup, ", style=dashed" },
        .{ "unreachable", ink.dead, ", style=dotted" },
    }) |kind| {
        const tail = "legend_" ++ kind[0] ++ "_from";
        const head = "legend_" ++ kind[0] ++ "_to";
        try writer.writeAll("    " ++ tail ++ " [shape=point, width=0.03, color=\"" ++ kind[1] ++ "\"];\n" ++
            "    " ++ head ++ " [shape=point, width=0.03, color=\"" ++ kind[1] ++ "\"];\n" ++
            "    " ++ tail ++ " -> " ++ head ++ " [label=\"" ++ kind[0] ++ "\", color=\"" ++ kind[1] ++ "\"" ++ kind[2] ++ "];\n");
    }
    try writer.writeAll("  }\n");
}

fn underscored(comptime name: []const u8) []const u8 {
    comptime var out: [name.len]u8 = undefined;
    inline for (name, 0..) |ch, i| out[i] = if (ch == ' ') '_' else ch;
    return &out;
}

fn lineOf(ctx: Ctx, node: NodeIndex) u32 {
    return ctx.lines.lineOf(ctx.semantic.nodeSpan(node).start);
}

/// Write `text` escaped for a DOT label, whitespace collapsed and truncated to
/// `max_snippet_len` characters.
fn writeSnippet(writer: *Writer, text: []const u8) Writer.Error!void {
    return writeText(writer, text, max_snippet_len);
}

/// Like `writeSnippet`, but keeps the whole string.
fn writeFull(writer: *Writer, text: []const u8) Writer.Error!void {
    return writeText(writer, text, null);
}

/// Length of the UTF-8 sequence starting at `text[i]`, or 1 if it isn't one.
fn seqLenAt(text: []const u8, i: usize) usize {
    const n = std.unicode.utf8ByteSequenceLength(text[i]) catch return 1;
    if (i + n > text.len) return 1;
    _ = std.unicode.utf8Decode(text[i..][0..n]) catch return 1;
    return n;
}

/// Advances a codepoint at a time, so `limit` can never cut a multi-byte
/// sequence in half and leave invalid UTF-8 in the label.
fn writeText(writer: *Writer, text: []const u8, limit: ?usize) Writer.Error!void {
    var count: usize = 0;
    var last_was_space = true;
    var i: usize = 0;
    while (i < text.len) {
        if (limit != null and count >= limit.?) return writer.writeAll("...");

        const ch = text[i];
        if (std.ascii.isWhitespace(ch)) {
            i += 1;
            if (!last_was_space) {
                try writer.writeByte(' ');
                count += 1;
                last_was_space = true;
            }
            continue;
        }
        last_was_space = false;

        const seq_len = seqLenAt(text, i);
        if (seq_len > 1) {
            try writer.writeAll(text[i..][0..seq_len]);
        } else switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            // a raw control byte or a stray non-UTF-8 one; whitespace is handled above
            0x00...0x1f, 0x7f...0xff => try writer.print("\\\\x{X:0>2}", .{ch}),
            else => try writer.writeByte(ch),
        }
        i += seq_len;
        count += 1;
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const Cfg = @import("../Cfg.zig");
const Semantic = @import("../../Semantic.zig");
const BasicBlock = Cfg.BasicBlock;
const Container = Cfg.Container;
const Edge = Cfg.Edge;
const NodeIndex = std.zig.Ast.Node.Index;

const t = std.testing;

test render {
    var builder: Semantic.Builder = .init(t.allocator);
    defer builder.deinit();
    builder.withCfg(true);

    var result = try builder.build(
        \\const x = blk: {
        \\    break :blk 1;
        \\};
        \\pub fn f(a: bool) !void {
        \\    defer g();
        \\    if (a) return error.Oops;
        \\    while (a) {}
        \\}
    );
    defer result.deinit();
    try t.expect(!result.hasErrors());

    var out: Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    try render(t.allocator, &result.value, &out.writer, .{ .title = "demo.zig" });
    const src = out.written();

    try t.expect(std.mem.indexOf(u8, src, "digraph cfg {") != null);
    try t.expect(std.mem.indexOf(u8, src, "demo.zig") != null);
    try t.expect(std.mem.indexOf(u8, src, "label=\"cleanup\"") != null);
    try t.expect(std.mem.indexOf(u8, src, "label=\"true\"") != null);
    try t.expect(std.mem.indexOf(u8, src, "label=\"back\"") != null);
    try t.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, src, "\n"), "}"));

    // container header: visibility, kind, name, line, block count
    try t.expect(std.mem.indexOf(u8, src, "label=\"pub fn f  L4  ") != null);
    // instructions carry their source line, terminators name their node
    try t.expect(std.mem.indexOf(u8, src, "6: condition  a") != null);
    try t.expect(std.mem.indexOf(u8, src, "5: cleanup  g()") != null);
    try t.expect(std.mem.indexOf(u8, src, "-> return  return error.Oops") != null);
    // the loop header is a join
    try t.expect(std.mem.indexOf(u8, src, " preds") != null);
    // color coding + legend
    try t.expect(std.mem.indexOf(u8, src, "fillcolor=\"" ++ fill.entry ++ "\"") != null);
    try t.expect(std.mem.indexOf(u8, src, "fillcolor=\"" ++ fill.loop ++ "\"") != null);
    try t.expect(std.mem.indexOf(u8, src, "cluster_legend") != null);

    // decl initializer containers are skipped by default...
    try t.expect(std.mem.indexOf(u8, src, "decl x") == null);
    try t.expect(std.mem.indexOf(u8, src, "break :blk 1") == null);

    // ...and included on request, as is the legend on demand.
    var full: Writer.Allocating = .init(t.allocator);
    defer full.deinit();
    try render(t.allocator, &result.value, &full.writer, .{ .decls = true, .legend = false });
    try t.expect(std.mem.indexOf(u8, full.written(), "decl x") != null);
    try t.expect(std.mem.indexOf(u8, full.written(), "break :blk 1") != null);
    try t.expect(std.mem.indexOf(u8, full.written(), "cluster_legend") == null);
}

test seqLenAt {
    // well-formed sequences report their full length
    try t.expectEqual(1, seqLenAt("a", 0));
    try t.expectEqual(2, seqLenAt("æ", 0));
    try t.expectEqual(3, seqLenAt("日", 0));
    try t.expectEqual(4, seqLenAt("😀", 0));
    try t.expectEqual(3, seqLenAt("a日b", 1));

    // anything malformed falls back to one byte, so callers always advance
    try t.expectEqual(1, seqLenAt("æ", 1)); // continuation byte, not a start byte
    try t.expectEqual(1, seqLenAt("\xff", 0)); // never a start byte
    try t.expectEqual(1, seqLenAt("\xc3", 0)); // sequence runs past the end
    try t.expectEqual(1, seqLenAt("\xc3A", 0)); // missing continuation byte
    try t.expectEqual(1, seqLenAt("\xc0\x80", 0)); // overlong encoding of U+0000
    try t.expectEqual(1, seqLenAt("\xed\xa0\x80", 0)); // surrogate half U+D800
    try t.expectEqual(1, seqLenAt("\xf7\xbf\xbf\xbf", 0)); // codepoint above U+10FFFF
}

test writeText {
    const case = struct {
        fn check(expected: []const u8, text: []const u8, limit: ?usize) !void {
            var out: Writer.Allocating = .init(t.allocator);
            defer out.deinit();
            try writeText(&out.writer, text, limit);
            try t.expectEqualStrings(expected, out.written());
        }
    }.check;

    // whitespace collapses, quotes and backslashes are escaped
    try case("a b c", "a  b\n\tc", null);
    try case("say \\\"hi\\\" \\\\n", "say \"hi\" \\n", null);

    // `limit` counts codepoints, not bytes, and never splits one. "æ" is 2
    // bytes, so a byte-wise limit of 2 would emit a lone 0xC3.
    try case("aæb", "aæb", null);
    try case("aæ...", "aæb", 2);
    try case("æææ...", "ææææ", 3);

    // control bytes and stray non-UTF-8 bytes are escaped, not passed through.
    // A lone 0xC3 is a lead byte with no continuation: don't run off the end.
    try case("a\\\\x00b", "a\x00b", null);
    try case("\\\\xFF", "\xff", null);
    try case("\\\\xC3", "\xc3", null);
}

test BlocksByContainer {
    const c: [7]Container.Id = .{ .from(2), .from(0), .from(2), .from(0), .from(3), .from(0), .from(2) };
    var grouped: BlocksByContainer = try .init(t.allocator, &c, 4);
    defer grouped.deinit(t.allocator);

    try t.expectEqualSlices(BasicBlock.Id, &.{ .from(1), .from(3), .from(5) }, grouped.blocksIn(0));
    try t.expectEqualSlices(BasicBlock.Id, &.{}, grouped.blocksIn(1));
    try t.expectEqualSlices(BasicBlock.Id, &.{ .from(0), .from(2), .from(6) }, grouped.blocksIn(2));
    try t.expectEqualSlices(BasicBlock.Id, &.{.from(4)}, grouped.blocksIn(3));

    try t.expectEqual(c.len, grouped.ids.len);
    try t.expectEqual(0, grouped.offsets[0]);
    try t.expectEqual(c.len, grouped.offsets[grouped.offsets.len - 1]);

    var empty: BlocksByContainer = try .init(t.allocator, &.{}, 0);
    defer empty.deinit(t.allocator);
    try t.expectEqual(0, empty.ids.len);
}

test LineIndex {
    var lines: LineIndex = try .init(t.allocator, "a\nbb\n\nccc");
    defer lines.deinit(t.allocator);

    try t.expectEqual(1, lines.lineOf(0)); // 'a'
    try t.expectEqual(1, lines.lineOf(1)); // the newline itself
    try t.expectEqual(2, lines.lineOf(2)); // 'b'
    try t.expectEqual(3, lines.lineOf(5)); // empty line
    try t.expectEqual(4, lines.lineOf(8)); // last char, no trailing newline
}
