printer: *Printer,
semantic: *const Semantic,
alloc: Allocator,

pub fn new(printer: *Printer, semantic: *const Semantic) SemanticPrinter {
    return SemanticPrinter{
        .printer = printer,
        .semantic = semantic,
        .alloc = semantic._gpa,
    };
}

pub fn printSymbolTable(self: *SemanticPrinter) !void {
    const symbols = &self.semantic.symbols;
    try self.printer.pushArray();
    defer self.printer.pop();

    var iter = symbols.iter();
    while (iter.next()) |id| {
        const symbol = symbols.get(id);
        try self.printSymbol(symbol, symbols);
        if (id.int() + 1 != symbols.symbols.len) {
            try self.printer.pIndent();
        }
    }
}

fn printSymbol(self: *SemanticPrinter, symbol: *const Semantic.Symbol, symbols: *const Semantic.SymbolTable) !void {
    try self.printer.pushObject();
    defer self.printer.pop();

    try self.printer.pPropStr("name", symbol.name);
    try self.printer.pPropStr("debugName", symbol.debug_name);
    const decl = self.semantic.ast.nodes.items(.tag)[symbol.decl];
    try self.printer.pPropWithNamespacedValue("declNode", decl);
    try self.printer.pProp("scope", "{d}", symbol.scope);
    try self.printer.pPropJson("flags", symbol.flags);

    {
        try self.printer.pPropName("references");
        try self.printer.pushArray();
        defer {
            self.printer.pop();
            self.printer.pIndent() catch @panic("print failed");
        }
        for (symbol.references.items) |ref_id| {
            try self.printReference(ref_id);
            self.printer.pComma();
            try self.printer.pIndent();
        }
    }

    try self.printer.pPropJson("members", @as([]u32, @ptrCast(symbols.getMembers(symbol.id).items)));
    try self.printer.pPropJson("exports", @as([]u32, @ptrCast(symbols.getExports(symbol.id).items)));
}

pub fn printUnresolvedReferences(self: *SemanticPrinter) !void {
    const p = self.printer;
    const symbols = &self.semantic.symbols;

    if (symbols.unresolved_references.items.len == 0) {
        try p.print("[],", .{});
        return;
    }

    try p.pushArray();
    defer p.pop();
    for (symbols.unresolved_references.items) |ref_id| {
        try self.printReference(ref_id);
        self.printer.pComma();
        try self.printer.pIndent();
    }
}

fn printReference(self: *SemanticPrinter, ref_id: Reference.Id) !void {
    const ref = self.semantic.symbols.getReference(ref_id);
    const tags = self.semantic.ast.nodes.items(.tag);

    const sid: ?Symbol.Id.Repr = if (ref.symbol.unwrap()) |id| id.int() else null;
    const printable = PrintableReference{
        .symbol = sid,
        .scope = ref.scope.int(),
        .node = tags[ref.node],
        .identifier = ref.identifier,
        .flags = ref.flags,
    };
    try self.printer.pJson(printable);
}

pub fn printScopeTree(self: *SemanticPrinter) !void {
    return self.printScope(&self.semantic.scopes.getScope(Semantic.ROOT_SCOPE_ID));
}

const StackAllocator = std.heap.StackFallbackAllocator(1024);
fn printScope(self: *SemanticPrinter, scope: *const Semantic.Scope) !void {
    const scopes = &self.semantic.scopes;
    const symbols = &self.semantic.symbols;
    const bound_names = symbols.symbols.items(.name);
    const debug_names = symbols.symbols.items(.debug_name);

    const p = self.printer;

    try p.pushObject();
    defer p.pop();

    try p.pProp("id", "{d}", scope.id);

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
        try printStrIf(p, "comptime", f.s_comptime);
        try printStrIf(p, "catch", f.s_catch);
    }
    try p.pIndent();

    {
        try p.pPropName("bindings");
        try p.pushObject();
        defer p.popIndent();
        // var bindings = std.StringHashMap(Symbol.Id).init(fixed_alloc.get());
        // defer bindings.deinit();
        for (scopes.bindings.items[scope.id.int()].items) |id| {
            const i = id.int();
            var name = bound_names[i];
            if (name.len == 0) {
                name = debug_names[i];
            }
            try p.pProp(name, "{d}", i);
        }
    }

    const children = &scopes.children.items[scope.id.int()];
    if (children.items.len == 0) {
        try p.pPropName("children");
        try p.writer.print("[]", .{});
        p.pComma();
        try p.pIndent();
        return;
    }
    try p.pPropName("children");
    try p.pushArray();
    defer p.popIndent();
    for (children.items) |child_id| {
        const child = &scopes.getScope(child_id);
        try self.printScope(child);
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

const PrintableReference = struct {
    symbol: ?Symbol.Id.Repr,
    scope: Scope.Id.Repr,
    node: Node.Tag,
    identifier: []const u8,
    flags: Reference.Flags,
};

const SemanticPrinter = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Printer = @import("./Printer.zig");

const _semantic = @import("../semantic.zig");
const SemanticBuilder = _semantic.Builder;
const Semantic = _semantic.Semantic;
const Symbol = _semantic.Symbol;
const Scope = _semantic.Scope;
const Reference = _semantic.Reference;
const Node = std.zig.Ast.Node;
