const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Node = Ast.Node;
const NodeId = Ast.Node.Index;
const Writer = std.fs.File.Writer;

const Options = @import("../cli/options.zig");
const Source = @import("../source.zig").Source;
const semantic = @import("../semantic.zig");

const assert = std.debug.assert;
const print = std.debug.print;
const stringify = std.json.fmt;

pub fn parseAndPrint(alloc: Allocator, opts: Options, source: Source) !void {
    var sema_result = try semantic.Builder.build(alloc, source.contents);
    defer sema_result.deinit();
    if (sema_result.hasErrors()) {
        for (sema_result.errors.items) |err| {
            std.debug.print("{s}\n", .{err.message});
        }
        return;
    }
    const ast = sema_result.semantic.ast;
    const writer = std.io.getStdOut().writer();
    var printer = Printer.init(alloc, writer, opts, source.contents, &ast);
    defer printer.deinit();
    try printer.printAst();
}

pub const Printer = struct {
    container_stack: ContainerStack,
    alloc: Allocator,
    writer: Writer,
    opts: Options,
    ast: *const Ast,
    source: [:0]const u8,

    const ContainerKind = enum { object, array };
    const ContainerStack = std.ArrayList(ContainerKind);
    const NULL_NODE_ID: NodeId = 0;

    pub fn init(alloc: Allocator, writer: Writer, opts: Options, source: [:0]const u8, ast: *const Ast) Printer {
        const stack = ContainerStack.initCapacity(alloc, 16) catch @panic("failed to allocate memory for printer's container stack");
        return Printer{
            .container_stack = stack,
            .alloc = alloc,
            .opts = opts,
            .writer = writer,
            .source = source,
            .ast = ast,
        };
    }
    pub fn deinit(self: *Printer) void {
        self.container_stack.deinit();
    }
    pub fn printAst(self: *Printer) !void {
        try self.pushArray();
        defer self.pop();

        for (self.ast.rootDecls()) |decl| {
            try self.printAstNode(decl);
        }
    }

    fn printAstNode(self: *Printer, node_id: NodeId) !void {
        const node = self.ast.nodes.get(node_id);
        if (node.tag == .root) {
            return self.pNull();
        }

        // Node object curly braces
        try self.pushObject();
        defer self.pop();
        // NOTE: node.tag has something like `Ast.Node.Tag` as its prefix
        try self.pPropWithNamespacedValue("tag", node.tag);
        try self.pProp("id", "{d}", node_id);

        // Print main token information. In verbose mode, we print all available
        // information (tag, id, location). Otherwise, we only print the tag.
        if (self.opts.verbose) {
            const main_token = self.ast.tokens.get(node.main_token);
            const main_token_loc = self.ast.tokenLocation(main_token.start, node.main_token);
            try self.pPropName("main_token");
            try self.pushObject();
            defer self.pop();

            try self.pPropWithNamespacedValue("tag", main_token.tag);
            try self.pProp("id", "{d}", node.main_token);
            try self.pPropJson("loc", main_token_loc);
        } else {
            const tag = self.ast.tokens.items(.tag)[node.main_token];
            try self.pPropWithNamespacedValue("main_token", tag);
        }

        // Print node-specific data.
        switch (node.tag) {
            .string_literal => {
                const main_value = self.ast.tokenSlice(node.main_token);
                try self.pPropStr("value", main_value);
            },
            .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                const identifier_tok_id = node.main_token + 1;
                const id_tok = self.ast.tokens.get(identifier_tok_id);
                assert(id_tok.tag == .identifier);
                const ident = self.ast.tokenSlice(identifier_tok_id);
                try self.pPropStr("ident", ident);
                const decl = self.ast.fullVarDecl(node_id) orelse unreachable;
                try self.pPropJson("data", decl);
            },
            .root => unreachable,
            else => {},
        }

        if (node.data.lhs == NULL_NODE_ID and node.data.lhs == NULL_NODE_ID) {
            return;
        }
        try self.pPropName("lhs");
        try self.printAstNode(node.data.lhs);

        try self.pPropName("rhs");
        try self.printAstNode(node.data.rhs);
    }

    /// Print a `"key": value` pair with a trailing comma. Value is formatted
    /// using `fmt` as a format string.
    fn pProp(self: *Printer, key: []const u8, comptime fmt: []const u8, value: anytype) !void {
        try self.pPropName(key);
        try self.writer.print(fmt, .{value});
        self.pComma();
    }

    inline fn pPropStr(self: *Printer, key: []const u8, value: []const u8) !void {
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            return self.pProp(key, "{s}", value);
        }
        return self.pProp(key, "\"{s}\"", value);
    }

    fn pPropJson(self: *Printer, key: []const u8, value: anytype) !void {
        try self.pPropName(key);
        try stringify(value, .{}).format("{any}", .{}, self.writer);
        self.pComma();
    }

    /// Print an object property key with a trailing `:`, without printing a value.
    fn pPropName(self: *Printer, key: []const u8) !void {
        try self.pString(key);
        try self.writer.writeAll(": ");
    }

    /// Print a `"key": "value"` object property pair where `value` is a
    /// `dot.separated.namespaced.value`.  Only the last part of the value is
    /// printed.
    fn pPropWithNamespacedValue(self: *Printer, key: []const u8, value: anytype) !void {
        var value_buf: [256]u8 = undefined;
        const value_str = try std.fmt.bufPrintZ(&value_buf, "{any}", .{value});

        // Get the last part of the dot-separated value string.
        var iter = std.mem.split(u8, value_str, ".");
        // Always the previous result from `iter.next()`. Stop once we've
        // reached the end, then `segment` will contain the last part.
        var segment = iter.next();
        while (iter.peek()) |part| {
            segment = part;
            _ = iter.next();
        }
        if (segment == null) @panic("tag should have at least one '.'");
        return self.pProp(key, "\"{s}\"", segment.?);
    }

    /// Print a `null` literal.
    inline fn pNull(self: *Printer) void {
        self.writer.writeAll("null") catch @panic("failed to write null");
    }

    /// Print a string literal.
    inline fn pString(self: *Printer, s: []const u8) !void {
        try self.writer.writeAll("\"");
        try self.writer.writeAll(s);
        try self.writer.writeAll("\"");
    }

    /// Print a comma with a trailing space (`, `).
    inline fn pComma(self: *Printer) void {
        self.writer.writeAll(", ") catch @panic("failed to write comma");
    }

    /// Enter into an object container. When exited (i.e. `pop()`), a closing curly brace will
    /// be printed.
    fn pushObject(self: *Printer) !void {
        try self.container_stack.append(ContainerKind.object);
        _ = try self.writer.write("{");
    }

    /// Enter into an array container. When exited (i.e. `pop()`), a closing square bracket will
    /// be printed.
    fn pushArray(self: *Printer) !void {
        try self.container_stack.append(ContainerKind.array);
        _ = try self.writer.write("[");
    }

    /// Exit out of an object or array container, printing the correspodning
    /// closing token.
    fn pop(self: *Printer) void {
        const kind = self.container_stack.pop();
        const res = switch (kind) {
            ContainerKind.object => self.writer.write("}"),
            ContainerKind.array => self.writer.write("]"),
        };
        if (self.container_stack.items.len > 0) {
            self.pComma();
        }
        _ = res catch @panic("failed to write container end");
    }
};
