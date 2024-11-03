printer: *Printer,

pub fn new(printer: *Printer) SemanticPrinter {
    return SemanticPrinter{
        .printer = printer,
    };
}

pub fn printSymbolTable(self: *SemanticPrinter, symbols: *const Semantic.SymbolTable) !void {
    try self.printer.pushArray();
    defer self.printer.pop();

    var i: Semantic.Symbol.Id = 0;
    while (i < symbols.symbols.len) {
        const symbol = symbols.get(i);
        try self.printSymbol(symbol, symbols);
        i += 1;
    }
}

fn printSymbol(self: *SemanticPrinter, symbol: *const Semantic.Symbol, symbols: *const Semantic.SymbolTable) !void {
    try self.printer.pushObject();
    defer self.printer.pop();

    try self.printer.pPropStr("name", symbol.name);
    // try self.printer.pPropStr("kind", symbol.kind);
    try self.printer.pProp("declNode", "{d}", symbol.decl);
    // try self.printer.pPropStr("type", symbol.type);
    try self.printer.pProp("scope", "{d}", symbol.scope);
    try self.printer.pPropJson("flags", symbol.flags);
    try self.printer.pPropJson("members", symbols.getMembers(symbol.id).items);
    try self.printer.pPropJson("exports", symbols.getExports(symbol.id).items);
    // try self.printer.pPropStr("location", symbol.location);
}

const SemanticPrinter = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Printer = @import("./Printer.zig");

const _semantic = @import("../semantic.zig");
const SemanticBuilder = _semantic.Builder;
const Semantic = _semantic.Semantic;