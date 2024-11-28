const std = @import("std");
const utils = @import("utils.zig");

const test_runner = @import("harness/runner.zig");
const TestRunner = test_runner.TestRunner;

// Allows recovery from panics in test cases. Errors get saved to that suite's
// snapshot file, and testing continues.
// pub const panic = @import("recover").panic;

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
