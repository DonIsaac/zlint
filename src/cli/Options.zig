//! CLI options. Not necessarily linting-specific.

/// Enable verbose logging.
verbose: bool = false,
/// Instead of linting a file, print its AST as JSON to stdout.
///
/// This is primarily for debugging purposes.
print_ast: bool = false,
/// Positional arguments
args: std.ArrayListUnmanaged(util.string) = .{},

pub fn parseArgv(alloc: std.mem.Allocator) Options {
    var opts = Options{};
    var argv = std.process.args();

    // skip binary name
    _ = argv.next() orelse {
        return opts;
    };
    while (argv.next()) |arg| {
        if (arg.len == 0) continue;
        if (arg[0] != '-') {
            opts.args.append(alloc, arg) catch @panic("OOM");
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

inline fn eq(arg: [:0]const u8, name: [:0]const u8) bool {
    return std.mem.eql(u8, arg, name);
}

const Options = @This();
const std = @import("std");
const util = @import("util");
