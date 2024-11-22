rule: Rule,
linter: Linter,

filename: string,

/// Test cases that should produce no violations when linted.
passes: std.ArrayListUnmanaged([:0]const u8) = .{},
/// Test cases that should produce at least one violation when linted.
fails: std.ArrayListUnmanaged([:0]const u8) = .{},
/// Violation diagnostics collected by pass and fail cases.
errors: std.ArrayListUnmanaged(Error) = .{},
diagnostic: TestDiagnostic = .{},
fmt: GraphicalFormatter,

alloc: Allocator,

const RuleTester = @This();

const SNAPSHOT_DIR = "src/linter/rules/snapshots";

const SnapshotError = fs.Dir.OpenError || fs.Dir.MakeError || fs.Dir.StatFileError || Allocator.Error || fs.File.WriteError;
const TestError = error{
    /// Expected no violations, but violations were found.
    PassFailed,
    /// Expected violations, but none were found.
    FailPassed,
};
pub const LintTesterError = SnapshotError || TestError;

pub fn init(alloc: Allocator, rule: Rule) RuleTester {
    const filename = std.mem.concat(alloc, u8, &[_]string{ rule.meta.name, ".zig" }) catch @panic("OOM");
    var linter = Linter.init(alloc);
    linter.rules.append(rule) catch @panic("OOM");

    const fmt = GraphicalFormatter.unicode(alloc, false);
    return .{
        .rule = rule,
        .filename = filename,
        .linter = linter,
        .fmt = fmt,
        .alloc = alloc,
    };
}

/// Set the file name to use when linting test cases. It must end in `.zig`.
///
/// By default, the file name is `<rule-name>.zig`.
pub fn setFileName(self: *RuleTester, filename: string) void {
    util.assert(std.mem.endsWith(u8, filename, ".zig"), "File names must end in .zig", .{});
    self.alloc.free(self.filename);
    self.filename = self.alloc.dupe(u8, filename) catch |e| {
        panic("Failed to allocate for filename {s}: {s}", .{ filename, @errorName(e) });
    };
}
pub fn withPath(self: *RuleTester, source_dir: string) *RuleTester {
    const new_name = fs.path.join(self.alloc, &[_]string{ source_dir, self.filename }) catch @panic("OOM");
    self.alloc.free(self.filename);
    self.filename = new_name;
    return self;
}

pub fn withPass(self: *RuleTester, comptime pass: []const [:0]const u8) *RuleTester {
    self.passes.appendSlice(self.alloc, pass) catch |e| {
        const name = self.rule.meta.name;
        panic("Failed to add pass cases to RuleTester for {s}: {s}", .{ name, @errorName(e) });
    };
    return self;
}

pub fn withFail(self: *RuleTester, comptime fail: []const [:0]const u8) *RuleTester {
    self.fails.appendSlice(self.alloc, fail) catch |e| {
        const name = self.rule.meta.name;
        panic("Failed to add fail cases to RuleTester for {s}: {s}", .{ name, @errorName(e) });
    };
    return self;
}

