const Runtime = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Constellation = @import("../semantic/Constellation.zig");

pool: Thread.Pool,
constellation: Constellation,
// allocator: Allocator,

pub fn init(allocator: Allocator, n_threads: u32) Allocator.Error!Runtime {
    var pool: Thread.Pool = undefined;
    try pool.init(.{ .n_jobs = n_threads, .allocator = allocator });

    return Runtime{
        .pool = pool,
        .allocator = allocator,
    };
}

