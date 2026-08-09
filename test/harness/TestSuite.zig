const TestSuite = @This();

vtable: TestSuiteFns,

group_name: []const u8,
suite_name: []const u8,
dir: Io.Dir,
walker: Io.Dir.Walker,

errors: std.ArrayListUnmanaged(string) = .empty,
errors_mutex: Io.Mutex = .init,
stats: Stats = .{},

alloc: Allocator,
io: Io,

pub const TestFn = fn (allocator: Allocator, source: *const Source) anyerror!void;
pub const SetupFn = fn (suite: *TestSuite) anyerror!void;

pub const TestSuiteFns = struct {
    test_fn: *const TestFn,
    setup_fn: ?*const fn (suite: *TestSuite) anyerror!void = null,
    teardown_fn: ?*const fn (suite: *TestSuite) anyerror!void = null,
};

/// Takes ownership of `dir`. Do not close it directly after passing.
pub fn init(
    alloc: Allocator,
    io: Io,
    dir: Io.Dir,
    group_name: string,
    suite_name: string,
    fns: TestSuiteFns,
) !TestSuite {
    errdefer dir.close(io);
    const walker = try dir.walk(alloc);

    return TestSuite{
        .vtable = fns,
        .group_name = group_name,
        .suite_name = suite_name,
        .dir = dir,
        .walker = walker,
        .alloc = alloc,
        .io = io,
    };
}

pub fn deinit(self: *TestSuite) void {
    self.walker.deinit();
    self.dir.close(self.io);
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
    const cfg = harness.getRunner().config;
    if (self.vtable.setup_fn) |setup| {
        try setup(self);
    }
    self.beginLogGroup(cfg);
    defer endLogGroup(cfg);
    var group: Io.Group = .init;
    while (try self.walker.next(self.io)) |ent| {
        if (ent.kind != .file) continue;
        if (!std.mem.endsWith(u8, ent.path, ".zig")) continue;
        if (std.mem.startsWith(u8, ent.path, ".git")) continue;
        if (std.mem.indexOf(u8, ent.path, ".zig-cache") != null) continue;
        if (std.mem.indexOfScalar(u8, ent.path, 0) != null) {
            std.debug.print("bad path: {s}\n", .{ent.path});
            @panic("fuck");
        }
        // Walker.Entry is not thread-safe. walk() uses a non-sync stack, and
        // Entries store pointers to data in that stack. Subsequent calls to
        // walker.next() will clobber data addressed by these pointers, so we
        // must make our own copy.
        const entry_path = try self.alloc.dupe(u8, ent.path);
        group.async(self.io, runInThread, .{ self, entry_path });
    }
    try group.await(self.io);
    finishProgressLine(cfg);
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
    const file = self.dir.openFile(self.io, filename, .{}) catch |e| {
        self.pushErr(path, e);
        return;
    };
    // TODO: use some kind of Cow wrapper to avoid duplication here
    const filename_owned = self.alloc.dupe(u8, filename) catch @panic("OOM");
    var source = Source.init(self.alloc, self.io, file, filename_owned) catch |e| {
        self.alloc.free(filename_owned);
        self.pushErr(path, e);
        return;
    };
    defer source.deinit();

    var passed = true;
    recover.call(runImpl, .{ self, &source }) catch |e| {
        self.pushErr(path, e);
        passed = false;
    };
    self.printRun(&source, passed);
    if (passed) self.stats.incPass();
}

pub fn runImpl(self: *TestSuite, source: *const Source) anyerror!void {
    return @call(.never_inline, self.vtable.test_fn, .{ self.alloc, source });
}
fn printRun(self: *const TestSuite, source: *const Source, passed: bool) void {
    const cfg = harness.getRunner().config;
    const status_icon = if (passed) "\u{2705}" else "\u{274C}";

    var p = source.pathname orelse "<missing>";
    // Passing runs are transient: they get overwritten by the next status via
    // `\r`, which only returns to the start of the current *row*. A line that
    // wraps would leave the cursor mid-message, so keep it short. Failures are
    // permanent lines, so wrapping is harmless there and the full path matters.
    if (cfg.is_tty and passed and p.len > max_transient_path) {
        p = p[p.len - max_transient_path ..];
    }

    comptime var c = Chameleon.initComptime();
    comptime var gray = c.gray().createPreset();
    comptime var yellow = c.yellow().createPreset();

    const fmt_color = gray.fmt("[{s}]") ++ yellow.fmt(" {s}") ++ ": {s} {s}";
    const fmt_plain = "[{s}] {s}: {s} {s}";

    var buf: [256]u8 = undefined;
    const stderr = std.debug.lockStderr(&buf);
    defer std.debug.unlockStderr();
    const w = &stderr.file_writer.interface;

    const args = .{ self.group_name, self.suite_name, status_icon, p };
    if (cfg.color)
        w.print(fmt_color, args) catch return
    else
        w.print(fmt_plain, args) catch return;

    if (cfg.is_tty) {
        // Passing runs are overwritten by the next status; failures stay put.
        w.writeAll(if (passed) end_transient_line else end_permanent_line) catch {};
    } else {
        w.writeByte('\n') catch {};
    }
}

