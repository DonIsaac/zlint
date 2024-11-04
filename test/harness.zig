pub const TestSuite = @import("harness/TestSuite.zig");

const runner = @import("harness/runner.zig");
pub const getRunner = runner.getRunner;
pub const addTest = runner.addTest;
pub const globalShutdown = runner.globalShutdown;
pub const TestFile = runner.TestFile;
