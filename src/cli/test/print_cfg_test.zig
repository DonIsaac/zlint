const std = @import("std");
const Source = @import("zlint").Source;

const print_command = @import("../print_command.zig");
const Options = @import("../Options.zig");

const t = std.testing;

const source_code: [:0]const u8 =
    \\const x = blk: {
    \\    break :blk 1;
    \\};
    \\pub fn f(a: bool) !void {
    \\    defer g();
    \\    if (a) return error.Oops;
    \\}
;

/// Render `src` through the `--print-cfg` path. Result is owned by `alloc`,
/// which is expected to be an arena.
fn printCfg(alloc: std.mem.Allocator, opts: Options, src: [:0]const u8) ![]const u8 {
    const owned = try alloc.dupeZ(u8, src);
    const source = try Source.fromString(alloc, owned, "foo.zig");
    var buf: std.Io.Writer.Allocating = .init(alloc);
    try print_command.printCfg(alloc, t.io, opts, source, &buf.writer);
    return buf.written();
}

test "printCfg renders a DOT digraph" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    const dot = try printCfg(arena.allocator(), .{ .print_cfg = true }, source_code);

    try t.expect(std.mem.indexOf(u8, dot, "digraph cfg {") != null);
    try t.expect(std.mem.indexOf(u8, dot, "pub fn f") != null);
    try t.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, dot, "\n"), "}"));
}

test "printCfg --cfg-decls includes decl initializer containers" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const without = try printCfg(alloc, .{ .print_cfg = true }, source_code);
    try t.expect(std.mem.indexOf(u8, without, "decl x") == null);

    const with = try printCfg(alloc, .{ .print_cfg = true, .cfg_decls = true }, source_code);
    try t.expect(std.mem.indexOf(u8, with, "decl x") != null);
}

// The stderr diagnostic this prints is expected: `printCfg` reports parse
// errors with `std.debug.print`.
test "printCfg writes no graph for a file that fails to parse" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    const dot = try printCfg(arena.allocator(), .{ .print_cfg = true }, "pub fn f( {");

    try t.expectEqualStrings("", dot);
}
