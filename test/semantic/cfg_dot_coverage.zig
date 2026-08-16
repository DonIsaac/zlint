//! Renders a CFG as Graphviz DOT for every file in one ecosystem repo and
//! checks the result parses. `nop` is graphviz's parse-and-reprint tool; a full
//! `dot` layout pass is orders of magnitude slower.

const test_runner = @import("../harness.zig");

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const print = std.debug.print;

const zlint = @import("zlint");
const Source = zlint.Source;
const dot = zlint.Semantic.Cfg.dot;

const utils = @import("../utils.zig");

/// One repo only: a DOT render plus a `nop` subprocess per file is expensive.
/// lightpanda is the smallest non-trivial repo in the corpus (~426 files).
const REPO = "lightpanda";

var nop_available = false;

pub fn globalSetup(alloc: Allocator) !void {
    const io = test_runner.io();
    // `nop` with no file arguments reads stdin, which `run` leaves empty.
    const res = std.process.run(alloc, io, .{ .argv = &.{"nop"} }) catch |e| switch (e) {
        // Skipping is a convenience for local dev; on CI it would silently
        // disable this whole suite.
        error.FileNotFound => {
            if (isCi(alloc)) {
                print("`nop` (graphviz) not found. Refusing to skip DOT validation on CI.\n", .{});
                return error.GraphvizNotFound;
            }
            print("`nop` (graphviz) not found, skipping DOT validation suite.\n", .{});
            return;
        },
        else => return e,
    };
    alloc.free(res.stdout);
    alloc.free(res.stderr);
    nop_available = true;
}

/// GitHub Actions and most other CI providers set `CI` to a non-empty value.
fn isCi(alloc: Allocator) bool {
    const value = test_runner.getRunner().environ.getAlloc(alloc, "CI") catch return false;
    defer alloc.free(value);
    return value.len > 0;
}

fn testCfgDot(alloc: Allocator, source: *const Source) !void {
    var builder = zlint.Semantic.Builder.init(alloc);
    defer builder.deinit();
    builder.withCfg(true);
    var res = try builder.build(source.text());
    defer res.deinit();
    // parse/analysis failures are the ecosystem suite's business, not ours
    if (res.hasErrors()) return;

    const name = source.pathname orelse "<unknown>";
    var rendered: Io.Writer.Allocating = .init(alloc);
    defer rendered.deinit();
    try dot.render(alloc, &res.value, &rendered.writer, .{ .decls = true, .title = name });

    try verifyInvariants(&res.value.cfg);
    try validateDotSyntax(alloc, rendered.written(), name);
}

/// Pipe `src` through `nop`. Anything on stderr, or a non-zero exit, means the
/// graph we generated is malformed.
fn validateDotSyntax(alloc: Allocator, src: []const u8, name: []const u8) !void {
    const io = test_runner.io();
    var child = try std.process.spawn(io, .{
        .argv = &.{"nop"},
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .pipe,
    });
    defer child.kill(io);

    const stdin = child.stdin.?;
    try stdin.writeStreamingAll(io, src);
    stdin.close(io);
    child.stdin = null;

    var buf: [4096]u8 = undefined;
    var stderr_reader = child.stderr.?.readerStreaming(io, &buf);
    const stderr = try stderr_reader.interface.allocRemaining(alloc, .limited(64 * 1024));
    defer alloc.free(stderr);

    const term = try child.wait(io);
    const failed = switch (term) {
        .exited => |code| code != 0,
        else => true,
    };
    if (!failed and stderr.len == 0) return;

    print("Malformed DOT for {s}:\n{s}\n", .{ name, stderr });
    return error.InvalidDot;
}

fn verifyInvariants(cfg: *const zlint.Semantic.Cfg) !void {
    // these are all index lists keyed on BB ids. Each has 1 entry per block.
    const block_count = cfg.blocks.len;
    if (block_count != cfg.successors.items.len) return error.BlockSuccessorMismatch;
    if (block_count != cfg.predecessors.items.len) return error.BlockPredecessorMismatch;
    if (block_count == 0) return;

    // all subgraphs have different entry/exit nodes.
    const entries = cfg.containers.items(.entry);
    const exits = cfg.containers.items(.exit);
    const block_containers = cfg.blocks.items(.container);
    const block_flags = cfg.blocks.items(.flags);
    for (0..cfg.containers.len) |i| {
        if (entries[i] == exits[i]) return error.ContainerEntryBlockIsExit;
        if (entries[i].int() >= block_count) return error.ContainerEntryBlockOutOfBounds;
        if (exits[i].int() >= block_count) return error.ContainerExitBlockOutOfBounds;

        // entry/exit block relationships are reciprocal
        const entry_block = block_containers[entries[i].into(usize)];
        const exit_block = block_containers[exits[i].into(usize)];
        if (entry_block.int() != i) return error.ContainerEntryBlockOrphan;
        if (exit_block.int() != i) return error.ContainerExitBlockOrphan;
    }

    // Each container has exactly one flagged entry and exit: its designated
    // entry and exit blocks.
    for (block_containers, block_flags, 0..) |container, flags, i| {
        const container_index = container.into(usize);
        if (container_index >= cfg.containers.len) return error.BlockContainerOutOfBounds;
        if (flags.b_entry != (entries[container_index].int() == i)) {
            return error.ContainerEntryFlagMismatch;
        }
        if (flags.b_exit != (exits[container_index].int() == i)) {
            return error.ContainerExitFlagMismatch;
        }
    }
}

pub fn run(alloc: Allocator) !void {
    if (!nop_available) return;
    const io = test_runner.io();
    const repo_dir = try utils.TestFolders.openRepo(alloc, io, REPO);
    var suite = try test_runner.TestSuite.init(
        alloc,
        io,
        repo_dir,
        "cfg-dot-coverage",
        REPO,
        .{ .test_fn = &testCfgDot },
    );
    defer suite.deinit();

    try suite.run();
}

pub const SUITE = test_runner.TestFile{
    .name = "cfg_dot_coverage",
    .globalSetup = globalSetup,
    .run = run,
};
