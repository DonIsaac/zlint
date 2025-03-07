const std = @import("std");

const _source = @import("../../source.zig");
const SemanticBuilder = @import("../SemanticBuilder.zig");
const Semantic = @import("../Semantic.zig");
const report = @import("../../reporter.zig");

const printer = @import("../../root.zig").printer;

const t = std.testing;
const print = std.debug.print;

pub fn build(src: [:0]const u8) !Semantic {
    var r = try report.Reporter.graphical(
        std.io.getStdErr().writer().any(),
        t.allocator,
        report.formatter.Graphical.Theme.unicodeNoColor(),
    );
    defer r.deinit();
    var builder = SemanticBuilder.init(t.allocator);
    var source = try _source.Source.fromString(
        t.allocator,
        try t.allocator.dupeZ(u8, src),
        try t.allocator.dupe(u8, "test.zig"),
    );
    defer source.deinit();
    builder.withSource(&source);
    defer builder.deinit();

    var result = builder.build(src) catch |e| {
        print("Analysis failed on source:\n\n{s}\n\n", .{src});
        return e;
    };
    errdefer result.value.deinit();
    if (result.hasErrors()) {
        print("Analysis failed.\n", .{});
        r.reportErrors(result.errors.toManaged(t.allocator));
        print("\nSource:\n\n{s}\n\n", .{src});
        return error.AnalysisFailed;
    }

    return result.value;
}

pub fn debugSemantic(semantic: *const Semantic) !void {
    var p = printer.Printer.init(t.allocator, std.io.getStdErr().writer());
    defer p.deinit();
    var sp = printer.SemanticPrinter.new(&p, semantic);

    print("Symbol table:\n\n", .{});
    try sp.printSymbolTable();

    print("\n\nUnresolved references:\n\n", .{});
    try sp.printUnresolvedReferences();

    print("\n\nScopes:\n\n", .{});
    try sp.printScopeTree();
    print("\n\n", .{});

    print("\n\nModules:\n\n", .{});
    try sp.printModuleRecord();
    print("\n\n", .{});
}
