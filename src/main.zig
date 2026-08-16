const std = @import("std");
const util = @import("util");
const Source = @import("zlint").Source;
const config = @import("config");
const Error = @import("zlint").Error;

const Io = std.Io;
const print = std.debug.print;

const Options = @import("cli/Options.zig");
const print_cmd = @import("cli/print_command.zig");
const lint_cmd = @import("cli/lint_command.zig");
const update_cmd = @import("cli/update_command.zig");

// in debug builds, include more information for debugging memory leaks,
// double-frees, etc.
const DebugAllocator = std.heap.DebugAllocator(.{
    .never_unmap = util.IS_DEBUG,
    .retain_metadata = util.IS_DEBUG,
});
var debug_allocator = DebugAllocator.init;
pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const alloc = if (comptime util.IS_DEBUG)
        debug_allocator.allocator()
    else
        std.heap.smp_allocator;

    defer if (comptime util.IS_DEBUG) {
        _ = debug_allocator.deinit();
    };
    var stack = std.heap.stackFallback(16, alloc);
    const stack_alloc = stack.get();

    const is_update = update_cmd.isCommand(stack_alloc, init.minimal.args) catch {
        std.debug.print("error: ran out of memory while parsing command-line arguments\n", .{});
        return 1;
    };
    if (is_update) {
        return update_cmd.run(
            alloc,
            io,
            init.minimal.args,
            init.minimal.environ,
            config.version,
        );
    }

    var err: Error = undefined;
    var opts = Options.parseArgv(stack_alloc, io, init.minimal.args, &err) catch |e| switch (e) {
        // These variants populate `err` with a user-facing message describing
        // exactly what went wrong (e.g. the unknown flag or invalid value).
        error.InvalidArg, error.InvalidArgValue => {
            std.debug.print("{s}\n{s}\n", .{ err.message.borrow(), Options.usage });
            err.deinit(stack_alloc);
            return 1;
        },
        // The remaining variants leave `err` undefined, so give the user a
        // clear message here instead of letting the runtime dump a stack trace.
        error.OutOfMemory => {
            std.debug.print("error: ran out of memory while parsing command-line arguments\n", .{});
            return 1;
        },
        error.WriteFailed, error.WriterError => {
            std.debug.print("error: failed to write to stdout\n", .{});
            return 1;
        },
    };
    defer opts.deinit(stack_alloc);

    if (opts.version) {
        var stdout = Io.File.stdout().writer(io, &.{});
        stdout.interface.print("{s}\n", .{config.version}) catch |e| {
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
        const file = try Io.Dir.cwd().openFile(io, relative_path, .{});
        errdefer file.close(io);
        var source = try Source.init(alloc, io, file, null);
        defer source.deinit();
        try print_cmd.parseAndPrint(alloc, io, opts, source, null);
        return 0;
    } else if (opts.print_cfg) {
        if (opts.args.items.len == 0) {
            print("No files to print\nUsage: zlint --print-cfg [filename]", .{});
            std.process.exit(1);
        }

        const relative_path = opts.args.items[0];
        const file = try Io.Dir.cwd().openFile(io, relative_path, .{});
        errdefer file.close(io);
        var source = try Source.init(alloc, io, file, null);
        defer source.deinit();
        try print_cmd.printCfg(alloc, io, opts, source, null);
        return 0;
    }

    return lint_cmd.lint(alloc, io, init.minimal.environ, opts);
}

test {
    // `src/cli/` and `src/io/` aren't part of the library surface, so their
    // tests are compiled and run from here.
    std.testing.refAllDecls(Options);
    std.testing.refAllDecls(lint_cmd);
    std.testing.refAllDecls(print_cmd);
    std.testing.refAllDecls(update_cmd);
    std.testing.refAllDecls(@import("cli/lint_config.zig"));
    std.testing.refAllDecls(@import("io/Walker.zig"));
    std.testing.refAllDecls(@import("io/glob.zig"));
}
