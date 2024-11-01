const std = @import("std");
const builtin = @import("builtin");
const lint = @import("lint.zig");
const Source = @import("source.zig").Source;
const semantic = @import("semantic.zig");
const print_cmd = @import("cmd/print_command.zig");
const Options = @import("cli/Options.zig");

const fs = std.fs;
const path = std.path;
const assert = std.debug.assert;
const print = std.debug.print;

const Ast = std.zig.Ast;
const Linter = lint.Linter;

const IS_DEBUG = builtin.mode == .Debug;

pub fn main() !void {
    // in debug builds, include more information for debugging memory leaks,
    // double-frees, etc.
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .never_unmap = IS_DEBUG,
        .retain_metadata = IS_DEBUG,
    }){};

    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const opts = Options.parseArgv();

    print("opening foo.zig\n", .{});
    const file = try fs.cwd().openFile("fixtures/foo.zig", .{});
    var source = try Source.init(alloc, file);
    defer source.deinit();

    if (opts.print_ast) {
        return print_cmd.parseAndPrint(alloc, opts, source);
    }

    var linter = Linter.init(alloc);
    defer linter.deinit();

    var errors = try linter.runOnSource(&source);
    for (errors.items) |err| {
        print("{s}\n", .{err.message});
    }
    errors.deinit();
}

test {
    std.testing.refAllDecls(@This());
}
