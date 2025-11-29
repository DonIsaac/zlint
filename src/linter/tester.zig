rule: Rule,
linter: Linter,

filename: []const u8,

/// Test cases that should produce no violations when linted.
passes: std.ArrayListUnmanaged([:0]const u8) = .{},
/// Test cases that should produce at least one violation when linted.
fails: std.ArrayListUnmanaged([:0]const u8) = .{},
fixes: std.ArrayListUnmanaged(FixCase) = .{},
/// Violation diagnostics collected by pass and fail cases.
diagnostics: std.ArrayListUnmanaged(Linter.Diagnostic) = .{},
diagnostic: TestDiagnostic = .{},
fmt: GraphicalFormatter,

alloc: Allocator,

const RuleTester = @This();

const SNAPSHOT_DIR = "src/linter/rules/snapshots";

const SnapshotError = fs.Dir.OpenError || fs.Dir.MakeError || fs.Dir.StatFileError || fs.File.WriteError || Allocator.Error || std.io.Writer.Error;

const TestError = error{
    /// Expected no violations, but violations were found.
    PassFailed,
    /// Expected violations, but none were found.
    FailPassed,
    /// Expected fixable violations, but none were produced
    FixPassed,
    /// After applying fixes, unfixed violations remained
    FixFailed,
    /// After applying fixes, the fixed source code did not match the expected
    /// result.
    FixMismatch,
};
pub const LintTesterError = SnapshotError || TestError || Semantic.Builder.SemanticError || Linter.LintError;

pub const FixCase = struct {
    src: [:0]const u8,
    expected: [:0]const u8,
    /// What kind of fix should have been provided. Leave this as `null` if you
    /// don't care.
    kind: ?Fix.Kind = null,
};

