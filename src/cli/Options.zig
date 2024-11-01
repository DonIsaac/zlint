verbose: bool = false,
print_ast: bool = false,

pub fn parseArgv() Options {
    var opts = Options{};
    var args = std.process.args();

    // skip binary name
    _ = args.next() orelse {
        return opts;
    };

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

inline fn eq(arg: [:0]const u8, name: [:0]const u8) bool {
    return std.mem.eql(u8, arg, name);
}

const Options = @This();
const std = @import("std");