/// Visible path budget for a single-row progress line. Conservative enough to
/// leave room for the group/suite prefix on an 80-column terminal.
const max_transient_path = 48;

/// `ESC` (0x1B) followed by `[` is CSI, the introducer for an ANSI control
/// sequence.
const csi = "\x1b[";
/// CSI `0K` is `EL` (erase in line) with parameter 0: clear from the cursor to
/// the end of the current row, leaving the cursor where it is. Used to wipe
/// leftovers from a longer status that was previously printed on this row.
const erase_to_eol = csi ++ "0K";
/// A status line that will be overwritten by the next one: erase this row's
/// tail, then park the cursor back at column 0.
const end_transient_line = erase_to_eol ++ "\r";
/// A status line that stays in scrollback: erase this row's tail, then advance
/// to a fresh row.
const end_permanent_line = erase_to_eol ++ "\n";

/// See: https://docs.github.com/actions/reference/workflow-commands-for-github-actions#grouping-log-lines
const gh_group_start = "::group::";
const gh_group_end = "::endgroup::\n";

fn beginLogGroup(self: *const TestSuite, cfg: harness.Config) void {
    switch (cfg.format) {
        .utf8 => {},
        .github => std.debug.print(gh_group_start ++ "{s}/{s}\n", .{
            self.group_name,
            self.suite_name,
        }),
    }
}

fn endLogGroup(cfg: harness.Config) void {
    switch (cfg.format) {
        .utf8 => {},
        .github => std.debug.print(gh_group_end, .{}),
    }
}

/// Commit the trailing transient progress line, if any, so subsequent output
/// doesn't land on top of it.
fn finishProgressLine(cfg: harness.Config) void {
    if (!cfg.is_tty) return;
    var buf: [8]u8 = undefined;
    const stderr = std.debug.lockStderr(&buf);
    defer std.debug.unlockStderr();
    stderr.file_writer.interface.writeAll(erase_to_eol) catch {};
}

fn pushErr(self: *TestSuite, msg: string, err: anytype) void {
    const err_msg = std.fmt.allocPrint(self.alloc, "{s}: {any}", .{ msg, err }) catch @panic("Failed to allocate error message: OOM");
    if (err == error.Panic) {
        self.stats.incPanic();
    } else {
        self.stats.incFail();
    }
    self.errors_mutex.lockUncancelable(self.io);
    defer self.errors_mutex.unlock(self.io);
    self.errors.append(self.alloc, err_msg) catch @panic("Failed to push error into error list.");
}

fn writeSnapshot(self: *TestSuite) !void {
    const snapshot = try self.openSnapshotFile();
    defer snapshot.close(self.io);
    var buf: [1024]u8 = undefined;
    var w = snapshot.writer(self.io, &buf);
    defer w.interface.flush() catch @panic("failed to flush writer");

    const pass = self.stats.pass.load(.monotonic);
    const panics = self.stats.panic.load(.monotonic);
    const total = self.stats.total();

    {
        const pct = self.stats.passPct();
        try w.interface.print("Passed: {d}% ({d}/{d})\n", .{ pct, pass, total });
    }
    {
        const pct = 100.0 * (@as(f32, @floatFromInt(panics)) / @as(f32, @floatFromInt(total)));
        try w.interface.print("Panics: {d}% ({d}/{d})\n\n", .{ pct, panics, total });
    }
    self.errors_mutex.lockUncancelable(self.io);
    defer self.errors_mutex.unlock(self.io);
    // errors must be sorted for stable `git diff` output
    std.mem.sort(string, self.errors.items, {}, stringsLessThan);
    for (self.errors.items) |err| {
        try w.interface.print("{s}\n", .{err});
    }
}

fn openSnapshotFile(self: *TestSuite) !Io.File {
    const SNAP_EXT = ".snap";

    var stack_alloc = std.heap.stackFallback(1024, self.alloc);
    var allocator = stack_alloc.get();

    const snapshot_name = try std.mem.concat(allocator, u8, &[_]string{ self.suite_name, SNAP_EXT });
    defer allocator.free(snapshot_name);

    return utils.TestFolders.openSnapshotFile(allocator, self.io, self.group_name, snapshot_name);
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

    pub inline fn total(self: *const Stats) usize {
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

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const recover = @import("recover");
const Chameleon = @import("chameleon");

const utils = @import("../utils.zig");
const harness = @import("../harness.zig");
const string = utils.string;
const Source = zlint.Source;

const zlint = @import("zlint");
