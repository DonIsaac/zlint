const std = @import("std");
const utils = @import("../utils.zig");
const TestSuite = @import("TestSuite.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const panic = std.debug.panic;
const print = std.debug.print;

const TestAllocator = std.heap.GeneralPurposeAllocator(.{
    .never_unmap = true,
    .retain_metadata = true,
});

var gpa = TestAllocator{};
var global_runner_instance = TestRunner.new(gpa.allocator());

pub fn getRunner() *TestRunner {
    return &global_runner_instance;
}

pub fn addTest(test_file: TestRunner.TestFile) *TestRunner {
    assert(global_runner_instance != null);
    return global_runner_instance.?.addTest(test_file);
}

pub fn globalShutdown() void {
    getRunner().deinit();

    _ = gpa.detectLeaks();
    const status = gpa.deinit();
    if (status == .leak) {
        panic("Memory leak detected\n", .{});
    }
}

pub const TestRunner = struct {
    tests: std.ArrayListUnmanaged(TestFile) = .{},
    alloc: Allocator,

    pub inline fn new(alloc: Allocator) TestRunner {
        return TestRunner{ .alloc = alloc };
    }

    pub inline fn deinit(self: *TestRunner) void {
        for (self.tests.items) |test_file| {
            if (test_file.deinit) |deinit_fn| {
                deinit_fn(self.alloc);
            }
        }
        self.tests.deinit(self.alloc);
    }

    pub inline fn addTest(self: *TestRunner, test_file: TestFile) *TestRunner {
        self.tests.append(self.alloc, test_file) catch |e| panic("Failed to add test {s}: {any}\n", .{ test_file.name, e });
        return self;
    }

    // pub inline fn addSuite(self: *TestRunner, test_suite: TestSuite) *TestRunner {
    //     const test_file = TestFile {
    //         const
    //     }
    // }

    pub inline fn runAll(self: *TestRunner) !void {
        try utils.TestFolders.globalInit();

        var last_error: ?anyerror = null;
        for (self.tests.items) |test_file| {
            if (test_file.globalSetup) |global_setup| {
                try global_setup(self.alloc);
            }
            print("Running test {s}...\n", .{test_file.name});
            test_file.run(self.alloc) catch |e| {
                print("Failed to run test {s}: {any}\n", .{ test_file.name, e });
                last_error = e;
            };
        }

        if (last_error) |e| {
            return e;
        }
    }
};

pub const TestFile = struct {
    /// Inlined string (`&'static str`). Never deallocated.
    name: []const u8,
    globalSetup: ?*const GlobalSetupFn = null,
    deinit: ?*const GlobalTeardownFn = null,
    run: *const RunFn,

    pub const GlobalSetupFn = fn (alloc: Allocator) anyerror!void;
    pub const GlobalTeardownFn = fn (alloc: Allocator) void;
    pub const RunFn = fn (alloc: Allocator) anyerror!void;

    fn fromSuite(suite: TestSuite) TestFile {
        const gen = struct {
            fn deinit(_: Allocator) void {
                suite.deinit();
            }
            fn run(_: Allocator) anyerror!void {
                suite.run();
            }
        };
        return TestFile{
            .name = suite.name,
            .run = &gen.run,
            .deinit = &gen.deinit,
        };
    }
};
