const std = @import("std");
const test_runner = @import("harness/runner.zig");

// Allows recovery from panics in test cases. Errors get saved to that suite's
// snapshot file, and testing continues.
pub const panic = @import("recover").panic;

// test suites
const semantic_coverage = @import("semantic/ecosystem_coverage.zig");
const snapshot_coverage = @import("semantic/snapshot_coverage.zig");
const cfg_dot_coverage = @import("semantic/cfg_dot_coverage.zig");

pub fn main(init: std.process.Init) !void {
    const runner = test_runner.getRunner();
    defer runner.deinit();
    try runner
        .setConfig(.new(init.io, init.environ_map))
        .setEnviron(init.minimal.environ)
        .addTest(semantic_coverage.SUITE)
        .addTest(snapshot_coverage.SUITE)
        .addTest(cfg_dot_coverage.SUITE)
        .runAll();
}
