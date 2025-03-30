//! CLI options. Not necessarily linting-specific.

/// Any number of warnings should cause zlint to exit with a non-zero status
/// code.
deny_warnings: bool = false,
/// Enable verbose logging.
verbose: bool = false,
/// Print version and exit.
version: bool = false,
/// Only display errors. Warnings are counted but not shown.
quiet: bool = false,
/// Instead of linting a file, print its AST as JSON to stdout.
///
/// This is primarily for debugging purposes.
print_ast: bool = false,
/// How diagnostics are formatted.
format: formatter.Kind = .graphical,
/// Print a summary about # of warnings and errors. Only applies for some formats.
summary: bool = true,
/// Instead of walking directories in cwd, read names of files to lint from stdin.
/// If relative, paths are resolved from the cwd.
stdin: bool = false,
/// enable auto fixes
fix: bool = false,
/// Like `--fix`, but also enable potentially dangerous fixes.
fix_dangerously: bool = false,
/// Positional arguments
args: std.ArrayListUnmanaged([]const u8) = .{},

pub const usage =
    \\Usage: zlint [options] [<dirs>]
;
const help =
    \\--print-ast <file>  Parse a file and print its AST as JSON
    \\-f, --format <fmt>  Choose an output format (default, graphical, github, gh)
    \\--no-summary        Do not print a summary after linting
    \\-S, --stdin         Lint filepaths received from stdin (newline separated)
    \\--fix               Apply automatic fixes where possible
    \\--fix-dangerously   Like --fix, but also enable potentially dangerous fixes
    \\--deny-warnings     Warnings produce a non-zero exit code
    \\-q, --quiet         Only display error diagnostics
    \\-V, --verbose       Enable verbose logging   
    \\-v, --version       Print version and exit
    \\-h, --help          Show this help message
;
const ParseError = error{
    OutOfMemory,
    InvalidArg,
    InvalidArgValue,
} || @TypeOf(std.io.getStdOut().writer()).Error;
pub fn parseArgv(alloc: Allocator, err: ?*Error) ParseError!Options {
    // NOTE: args() is not supported on WASM and windows. When targeting another
    // platform, argsWithAllocator does not actually allocate memory.
    var argv = try std.process.argsWithAllocator(alloc);
    defer argv.deinit();
    return parse(alloc, argv, err);
}

fn parse(alloc: Allocator, args_iter: anytype, err: ?*Error) ParseError!Options {
    var argv = args_iter;
    var opts = Options{};
    errdefer opts.deinit(alloc);

    // skip binary name
    _ = argv.next() orelse return opts;
    while (argv.next()) |arg| {
        if (arg.len == 0) continue;
        if (arg[0] != '-') {
            try opts.args.append(alloc, arg);
            continue;
        }
        if (eq(arg, "--fix")) {
            opts.fix = true;
        } else if (eq(arg, "--fix-dangerously")) {
            opts.fix_dangerously = true;
            opts.fix = true;
        } else if (eq(arg, "-q") or eq(arg, "--quiet")) {
            opts.quiet = true;
        } else if (eq(arg, "-V") or eq(arg, "--verbose")) {
            opts.verbose = true;
        } else if (eq(arg, "-v") or eq(arg, "--version")) {
            opts.version = true;
        } else if (eq(arg, "--deny-warnings")) {
            opts.deny_warnings = true;
        } else if (eq(arg, "-S") or eq(arg, "--stdin")) {
            opts.stdin = true;
        } else if (eq(arg, "-f") or eq(arg, "--format")) {
            // TODO: comptime string concat on format names
            const fmt = argv.next() orelse {
                if (err) |e| {
                    e.* = Error.fmt(alloc, "Invalid format name: {s}. Valid names are {s}.", .{ arg, FORMAT_NAMES }) catch @panic("OOM");
                }
                return error.InvalidArg;
            };
            opts.format = formatter.Kind.fromString(fmt) orelse {
                if (err) |e| {
                    e.* = Error.fmt(alloc, "Invalid format name: {s}. Valid names are {s}.", .{ arg, FORMAT_NAMES }) catch @panic("OOM");
                }
                return error.InvalidArgValue;
            };
        } else if (eq(arg, "--no-summary")) {
            opts.summary = false;
        } else if (eq(arg, "--print-ast")) {
            opts.print_ast = true;
        } else if (eq(arg, "-h") or eq(arg, "--help") or eq(arg, "--hlep") or eq(arg, "-help")) {
            const stdout = std.io.getStdOut().writer();
            try stdout.writeAll(usage);
            try stdout.writeBytesNTimes(util.NEWLINE, 2);
            try stdout.writeAll(help);
            try stdout.writeAll(util.NEWLINE);
            std.process.exit(0);
        } else if (eq(arg, "--")) {
            continue;
        } else {
            if (err) |e| {
                e.* = Error.fmt(alloc, "unknown option: {s}\n", .{arg}) catch @panic("OOM");
            }
            return error.InvalidArg;
        }
    }

    return opts;
}

