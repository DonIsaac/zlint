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

pub fn printModuleRecord(self: *SemanticPrinter) !void {
    try self.printer.pushObject();
    defer self.printer.pop();

    try self.printer.pPropName("imports");
    {
        const imports = self.semantic.modules.imports;
        try if (imports.items.len > 0) self.printer.pushArray(true) else self.printer.pushArray(false);
        defer self.printer.pop();

        for (imports.items, 0..) |import, i| {
            try self.printImport(import);
            if (i + 1 != imports.items.len) {
                self.printer.pComma();
                try self.printer.pIndent();
            }
        }
    }
}

fn printImport(self: *SemanticPrinter, import: Semantic.ModuleRecord.ImportEntry) !void {
    const p = self.printer;
    try p.pushObject();
    defer p.pop();
    try p.pPropStr("specifier", import.specifier);
    try p.pProp("node", "{d}", import.node);
    try p.pPropWithNamespacedValue("kind", import.kind);
}

pub fn printSymbolTable(self: *SemanticPrinter) !void {
    const symbols = &self.semantic.symbols;
    try self.printer.pushArray(true);
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

fn printSymbol(self: *SemanticPrinter, symbol: *const Semantic.Symbol, symbols: *const Semantic.Symbol.Table) !void {
    const p = self.printer;
    try p.pushObject();
    defer p.pop();

    try p.pPropStr("name", symbol.name);
    try p.pPropStr("debugName", symbol.debug_name);
    try p.pProp("token", "{any}", if (symbol.token.unwrap()) |t| t.int() else null);
    const decl = self.semantic.parse.ast.nodes.items(.tag)[symbol.decl];
    try p.pPropWithNamespacedValue("declNode", decl);
    try p.pProp("scope", "{d}", symbol.scope);
    {
        try p.pPropName("flags");
        try p.pJson(symbol.flags);
        p.pComma();
        try p.pIndent();
    }

    {
        try p.pPropName("references");
        try p.pushArray(true);
        defer {
            p.pop();
            p.pIndent() catch @panic("print failed");
        }
        for (symbol.references.items) |ref_id| {
            try self.printReference(ref_id);
            p.pComma();
            try p.pIndent();
        }
    }

    try p.pPropJson("members", @as([]u32, @ptrCast(symbols.getMembers(symbol.id).items)));
    try p.pPropJson("exports", @as([]u32, @ptrCast(symbols.getExports(symbol.id).items)));
}

pub fn printUnresolvedReferences(self: *SemanticPrinter) !void {
    const p = self.printer;
    const symbols = &self.semantic.symbols;

    if (symbols.unresolved_references.items.len == 0) {
        try p.print("[],", .{});
        return;
    }

    try p.pushArray(true);
    defer p.pop();
    for (symbols.unresolved_references.items) |ref_id| {
        try self.printReference(ref_id);
        self.printer.pComma();
        try self.printer.pIndent();
    }
}

fn printReference(self: *SemanticPrinter, ref_id: Reference.Id) !void {
    const ast = &self.semantic.parse.ast;
    const ref = self.semantic.symbols.getReference(ref_id);
    const tags = ast.nodes.items(.tag);

    const flag_fields = std.meta.fields(Reference.Flags);
    var buf: [flag_fields.len * @sizeOf([]const u8)]u8 = undefined;
    var fixed_alloc = std.heap.FixedBufferAllocator.init(&buf);
    const alloc = fixed_alloc.allocator();
    var flags = std.ArrayList([]const u8).init(alloc);
    flags.ensureTotalCapacityPrecise(flag_fields.len) catch @panic("fixed buffer is not large enough.");

    inline for (flag_fields) |field| {
        const f = @field(ref.flags, field.name);
        if (@TypeOf(f) == bool and f) {
            flags.appendAssumeCapacity(field.name);
        }
    }

    const sid: ?Symbol.Id.Repr = if (ref.symbol.unwrap()) |id| id.int() else null;
    const printable = PrintableReference{
        .symbol = sid,
        .scope = ref.scope.int(),
        .node = tags[ref.node],
        .identifier = ref.identifier,
        .flags = flags.items,
    };
    try self.printer.pJson(printable);
}

pub fn printScopeTree(self: *SemanticPrinter) !void {
    return self.printScope(&self.semantic.scopes.getScope(Semantic.ROOT_SCOPE_ID));
}

fn printScope(self: *SemanticPrinter, scope: *const Semantic.Scope) !void {
    const scopes = &self.semantic.scopes;
    const symbols = &self.semantic.symbols;
    const bound_names = symbols.symbols.items(.name);
    const debug_names = symbols.symbols.items(.debug_name);

    const p = self.printer;

    try p.pushObject();
    defer p.pop();

    try p.pProp("id", "{d}", scope.id);

    try p.pPropName("flags");
    try p.pJson(scope.flags);
    p.pComma();
    try p.pIndent();

    {
        try p.pPropName("bindings");
        try p.pushObject();
        defer p.popIndent();
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
    try p.pushArray(true);
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
    // flags: Reference.Flags,
    flags: []const []const u8,
};

const SemanticPrinter = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Printer = @import("./Printer.zig");

const _semantic = @import("../semantic.zig");
const Semantic = _semantic.Semantic;
const Symbol = _semantic.Symbol;
const Scope = _semantic.Scope;
const Reference = _semantic.Reference;
const Node = std.zig.Ast.Node;
