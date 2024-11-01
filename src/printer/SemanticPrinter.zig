printer: *Printer,

pub fn new(printer: *Printer) SemanticPrinter {
    return SemanticPrinter{
        .printer = printer,
    };
}

pub fn printSymbolTable(self: *SemanticPrinter, symbols: *const Semantic.SymbolTable) !void {
    try self.printer.pushArray();
    defer self.printer.pop();

    for (symbols.symbols.items) |symbol| {
        try self.printSymbol(&symbol);
    }
}

fn printSymbol(self: *SemanticPrinter, symbol: *const Semantic.Symbol) !void {
    try self.printer.pushObject();
    defer self.printer.pop();

    try self.printer.pPropStr("name", symbol.name);
    // try self.printer.pPropStr("kind", symbol.kind);
    try self.printer.pProp("declNode", "{d}", symbol.decl);
    // try self.printer.pPropStr("type", symbol.type);
    try self.printer.pProp("scope", "{d}", symbol.scope);
    try self.printer.pPropJson("flags", symbol.flags);
    // try self.printer.pPropStr("location", symbol.location);
}

const SemanticPrinter = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Printer = @import("./Printer.zig");

const _semantic = @import("../semantic.zig");
const SemanticBuilder = _semantic.Builder;
const Semantic = _semantic.Semantic;
