const std = @import("std");
const utils = @import("utils.zig");

const print = std.debug.print;
const panic = std.debug.panic;

const test_runner = @import("harness/runner.zig");
const TestRunner = test_runner.TestRunner;

// test suites
const semantic_coverage = @import("semantic/ecosystem_coverage.zig");
const snapshot_coverage = @import("semantic/snapshot_coverage.zig");

pub fn main() !void {
    const runner = test_runner.getRunner();
    defer runner.deinit();
    try runner
        .addTest(semantic_coverage.SUITE)
        .addTest(snapshot_coverage.SUITE)
        .runAll();
}
