const test_runner = @import("../harness.zig");
const std = @import("std");
const zlint = @import("zlint");
const utils = @import("../utils.zig");

const Allocator = std.mem.Allocator;
const SemanticError = @import("ecosystem_coverage.zig").SemanticError; // TODO: move to shared file
const string = utils.string;
const TestFolders = utils.TestFolders;
const Printer = zlint.printer.Printer;
const AstPrinter = zlint.printer.AstPrinter;
const SemanticPrinter = zlint.printer.SemanticPrinter;

// var pass_fixtures: *std.fs.Dir = undefined;

const Error = error {
    /// Parsing or semantic analysis failed.
    analysis_failed,
    /// The walker produced a source without a filename.
    source_missing_filename
};

fn run(alloc: Allocator) !void {
    var pass_fixtures = try std.fs.cwd().openDir("test/fixtures/simple/pass", .{ .iterate = true });
    defer pass_fixtures.close();
    var suite = try test_runner.TestSuite.init(alloc, pass_fixtures, "snapshot-coverage/simple", "pass", &runPass, null);
    return suite.run();
}

fn runPass(alloc: Allocator, source: *const zlint.Source) anyerror!void {
    // run analysis
    var semantic_result = try zlint.semantic.Builder.build(alloc, source.contents);
    defer semantic_result.deinit();
    if (semantic_result.hasErrors()) {
        return Error.analysis_failed;
    }
    const semantic = semantic_result.value;

    // open (and maybe create) source-local snapshot file
    if (source.pathname == null) {
        return Error.source_missing_filename;
    }
    const source_name = try alloc.allocSentinel(u8, source.pathname.?.len, 0);
    defer alloc.free(source_name);
    _ = std.mem.replace(u8, source.pathname.?, std.fs.path.sep_str, "-", source_name);
    const snapshot = try TestFolders.openSnapshotFile(alloc, "snapshot-coverage/simple/pass", source_name);
    defer snapshot.close();

    var printer = zlint.printer.Printer.init(alloc, snapshot.writer());
    var sem_printer = SemanticPrinter.new(&printer);
    defer printer.deinit();

    try printer.pushObject();
    try printer.pPropName("symbols");
    try sem_printer.printSymbolTable(&semantic.symbols);
    printer.pop();

    return;
}

pub const SUITE = test_runner.TestFile{
    .name = "snapshot_coverage",
    .run = run,
};
