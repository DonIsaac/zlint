//! CLI options. Not necessarily linting-specific.

/// Enable verbose logging.
verbose: bool = false,
/// Instead of linting a file, print its AST as JSON to stdout.
///
/// This is primarily for debugging purposes.
print_ast: bool = false,
/// Positional arguments
args: std.ArrayListUnmanaged(util.string) = .{},

const ParseError = error{OutOfMemory};
pub fn parseArgv(alloc: Allocator) ParseError!Options {
    // NOTE: args() is not supported on WASM and windows. When targeting another
    // platform, argsWithAllocator does not actually allocate memory.
    var argv = try std.process.argsWithAllocator(alloc);
    defer argv.deinit();
    return parse(alloc, argv);
}

fn parse(alloc: Allocator, args_iter: anytype) ParseError!Options {
    var opts = Options{};
    var argv = args_iter;

    // skip binary name
    _ = argv.next() orelse {
        return opts;
    };
    while (argv.next()) |arg| {
        if (arg.len == 0) continue;
        if (arg[0] != '-') {
            try opts.args.append(alloc, arg);
            continue;
        }
        if (eq(arg, "-V") or eq(arg, "--verbose")) {
            opts.verbose = true;
        } else if (eq(arg, "--print-ast")) {
            opts.print_ast = true;
        } else if (eq(arg, "--")) {
            continue;
        } else {
            std.debug.panic("unknown option: {s}\n", .{arg});
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
// inline fn eq(arg: [:0]const u8, name: [:0]const u8) bool {
//     return std.mem.eql(u8, arg, name);
// }

const Options = @This();
const std = @import("std");
const util = @import("util");
const Allocator = std.mem.Allocator;

test parse {
    const t = std.testing;
    const List = std.ArrayListUnmanaged(util.string);
    const Case = std.meta.Tuple(&[_]type{ []const u8, Options });

    const src_list: List = brk: {
        const items = &[_]util.string{"src"};
        break :brk List{ .items = @constCast(items) };
    };
    const src_test_list: List = brk: {
        const items = &[_]util.string{ "src", "test" };
        break :brk List{ .items = @constCast(items) };
    };

    const test_cases = [_]Case{
        .{ "", .{} },
        .{ "zlint", .{} },
        .{ "zlint --", .{} },
        .{ "zlint --print-ast", .{ .print_ast = true } },
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
        const opts = try parse(std.heap.page_allocator, argv);

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
