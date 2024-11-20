const std = @import("std");
const mem = std.mem;

const SemanticBuilder = @import("../SemanticBuilder.zig");
const Semantic = @import("../Semantic.zig");
const report = @import("../../reporter.zig");

const printer = @import("../../root.zig").printer;

const t = std.testing;
const panic = std.debug.panic;
const print = std.debug.print;

pub fn build(src: [:0]const u8) !Semantic {
    var r = report.GraphicalReporter.init(std.io.getStdErr().writer(), report.GraphicalFormatter.unicode(t.allocator, false));
    var builder = SemanticBuilder.init(t.allocator);
    defer builder.deinit();

    var result = builder.build(src) catch |e| {
        print("Analysis failed on source:\n\n{s}\n\n", .{src});
        return e;
    };
    errdefer result.value.deinit();
    r.reportErrors(result.errors.toManaged(t.allocator));
    if (result.hasErrors()) {
        panic("Analysis failed on source:\n\n{s}\n\n", .{src});
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
}
