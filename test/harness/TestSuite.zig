/// Root directory containing zig files being tested
test_fn: *const TestFn,
setup_fn: ?*const fn (suite: *TestSuite) anyerror!void,
teardown_fn: ?*const fn (suite: *TestSuite) anyerror!void,

group_name: []const u8,
suite_name: []const u8,
dir: fs.Dir,
walker: fs.Dir.Walker,

errors: std.ArrayListUnmanaged(string) = .{},
errors_mutex: std.Thread.Mutex = .{},
stats: Stats = .{},

alloc: Allocator,

pub const TestFn = fn (alloc: Allocator, source: *const Source) anyerror!void;
pub const SetupFn = fn (suite: *TestSuite) anyerror!void;

pub const TestSuiteFns = struct {
    test_fn: *const TestFn,
    setup_fn: ?*const fn (suite: *TestSuite) anyerror!void = null,
    teardown_fn: ?*const fn (suite: *TestSuite) anyerror!void = null,
};

/// Takes ownership of `dir`. Do not close it directly after passing.
pub fn init(
    alloc: Allocator,
    dir: fs.Dir,
    group_name: string,
    suite_name: string,
    fns: TestSuiteFns,
) !TestSuite {
    const walker = try dir.walk(alloc);

    return TestSuite{
        .test_fn = fns.test_fn,
        .setup_fn = fns.setup_fn,
        .teardown_fn = fns.teardown_fn,
        .group_name = group_name,
        .suite_name = suite_name,
        .dir = dir,
        .walker = walker,
        .alloc = alloc,
    };
}

pub fn deinit(self: *TestSuite) void {
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
    if (self.setup_fn) |setup| {
        try setup(self);
    }
    var pool: ThreadPool = undefined;
    try pool.init(.{ .allocator = self.alloc });
    while (try self.walker.next()) |ent| {
        if (ent.kind != .file) continue;
        if (!std.mem.endsWith(u8, ent.path, ".zig")) continue;
        if (std.mem.indexOfScalar(u8, ent.path, 0) != null) {
            std.debug.panic("bad path: {s}\n", .{ent.path});
        }
        // Walker.Entry is not thread-safe. walk() uses a non-sync stack, and
        // Entries store pointers to data in that stack. Subsequent calls to
        // walker.next() will clobber data addressed by these pointers, so we
        // must make our own copy.
        const entry_path = try self.alloc.dupe(u8, ent.path);
        pool.spawn(runInThread, .{ self, entry_path }) catch |e| {
            const msg = try std.fmt.allocPrint(self.alloc, "Failed to spawn task for test {s}", .{ent.path});
            defer self.alloc.free(msg);
            self.pushErr(msg, e);
        };
    }
    pool.deinit();
    try self.writeSnapshot();
}

fn runInThread(self: *TestSuite, path: []const u8) void {
    defer self.alloc.free(path);
    // ThreadPool seems to be adding a null byte at the end of ent.path in some
    // cases, which breaks openFile. TODO: open a bug report in Zig.
    const sentinel = std.mem.indexOfScalar(u8, path, 0);
    const filename = if (sentinel) |s|
        path[0..s]
    else
        path;
    const file = self.dir.openFile(filename, .{}) catch |e| {
        self.pushErr(path, e);
        return;
    };
    // TODO: use some kind of Cow wrapper to avoid duplication here
    const filename_owned = self.alloc.dupe(u8, filename) catch @panic("OOM");
    var source = Source.init(self.alloc, file, filename_owned) catch |e| {
        self.pushErr(path, e);
        return;
    };
    defer source.deinit();

    recover.call(runImpl, .{ self, &source }) catch |e| {
        self.pushErr(path, e);
        return;
    };
    self.stats.incPass();
}
pub fn runImpl(self: *TestSuite, source: *const Source) anyerror!void {
    return @call(.never_inline, self.test_fn, .{ self.alloc, source });
}

fn pushErr(self: *TestSuite, msg: string, err: anytype) void {
    const err_msg = std.fmt.allocPrint(self.alloc, "{s}: {any}", .{ msg, err }) catch @panic("Failed to allocate error message: OOM");
    if (err == error.Panic) {
        self.stats.incPanic();
    } else {
        self.stats.incFail();
    }
    self.errors_mutex.lock();
    defer self.errors_mutex.unlock();
    self.errors.append(self.alloc, err_msg) catch @panic("Failed to push error into error list.");
}

fn writeSnapshot(self: *TestSuite) !void {
    const snapshot = try self.openSnapshotFile();
    defer snapshot.close();
    const writer = snapshot.writer();

    const pass = self.stats.pass.load(.monotonic);
    const panics = self.stats.panic.load(.monotonic);
    const total = self.stats.total();

    {
        const pct = self.stats.passPct();
        try writer.print("Passed: {d}% ({d}/{d})\n", .{ pct, pass, total });
    }
    {
        const pct = 100.0 * (@as(f32, @floatFromInt(panics)) / @as(f32, @floatFromInt(total)));
        try writer.print("Panics: {d}% ({d}/{d})\n\n", .{ pct, panics, total });
    }
    self.errors_mutex.lock();
    defer self.errors_mutex.unlock();
    // errors must be sorted for stable `git diff` output
    std.mem.sort(string, self.errors.items, {}, stringsLessThan);
    for (self.errors.items) |err| {
        try writer.print("{s}\n", .{err});
    }
}

fn openSnapshotFile(self: *TestSuite) !fs.File {
    const SNAP_EXT = ".snap";

    var stack_alloc = std.heap.stackFallback(1024, self.alloc);
    var allocator = stack_alloc.get();

    const snapshot_name = try std.mem.concat(allocator, u8, &[_]string{ self.suite_name, SNAP_EXT });
    defer allocator.free(snapshot_name);

    return utils.TestFolders.openSnapshotFile(allocator, self.group_name, snapshot_name);
}

fn stringsLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b).compare(.lt);
}

const Stats = struct {
    pass: AtomicUsize = AtomicUsize.init(0),
    fail: AtomicUsize = AtomicUsize.init(0),
    panic: AtomicUsize = AtomicUsize.init(0),

    const AtomicUsize = std.atomic.Value(usize);

    inline fn incPass(self: *Stats) void {
        _ = self.pass.fetchAdd(1, .monotonic);
    }

    inline fn incFail(self: *Stats) void {
        _ = self.fail.fetchAdd(1, .monotonic);
    }

    inline fn incPanic(self: *Stats) void {
        _ = self.panic.fetchAdd(1, .monotonic);
    }

    inline fn total(self: *const Stats) usize {
        // zig fmt: off
        return self.pass.load(.monotonic)
             + self.fail.load(.monotonic)
             + self.panic.load(.monotonic);
        // zig fmt: on
    }

    inline fn passPct(self: *const Stats) f32 {
        // zig fmt: off
        const pass: f32   = @floatFromInt(self.pass.load(.monotonic));
        const fail: f32   = @floatFromInt(self.fail.load(.monotonic));
        const panics: f32 = @floatFromInt(self.panic.load(.monotonic));
        // zig fmt: on

        return 100.0 * (pass / (pass + fail + panics));
    }
};

const TestSuite = @This();

const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const ThreadPool = std.Thread.Pool;
const panic = std.debug.panic;

const recover = @import("recover");

const utils = @import("../utils.zig");
const string = utils.string;
const Source = zlint.Source;

const zlint = @import("zlint");
