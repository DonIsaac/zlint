const test_runner = @import("../harness.zig");
const std = @import("std");
const zlint = @import("zlint");
const utils = @import("../utils.zig");

const Allocator = std.mem.Allocator;
const TestFolders = utils.TestFolders;

const Printer = zlint.printer.Printer;
const SemanticPrinter = zlint.printer.SemanticPrinter;

const SemanticBuilder = zlint.semantic.SemanticBuilder;

const FailError = error{
    ExpectedSemanticFailure,
};
const Error = error{
    // The walker produced a source without a filename.
    SourceMissingFilename,
} || FailError || SemanticBuilder.SemanticError || Allocator.Error;

fn run(alloc: Allocator) !void {
    const Suite = std.meta.Tuple(&[_]type{ []const u8, *const test_runner.TestSuite.TestFn });
    inline for (.{
        Suite{ "pass", &runPass },
        Suite{ "fail", &runFail },
    }) |suite_inputs| {
        const suite_name, const suite_run_fn = suite_inputs;

        var fixtures = try std.fs.cwd().openDir(
            "test/fixtures/simple/" ++ suite_name,
            .{ .iterate = true },
        );
        defer fixtures.close();

        var suite = try test_runner.TestSuite.init(
            alloc,
            fixtures,
            "snapshot-coverage/simple",
            suite_name,
            .{ .test_fn = suite_run_fn },
        );
        try suite.run();
    }
    // var pass_fixtures = try std.fs.cwd().openDir("test/fixtures/simple/pass", .{ .iterate = true });
    // defer pass_fixtures.close();

    // var pass_suite = try test_runner.TestSuite.init(alloc, pass_fixtures, "snapshot-coverage/simple", "pass", .{ .test_fn = &runPass });
    // return pass_suite.run();
}

fn runPass(alloc: Allocator, source: *const zlint.Source) anyerror!void {
    // run analysis
    var builder = SemanticBuilder.init(alloc);
    defer builder.deinit();
    var semantic_result = try builder.build(source.text());
    defer semantic_result.deinit();
    if (semantic_result.hasErrors()) {
        return error.AnalysisFailed;
    }
    const semantic = semantic_result.value;

    // open (and maybe create) source-local snapshot file
    if (source.pathname == null) {
        return Error.SourceMissingFilename;
    }
    const source_name = try alloc.allocSentinel(u8, source.pathname.?.len, 0);
    defer alloc.free(source_name);
    _ = std.mem.replace(u8, source.pathname.?, std.fs.path.sep_str, "-", source_name);
    const snapshot = try TestFolders.openSnapshotFile(alloc, "snapshot-coverage/simple/pass", utils.cleanStrSlice(source_name));
    defer snapshot.close();

    var printer = Printer.init(alloc, snapshot.writer());
    var sem_printer = SemanticPrinter.new(&printer, &semantic);
    defer printer.deinit();

    try printer.pushObject();
    try printer.pPropName("symbols");
    try sem_printer.printSymbolTable();
    try printer.pIndent();

    try printer.pPropName("unresolvedReferences");
    try sem_printer.printUnresolvedReferences();
    try printer.pIndent();

    try printer.pPropName("scopes");
    try sem_printer.printScopeTree();
    printer.pop();

    return;
}

fn runFail(alloc: Allocator, source: *const zlint.Source) anyerror!void {

    // open (and maybe create) source-local snapshot file
    if (source.pathname == null) return Error.SourceMissingFilename;
    const source_name = try alloc.allocSentinel(u8, source.pathname.?.len, 0);
    defer alloc.free(source_name);
    _ = std.mem.replace(u8, source.pathname.?, std.fs.path.sep_str, "-", source_name);

    const snapshot = try TestFolders.openSnapshotFile(alloc, "snapshot-coverage/simple/fail", utils.cleanStrSlice(source_name));
    defer snapshot.close();

    const formatter = zlint.report.formatter.Graphical.unicode(alloc, false);
    var reporter = try zlint.report.Reporter.init(@TypeOf(formatter), formatter, snapshot.writer(), alloc);
    defer reporter.deinit();

    // run analysis
    var builder = SemanticBuilder.init(alloc);
    builder.withSource(source);
    defer builder.deinit();

    var semantic_result: SemanticBuilder.Result = builder.build(source.text()) catch {
        reporter.reportErrorSlice(alloc, builder._errors.items);
        builder._errors.deinit(alloc);
        return;
    };
    if (semantic_result.hasErrors()) {
        reporter.reportErrorSlice(alloc, semantic_result.errors.items);
        builder._errors.deinit(alloc);
        semantic_result.value.deinit();
        return;
    }
    defer semantic_result.deinit();
    return FailError.ExpectedSemanticFailure;
}

pub const SUITE = test_runner.TestFile{
    .name = "snapshot_coverage",
    .run = run,
};