pub fn deinit(self: *Options, alloc: std.mem.Allocator) void {
    self.args.deinit(alloc);
}

inline fn eq(arg: anytype, name: @TypeOf(arg)) bool {
    return std.mem.eql(u8, arg, name);
}
// TODO: comptime string concat on format names
const FORMAT_NAMES: []const u8 = "default, graphical, github, gh";

const Options = @This();
const std = @import("std");
const util = @import("util");
const Allocator = std.mem.Allocator;
const formatter = @import("../reporter.zig").formatter;
const Error = @import("../Error.zig");

const t = std.testing;

test parse {
    const List = std.ArrayListUnmanaged([]const u8);
    const Case = std.meta.Tuple(&[_]type{ []const u8, Options });

    const src_list: List = brk: {
        const items = &[_][]const u8{"src"};
        break :brk List{ .items = @constCast(items) };
    };
    const src_test_list: List = brk: {
        const items = &[_][]const u8{ "src", "test" };
        break :brk List{ .items = @constCast(items) };
    };

    const test_cases = [_]Case{
        .{ "", .{} },
        .{ "zlint", .{} },
        .{ "zlint --", .{} },
        .{ "zlint --print-ast", .{ .print_ast = true } },
        .{ "zlint --fix", .{ .fix = true } },
        .{ "zlint --no-summary", .{ .summary = false } },
        .{ "zlint --verbose", .{ .verbose = true } },
        .{ "zlint -V", .{ .verbose = true } },
        .{ "zlint --verbose --print-ast", .{ .verbose = true, .print_ast = true } },
        .{ "zlint src -V", .{ .verbose = true, .args = src_list } },
        .{ "zlint -V src", .{ .verbose = true, .args = src_list } },
        .{ "zlint -V -- src", .{ .verbose = true, .args = src_list } },
        .{ "zlint -V src test ", .{ .verbose = true, .args = src_test_list } },
        .{ "zlint -V -- src test ", .{ .verbose = true, .args = src_test_list } },
        .{ "zlint src -V test", .{ .verbose = true, .args = src_test_list } },
    };

    for (test_cases) |test_case| {
        const argv = std.mem.splitScalar(u8, test_case[0], ' ');
        const expected: Options = test_case[1];
        var opts = try parse(t.allocator, argv, null);
        defer opts.deinit(t.allocator);

        try t.expectEqual(expected.verbose, opts.verbose);
        try t.expectEqual(expected.print_ast, opts.print_ast);
        try t.expectEqual(expected.args.items.len, opts.args.items.len);
        for (0..expected.args.items.len) |i| {
            try t.expectEqualStrings(
                expected.args.items[i],
                opts.args.items[i],
            );
        }
    }
}

test "invalid --format" {
    var err: Error = undefined;
    const argv = std.mem.splitScalar(u8, "zlint --format this-is-not-a-valid-format", ' ');
    defer err.deinit(t.allocator);
    try t.expectError(
        error.InvalidArgValue,
        parse(t.allocator, argv, &err),
    );
    try t.expect(std.mem.indexOf(u8, err.message.borrow(), "Invalid format name") != null);
}
