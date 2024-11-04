const test_runner = @import("../harness.zig");
const std = @import("std");
const zlint = @import("zlint");

const Allocator = std.mem.Allocator;

var pass_fixtures: *std.fs.Dir = undefined;

fn run(alloc: Allocator) !void {
    pass_fixtures.* = try std.fs.cwd().openDir("test/fixtures/simple/pass", .{.iterate = true});
    defer pass_fixtures.close();
    const suite = test_runner.TestSuite.init(alloc, pass_fixtures, "snapshot-coverage/simple", "pass", &runPass, null);
}

fn runPass(alloc: Allocator, source: *const zlint.Source) anyerror!void {
    return;
}