pub fn init(alloc: Allocator, rule: Rule) RuleTester {
    const filename = std.mem.concat(alloc, u8, &[_][]const u8{ rule.meta.name, ".zig" }) catch @panic("OOM");
    var linter = Linter.initEmpty(alloc);
    linter.registerRule(.err, rule) catch |e| {
        panic("Failed to register rule {s}: {s}", .{ rule.meta.name, @errorName(e) });
    };

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
pub fn setFileName(self: *RuleTester, filename: []const u8) void {
    util.assert(std.mem.endsWith(u8, filename, ".zig"), "File names must end in .zig", .{});
    self.alloc.free(self.filename);
    self.filename = self.alloc.dupe(u8, filename) catch |e| {
        panic("Failed to allocate for filename {s}: {s}", .{ filename, @errorName(e) });
    };
}

pub fn withPath(self: *RuleTester, source_dir: []const u8) *RuleTester {
    const new_name = fs.path.join(self.alloc, &[_][]const u8{ source_dir, self.filename }) catch @panic("OOM");
    self.alloc.free(self.filename);
    self.filename = new_name;
    return self;
}

/// Add test cases that, when linted, should not produce any diagnostics.
pub fn withPass(self: *RuleTester, comptime pass: []const [:0]const u8) *RuleTester {
    self.passes.appendSlice(self.alloc, pass) catch |e| {
        const name = self.rule.meta.name;
        panic("Failed to add pass cases to RuleTester for {s}: {s}", .{ name, @errorName(e) });
    };
    return self;
}

/// Add test cases that, when linted, should produce diagnostics.
pub fn withFail(self: *RuleTester, comptime fail: []const [:0]const u8) *RuleTester {
    self.fails.appendSlice(self.alloc, fail) catch |e| {
        const name = self.rule.meta.name;
        panic("Failed to add fail cases to RuleTester for {s}: {s}", .{ name, @errorName(e) });
    };
    return self;
}

pub fn withFix(self: *RuleTester, comptime fix: []const FixCase) *RuleTester {
    self.fixes.appendSlice(self.alloc, fix) catch |e| {
        const name = self.rule.meta.name;
        panic("Failed to add fix cases to RuleTester for {s}: {s}", .{ name, @errorName(e) });
    };
    return self;
}

pub fn run(self: *RuleTester) anyerror!void {
    self.runImpl() catch |e| {
        const msg = self.diagnostic.message.borrow();
        var buf: [512]u8 = undefined;
        var writer = try self.alloc.create(std.fs.File.Writer);
        writer.* = std.fs.File.stderr().writer(&buf);
        defer self.alloc.destroy(writer);
        var stderr = &writer.interface;
        defer stderr.flush() catch @panic("failed to flush writer");
        try stderr.writeAll(msg);
        try stderr.writeByte('\n');

        switch (e) {
            TestError.PassFailed, error.AnalysisFailed => {
                for (self.diagnostics.items) |diagnostic| {
                    try self.fmt.format(stderr, diagnostic.err);
                    try stderr.writeByte('\n');
                }
                return e;
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

        var pass_errors = self.newList();
        defer pass_errors.deinit();

        self.lint(src, i, &pass_errors) catch |e| {
            if (self.diagnostic.message.borrow().len == 0) {
                self.diagnostic.message = Cow.fmt(
                    self.alloc,
                    "Expected test case #{d} to pass: {s}\n\n{s}",
                    .{ i + 1, @errorName(e), src },
                ) catch @panic("OOM");
            }
            try self.diagnostics.appendSlice(self.alloc, pass_errors.items);
            return LintTesterError.PassFailed;
        };
    }

    // Run fail cases
    i = 0;
    for (self.fails.items) |src| {
        defer i += 1;

        var fail_errors = self.newList();
        defer fail_errors.deinit();

        self.lint(src, i, &fail_errors) catch |e| {
            try self.diagnostics.appendSlice(self.alloc, fail_errors.items);
            switch (e) {
                error.LintingFailed => continue,
                else => {
                    return e;
                },
            }
        };

        if (fail_errors.items.len == 0) {
            self.diagnostic.message = Cow.fmt(
                self.alloc,
                "Expected test case #{d} to fail:\n\n{s}",
                .{ i + 1, src },
            ) catch @panic("OOM");
            return LintTesterError.FailPassed;
        }
    }

    // Run fix cases
    i = 0;
    self.linter.options.fix = Fix.Meta.safe_fix;
    for (self.fixes.items) |case| {
        defer i += 1;

        var fix_errors = self.newList();
        defer fix_errors.deinit();

        self.lint(case.src, i, &fix_errors) catch |e| {
            if (e != error.LintingFailed) {
                try self.diagnostics.appendSlice(self.alloc, fix_errors.items);
                if (self.diagnostic.message.borrow().len == 0) {
                    self.diagnostic.message = Cow.fmt(
                        self.alloc,
                        "Expected test case #{d} to provide fixable diagnsotics: {s}\n\n{s}",
                        .{ i + 1, @errorName(e), case.src },
                    ) catch @panic("OOM");
                }
                return e;
            }

            var fixer: Fixer = .{ .allocator = self.alloc };
            var fixed = try fixer.applyFixes(case.src, fix_errors.items);
            const unfixed = fixed.unfixed_errors.items;

            // TODO: check fix kind.

            if (unfixed.len > 0) {
                defer if (fixed.did_fix) fixed.source.deinit(self.alloc);
                try self.diagnostics.ensureUnusedCapacity(self.alloc, unfixed.len);
                for (unfixed) |err| {
                    self.diagnostics.appendAssumeCapacity(.{ .err = err });
                }
                self.diagnostic.message = Cow.fmt(
                    self.alloc,
                    "Expected case #{d} to produce only fixable violations, but some violations remained after fixing.\n\n{s}",
                    .{ i + 1, case.src },
                ) catch @panic("OOM");
                return error.FixFailed;
            }
            defer fixed.deinit(self.alloc);
            if (!fixed.did_fix) {
                self.diagnostic.message = Cow.fmt(
                    self.alloc,
                    "Expected case #{d} to fix rule violations, but no fixes were applied.\n\n{s}",
                    .{ i + 1, case.src },
                ) catch @panic("OOM");
                return error.FixMismatch;
            }

            if (!std.mem.eql(u8, case.expected, fixed.source.items)) {
                self.diagnostic.message = Cow.fmt(
                    self.alloc,
                    "Fixed source code in case #{d} did not match the expected text.\n\nExpected:\n{s}\n\nActual:\n{s}",
                    .{ i + 1, case.expected, fixed.source.items },
                ) catch @panic("OOM");
                return error.FixMismatch;
            }

            continue;
        };

        self.diagnostic.message = Cow.fmt(
            self.alloc,
            "Expected case #{d} to produce fixable violations, but linting passed.\n\n{s}",
            .{ i + 1, case.src },
        ) catch @panic("OOM");
        return error.FixPassed;
    }

    try self.saveSnapshot();
}

fn lint(
    self: *RuleTester,
    src: [:0]const u8,
    test_id: usize,
    errors: *Linter.Diagnostic.List,
) (Linter.LintError || Semantic.Builder.SemanticError || Allocator.Error)!void {
    // TODO: support static strings in Source w/o leaking memory.
    var source = try Source.fromString(
        self.alloc,
        try self.alloc.dupeZ(u8, src),
        try self.alloc.dupe(u8, self.filename),
    );
    defer source.deinit();

    var builder = Semantic.Builder.init(self.alloc);
    defer builder.deinit();
    builder.withSource(&source);

    var semantic_result = builder.build(source.text()) catch |e| {
        try errors.ensureUnusedCapacity(builder._errors.items.len);
        for (builder._errors.items) |err| {
            errors.appendAssumeCapacity(.{ .err = err });
        }
        return e;
    };

    // defer semantic_result.deinit();
    if (semantic_result.hasErrors()) {
        defer semantic_result.value.deinit();
        defer semantic_result.errors.deinit(self.alloc);
        self.diagnostic.message = Cow.fmt(
            self.alloc,
            "Test case #{} had semantic or parse errors\n\nSource:\n{s}\n",
            .{ test_id, src },
        ) catch @panic("OOM");

        try errors.ensureUnusedCapacity(builder._errors.items.len);
        for (semantic_result.errors.items) |err| {
            errors.appendAssumeCapacity(.{ .err = err });
        }

        return error.AnalysisFailed;
    }
    defer semantic_result.deinit();
    const semantic = semantic_result.value;

    return self.linter.runOnSource(&semantic, &source, @ptrCast(errors));
}

fn saveSnapshot(self: *RuleTester) SnapshotError!void {
    const snapshot_file: fs.File = brk: {
        var snapshot_dir = fs.cwd().makeOpenPath(SNAPSHOT_DIR, .{}) catch |e| {
            self.diagnostic.message = Cow.static("Failed to open snapshot directory '" ++ SNAPSHOT_DIR ++ "'");
            return e;
        };
        defer snapshot_dir.close();
        const snapshot_filename = try std.mem.concat(self.alloc, u8, &[_][]const u8{ self.rule.meta.name, ".snap" });
        defer self.alloc.free(snapshot_filename);
        const snapshot_file = snapshot_dir.createFile(snapshot_filename, .{ .truncate = true }) catch |e| {
            self.diagnostic.message = Cow.fmt(
                self.alloc,
                "Failed to open snapshot file '{s}'",
                .{snapshot_filename},
            ) catch @panic("OOM");
            return e;
        };
        break :brk snapshot_file;
    };
    defer snapshot_file.close();

    var buf: [8192]u8 = undefined;
    const writer = snapshot_file.writer(&buf);
    var w = writer.interface;
    
    // defer w.flush() catch |e| std.debug.panic("Failed to flush snapshot writer: {s}", .{@errorName(e)});
    for (self.diagnostics.items) |diagnostic| {
        try self.fmt.format(&w, diagnostic.err);
        try w.writeByte('\n');
    }
    
}

inline fn newList(self: *RuleTester) Linter.Diagnostic.List {
    return Linter.Diagnostic.List.init(self.alloc);
}

pub fn deinit(self: *RuleTester) void {
    self.linter.deinit();
    self.alloc.free(self.filename);
    self.passes.deinit(self.alloc);
    self.fails.deinit(self.alloc);
    self.fixes.deinit(self.alloc);
    self.diagnostic.message.deinit(self.alloc);

    for (0..self.diagnostics.items.len) |i| {
        var err = self.diagnostics.items[i];
        err.deinit(self.alloc);
    }
    self.diagnostics.deinit(self.alloc);
}

const TestDiagnostic = struct {
    /// Always static. Do not `free()`.
    message: Cow = Cow.static(""),
    // errors:
};

const std = @import("std");
const fs = std.fs;
const util = @import("util");

const Allocator = std.mem.Allocator;

const Linter = @import("linter.zig").Linter;
const Rule = @import("rule.zig").Rule;
const Fix = @import("fix.zig").Fix;
const Fixer = @import("fix.zig").Fixer;
const Semantic = @import("../Semantic.zig");
const Source = @import("../source.zig").Source;
const GraphicalFormatter = @import("../reporter.zig").formatter.Graphical;

const Cow = util.Cow(false);
const panic = std.debug.panic;

const NodeWrapper = @import("rule.zig").NodeWrapper;
const LinterContext = @import("lint_context.zig");
const MockRule = struct {
    pub const meta: Rule.Meta = .{
        .name = "unsafe-undefined",
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
