/// Root directory containing zig files being tested
test_fn: *const TestFn,
dir: fs.Dir,
walker: fs.Dir.Walker,
snapshot: fs.File,
alloc: Allocator,
errors: std.ArrayListUnmanaged(string) = .{},
errors_mutex: std.Thread.Mutex = .{},
stats: Stats = .{},

const TestFn = fn (alloc: Allocator, source: *const Source) anyerror!void;

/// Takes ownership of `dir`. Do not close it directly after passing.
pub fn init(
    alloc: Allocator,
    dir: fs.Dir,
    group_name: string,
    suite_name: string,
    test_fn: *const TestFn,
) !TestSuite {
    if (builtin.single_threaded) {
        @compileError("TestSuite cannot be used in a single-threaded environment.");
    }

    const SNAP_EXT = ".snap";
    // +1 for sentinel (TODO: check if needed)
    var stack_alloc = std.heap.stackFallback(256 + SNAP_EXT.len + 1, alloc);
    var allocator = stack_alloc.get();

    const snapshot_name = try std.mem.concat(alloc, u8, &[_]string{ suite_name, SNAP_EXT });
    defer allocator.free(snapshot_name);

    const snapshot = try utils.TestFolders.openSnapshotFile(alloc, group_name, snapshot_name);
    const walker = try dir.walk(alloc);

    return TestSuite{ .test_fn = test_fn, .dir = dir, .walker = walker, .snapshot = snapshot, .alloc = alloc };
}

pub fn deinit(self: *TestSuite) void {
    self.snapshot.close();
    self.walker.deinit();
    self.dir.close();
    {
        var i: usize = 0;
        while (i < self.errors.items.len) {
            self.alloc.free(self.errors.items[i]);
            i += 1;
        }
        self.errors.deinit(self.alloc);
    }
    self.* = undefined;
}

pub fn run(self: *TestSuite) !void {
    var pool: ThreadPool = undefined;
    try pool.init(.{ .allocator = self.alloc });
    defer pool.deinit();
    while (try self.walker.next()) |ent| {
        if (ent.kind != .file) continue;
        if (!std.mem.endsWith(u8, ent.path, ".zig")) continue;
        pool.spawn(runInThread, .{ self, ent }) catch |e| {
            const msg = try std.fmt.allocPrint(self.alloc, "Failed to spawn task for test {s}", .{ent.path});
            defer self.alloc.free(msg);
            self.pushErr(msg, e);
        };
    }
}

fn runInThread(self: *TestSuite, ent: fs.Dir.Walker.Entry) void {
    const file = self.dir.openFile(ent.path, .{}) catch |e| {
        self.stats.incFail();
        self.pushErr(ent.path, e);
        return;
    };
    var source = Source.init(self.alloc, file) catch |e| {
        self.stats.incFail();
        self.pushErr(ent.path, e);
        return;
    };
    defer source.deinit();
    @call(.never_inline, self.test_fn, .{ self.alloc, &source }) catch |e| {
        self.stats.incFail();
        self.pushErr(ent.path, e);
        return;
    };
    self.stats.incPass();
}

fn pushErr(self: *TestSuite, msg: string, err: anytype) void {
    const err_msg = std.fmt.allocPrint(self.alloc, "{s}: {any}\n", .{ msg, err }) catch @panic("Failed to allocate error message: OOM");
    self.errors_mutex.lock();
    defer self.errors_mutex.unlock();
    self.errors.append(self.alloc, err_msg) catch @panic("Failed to push error into error list.");
}

fn writeSnapshot(self: *TestSuite) !void {
    const total = self.stats.total();
    const pct = self.stats.passPct();

    try self.snapshot.writer().print("Passed: {d}% ({d}/{d})\n", .{ pct, self.stats.pass, total });
}

const Stats = struct {
    pass: AtomicUsize = AtomicUsize.init(0),
    fail: AtomicUsize = AtomicUsize.init(0),

    const AtomicUsize = std.atomic.Value(usize);

    inline fn incPass(self: *Stats) void {
        _ = self.pass.fetchAdd(1, .acq_rel);
    }

    inline fn incFail(self: *Stats) void {
        _ = self.fail.fetchAdd(1, .acq_rel);
    }

    inline fn total(self: *const Stats) usize {
        return self.pass.load(.acq_rel) + self.fail.load(.acq_rel);
    }

    inline fn passPct(self: *const Stats) f32 {
        const pass: f32 = @floatFromInt(self.pass.load(.acq_rel));
        const fail: f32 = @floatFromInt(self.fail.load(.acq_rel));
        return 100.0 * (pass / (pass + fail));
    }
};

const TestSuite = @This();

const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const ThreadPool = std.Thread.Pool;
const panic = std.debug.panic;

const utils = @import("utils.zig");
const string = utils.string;
const Source = zlint.Source;

const zlint = @import("zlint");
