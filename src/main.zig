const std = @import("std");
const util = @import("util");
const Source = @import("source.zig").Source;
const config = @import("config");
const Error = @import("./Error.zig");

const fs = std.fs;
const print = std.debug.print;

const Options = @import("./cli/Options.zig");
const print_cmd = @import("cli/print_command.zig");
const lint_cmd = @import("cli/lint_command.zig");

// in debug builds, include more information for debugging memory leaks,
// double-frees, etc.
const DebugAllocator = std.heap.GeneralPurposeAllocator(.{
    .never_unmap = util.IS_DEBUG,
    .retain_metadata = util.IS_DEBUG,
});
var debug_allocator = DebugAllocator.init;
pub fn main() !u8 {
    const alloc = if (comptime util.IS_DEBUG)
        debug_allocator.allocator()
    else
        std.heap.smp_allocator;

    defer if (comptime util.IS_DEBUG) {
        _ = debug_allocator.deinit();
    };
    var stack = std.heap.stackFallback(16, alloc);
    const stack_alloc = stack.get();

    var err: Error = undefined;
    var opts = Options.parseArgv(stack_alloc, &err) catch {
        std.debug.print("{s}\n{s}\n", .{ err.message, Options.usage });
        err.deinit(stack_alloc);
        return 1;
    };
    defer opts.deinit(stack_alloc);

    if (opts.version) {
        const stdout = std.io.getStdOut().writer();
        stdout.print("{s}\n", .{config.version}) catch |e| {
            std.debug.panic("Failed to write version: {s}\n", .{@errorName(e)});
        };
        return 0;
    } else if (opts.print_ast) {
        if (opts.args.items.len == 0) {
            print("No files to print\nUsage: zlint --print-ast [filename]", .{});
            std.process.exit(1);
        }

        const relative_path = opts.args.items[0];
        print("Printing AST for {s}\n", .{relative_path});
        const file = try fs.cwd().openFile(relative_path, .{});
        errdefer file.close();
        var source = try Source.init(alloc, file, null);
        defer source.deinit();
        try print_cmd.parseAndPrint(alloc, opts, source);
        return 0;
    }

    return lint_cmd.lint(alloc, opts);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(@import("visit/walk.zig"));
    std.testing.refAllDecls(@import("json.zig"));
}
