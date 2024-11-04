printer: *Printer,

pub fn new(printer: *Printer) SemanticPrinter {
    return SemanticPrinter{
        .printer = printer,
    };
}

pub fn printSymbolTable(self: *SemanticPrinter, symbols: *const Semantic.SymbolTable) !void {
    try self.printer.pushArray();
    defer self.printer.pop();

    var iter = symbols.iter();
    while (iter.next()) |id| {
        const symbol = symbols.get(id);
        try self.printSymbol(symbol, symbols);
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

pub fn printScopeTree(self: *SemanticPrinter, scopes: *const Semantic.ScopeTree) !void {
    return self.printScope(&scopes.scopes.items[Semantic.ROOT_SCOPE_ID], scopes);
}

fn printScope(self: *SemanticPrinter, scope: *const Semantic.Scope, scopes: *const Semantic.ScopeTree) !void {
    const p = self.printer;
    try p.pushObject();
    defer p.pop();

    try p.pProp("id", "{d}", scope.id);

    // try p.pPropJson("flags", scope.flags);
    {
        const f = scope.flags;
        try p.pPropName("flags");
        try p.pushArray();
        defer p.pop();
        try printStrIf(p, "top", f.s_top);
        try printStrIf(p, "function", f.s_function);
        try printStrIf(p, "struct", f.s_struct);
        try printStrIf(p, "enum", f.s_enum);
        try printStrIf(p, "union", f.s_union);
        try printStrIf(p, "block", f.s_block);
    }
    try p.pIndent();

    const children = &scopes.children.items[scope.id];
    if (children.items.len == 0) {
        try p.pPropName("children");
        try p.writer.print("[]", .{});
        p.pComma();
        try p.pIndent();
        return;
    }
    try p.pPropName("children");
    try p.pushArray();
    defer p.pop();
    for (children.items) |child_id| {
        const child = &scopes.scopes.items[child_id];
        try self.printScope(child, scopes);
    }
}

fn printStrIf(p: *Printer, str: []const u8, cond: bool) !void {
    if (!cond) {
        return;
    }
    try p.pString(str);
    p.pComma();
    try p.pIndent();
}

const SemanticPrinter = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Printer = @import("./Printer.zig");

const _semantic = @import("../semantic.zig");
const SemanticBuilder = _semantic.Builder;
const Semantic = _semantic.Semantic;