pub fn run(self: *RuleTester) !void {
    self.runImpl() catch |e| {
        const msg = self.diagnostic.message.borrow();
        var stderr = std.io.getStdErr().writer();
        try stderr.writeAll(msg);
        try stderr.writeByte('\n');

        switch (e) {
            TestError.FailPassed => {
                for (self.errors.items) |err| {
                    try self.fmt.format(&stderr, err);
                    try stderr.writeByte('\n');
                }
                return TestError.FailPassed;
            },
            else => return e,
        }
    };
}
fn runImpl(self: *RuleTester) LintTesterError!void {
    // Run pass cases
    var i: usize = 0;
    for (self.passes.items) |src| {
        defer i += 1;

        // TODO: support static strings in Source w/o leaking memory.
        var source = try Source.fromString(
            self.alloc,
            try self.alloc.dupeZ(u8, src),
            try self.alloc.dupe(u8, self.filename),
        );
        defer source.deinit();
        var pass_errors: ?std.ArrayList(Error) = null;
        self.linter.runOnSource(&source, &pass_errors) catch |e| switch (e) {
            error.OutOfMemory => return Allocator.Error.OutOfMemory,
            else => {
                self.diagnostic.message = BooStr.fmt(
                    self.alloc,
                    "Expected test case #{d} to pass:\n\n{s}\n\nError: {s}\n",
                    .{ i + 1, self.rule.meta.name, @errorName(e) },
                ) catch @panic("OOM");
                return LintTesterError.PassFailed;
            },
        };

        if (pass_errors) |errors| {
            defer errors.deinit();
            try self.errors.appendSlice(self.alloc, errors.items);
            if (errors.items.len > 0) {
                self.diagnostic.message = BooStr.fmt(
                    self.alloc,
                    "Expected test case #{d} to pass:\n\n{s}",
                    .{ i + 1, src },
                ) catch @panic("OOM");
                return LintTesterError.PassFailed;
            }
        }
    }

    // Run fail cases
    i = 0;
    for (self.fails.items) |src| {
        defer i += 1;
        // TODO: support static strings in Source w/o leaking memory.
        var source = try Source.fromString(
            self.alloc,
            try self.alloc.dupeZ(u8, src),
            try self.alloc.dupe(u8, self.filename),
        );
        defer source.deinit();
        var fail_errors: ?std.ArrayList(Error) = null;
        defer if (fail_errors) |e| {
            self.errors.appendSlice(self.alloc, e.items) catch @panic("OOM");
            e.deinit();
        };
        self.linter.runOnSource(&source, &fail_errors) catch |e| switch (e) {
            error.OutOfMemory => return Allocator.Error.OutOfMemory,
            else => {
                // A fail case did, in fact, fail? Good.
                continue;
            },
        };
        if (fail_errors == null or fail_errors.?.items.len == 0) {
            self.diagnostic.message = BooStr.fmt(
                self.alloc,
                "Expected test case #{d} to fail:\n\n{s}",
                .{ i + 1, src },
            ) catch @panic("OOM");
            return LintTesterError.FailPassed;
        }
    }

    try self.saveSnapshot();
}

fn saveSnapshot(self: *RuleTester) SnapshotError!void {
    const snapshot_file: fs.File = brk: {
        var snapshot_dir = fs.cwd().makeOpenPath(SNAPSHOT_DIR, .{}) catch |e| {
            self.diagnostic.message = BooStr.borrowed("Failed to open snapshot directory '" ++ SNAPSHOT_DIR ++ "'");
            return e;
        };
        defer snapshot_dir.close();
        const snapshot_filename = try std.mem.concat(self.alloc, u8, &[_]string{ self.rule.meta.name, ".snap" });
        defer self.alloc.free(snapshot_filename);
        const snapshot_file = snapshot_dir.createFile(snapshot_filename, .{ .truncate = true }) catch |e| {
            self.diagnostic.message = BooStr.fmt(
                self.alloc,
                "Failed to open snapshot file '{s}'",
                .{snapshot_filename},
            ) catch @panic("OOM");
            return e;
        };
        break :brk snapshot_file;
    };
    defer snapshot_file.close();

    var w = snapshot_file.writer();
    for (self.errors.items) |err| {
        try self.fmt.format(&w, err);
        try w.writeByte('\n');
    }
}

pub fn deinit(self: *RuleTester) void {
    self.linter.deinit();
    self.alloc.free(self.filename);
    self.passes.deinit(self.alloc);
    self.fails.deinit(self.alloc);
    self.diagnostic.message.deinit();

    for (0..self.errors.items.len) |i| {
        var err = self.errors.items[i];
        err.deinit(self.alloc);
    }
    self.errors.deinit(self.alloc);
}

const TestDiagnostic = struct {
    /// Always static. Do not `free()`.
    message: BooStr = BooStr.borrowed(""),
    // errors:
};

const std = @import("std");
const fs = std.fs;
const util = @import("util");

const Allocator = std.mem.Allocator;
const Error = @import("../Error.zig");
const Linter = @import("../linter.zig").Linter;
const Rule = @import("rule.zig").Rule;
const Source = @import("../source.zig").Source;
const GraphicalFormatter = @import("../reporter.zig").GraphicalFormatter;

const BooStr = util.Boo(string);
const string = util.string;
const panic = std.debug.panic;
const assert = std.debug.assert;

const NodeWrapper = @import("rule.zig").NodeWrapper;
const LinterContext = @import("lint_context.zig");
const MockRule = struct {
    pub const meta: Rule.Meta = .{
        .name = "my-rule",
        .category = .correctness,
    };
    pub fn runOnNode(_: *const MockRule, _: NodeWrapper, _: *LinterContext) void {}
};
test RuleTester {
    const t = std.testing;
    var mock_rule = MockRule{};
    const rule = Rule.init(&mock_rule);
    var tester = RuleTester.init(t.allocator, rule);
    defer tester.deinit();
}
