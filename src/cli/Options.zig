//! CLI options. Not necessarily linting-specific.

/// Enable verbose logging.
verbose: bool = false,
/// Instead of linting a file, print its AST as JSON to stdout.
///
/// This is primarily for debugging purposes.
print_ast: bool = false,

args: std.ArrayListUnmanaged([:0]const u8) = .{},

pub fn parseArgv(alloc: Allocator) Options {
    var opts = Options{};
    var args = std.process.args();

    // skip binary name
    _ = args.next() orelse {
        return opts;
    };

    while (args.next()) |arg| {
        if (arg.len == 0) continue;

        if (arg[0] != '-') {
            opts.args.append(alloc, arg) catch @panic("Could not add CLI option: out of memory.");
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

    while (true) {
        const arg: [:0]const u8 = args.next() orelse {
            return opts;
        };
        if (eq(arg, "-V") or eq(arg, "--verbose")) {
            opts.verbose = true;
        } else if (eq(arg, "--print-ast")) {
            opts.print_ast = true;
        } else {
            std.debug.panic("unknown option: {s}\n", .{arg});
        }
    }

    return opts;
}

pub fn deinit(self: *Options, alloc: Allocator) void {
    self.args.deinit(alloc);
}

inline fn eq(arg: [:0]const u8, name: [:0]const u8) bool {
    return std.mem.eql(u8, arg, name);
}

const Options = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
