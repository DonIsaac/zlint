const std = @import("std");
const builtin = @import("builtin");
const lint = @import("linter.zig");
const util = @import("util");
const Source = @import("source.zig").Source;
const semantic = @import("semantic.zig");
const Options = @import("./cli/Options.zig");

const fs = std.fs;
const path = std.path;
const assert = std.debug.assert;
const print = std.debug.print;

const Ast = std.zig.Ast;
const Linter = lint.Linter;

const print_cmd = @import("cmd/print_command.zig");
const lint_cmd = @import("cmd/lint_command.zig");

pub fn main() !void {
    // in debug builds, include more information for debugging memory leaks,
    // double-frees, etc.
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .never_unmap = util.IS_DEBUG,
        .retain_metadata = util.IS_DEBUG,
    }){};

    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const opts = Options.parseArgv();

    // While under development, I'm unconditionally linting fixtures/foo.zig.
    // I'll add file walking later.
    print("opening top_level_struct.zig\n", .{});
    const file = try fs.cwd().openFile("test/fixtures/simple/pass/top_level_struct.zig", .{});
    var source = try Source.init(alloc, file, null);
    defer source.deinit();

    if (opts.print_ast) {
        @panic("todo: re-enable print command");
        // return print_cmd.parseAndPrint(alloc, opts, source);
    }

    try lint_cmd.lint(alloc, opts);
}

test {
    std.testing.refAllDecls(@This());
}
