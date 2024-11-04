const std = @import("std");
const print = std.debug.print;
const utils = @import("utils.zig");

// test suites
const semantic_coverage = @import("semantic/ecosystem_coverage.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .never_unmap = true,
        .retain_metadata = true,
    }){};
    defer {
        _ = gpa.detectLeaks();
        const status = gpa.deinit();
        if (status == .leak) {
            std.debug.panic("Memory leak detected\n", .{});
        }
    }
    const alloc = gpa.allocator();

    try utils.TestFolders.globalInit();

    print("running semantic coverage tests\n", .{});
    try semantic_coverage.globalSetup(alloc);
    try semantic_coverage.run(alloc);
}
