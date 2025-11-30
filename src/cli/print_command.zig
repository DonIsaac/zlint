//! Hacky AST printer for debugging purposes.
//!
//! Resolves AST nodes and prints them as JSON. This can be safely piped into a file, since `std.debug.print` writes to stderr.
//!
//! ## Usage
//! ```sh
//! # note: right now, no target file can be specified. Run
//! zig build run -- --print-ast | prettier --stdin-filepath foo.ast.json > tmp/foo.ast.json
//! ```
const std = @import("std");
const io = std.io;
const Allocator = std.mem.Allocator;

const Options = @import("../cli/Options.zig");
const Source = @import("../source.zig").Source;
const Semantic = @import("../Semantic.zig");

const Printer = @import("../printer/Printer.zig");
const AstPrinter = @import("../printer/AstPrinter.zig");
const SemanticPrinter = @import("../printer/SemanticPrinter.zig");

/// Borrows source.
pub fn parseAndPrint(alloc: Allocator, opts: Options, source: Source, writer_: ?*io.Writer) !void {
    var buf: [4096]u8 = undefined;
    var builder = Semantic.Builder.init(alloc);
    defer builder.deinit();
    var sema_result = try builder.build(source.text());
    defer sema_result.deinit();
    if (sema_result.hasErrors()) {
        for (sema_result.errors.items) |err| {
            std.debug.print("{s}\n", .{err.message.str});
        }
        return;
    }
    const sema = &sema_result.value;
    var stdout: ?std.fs.File.Writer = null;
    defer if (stdout) |*out| out.interface.flush() catch @panic("failed to flush writer");
    var writer = writer_ orelse blk: {
        stdout = std.fs.File.stdout().writer(&buf);
        break :blk &stdout.?.interface;
    };
    defer writer.flush() catch @panic("failed to flush writer");
    var printer = Printer.init(alloc, writer);
    defer printer.deinit();
    var ast_printer = AstPrinter.new(&printer, .{ .verbose = opts.verbose }, source, &sema.parse.ast);
    ast_printer.setNodeLinks(&sema.node_links);
    var semantic_printer = SemanticPrinter.new(&printer, &sema_result.value);

    try printer.pushObject();
    defer printer.pop();
    try printer.pPropName("ast");
    try ast_printer.printAst();
    try printer.pPropName("symbols");
    try semantic_printer.printSymbolTable();
    try printer.pPropName("scopes");
    try semantic_printer.printScopeTree();
    try printer.pPropName("modules");
    try semantic_printer.printModuleRecord();
}

test {
    _ = @import("test/print_ast_test.zig");
}
