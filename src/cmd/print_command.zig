//! Hacky AST printer for debugging purposes.
//!
//! Resolves AST nodes and prints them as JSON. This can be safely piped into a file, since `std.debug.print` writes to stderr.
//!
//! ## Usage
//! ```sh
//! # note: right now, no target file can be specified. Run
//! zig build run -- --print-ast | prettier --stdin-filepath foo.ast.json > tmp/foo.ast.json
//! ```
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Node = Ast.Node;
const NodeId = Ast.Node.Index;

const Options = @import("../cli/Options.zig");
const Source = @import("../source.zig").Source;
const semantic = @import("../semantic.zig");
const Printer = @import("../printer/Printer.zig");
const SemanticPrinter = @import("../printer/SemanticPrinter.zig");

const assert = std.debug.assert;
const IS_DEBUG = builtin.mode == .Debug;

const NULL_NODE_ID: NodeId = 0;

pub fn parseAndPrint(alloc: Allocator, opts: Options, source: Source) !void {
    var sema_result = try semantic.Builder.build(alloc, source.contents);
    defer sema_result.deinit();
    if (sema_result.hasErrors()) {
        for (sema_result.errors.items) |err| {
            std.debug.print("{s}\n", .{err.message});
        }
        return;
    }
    const ast = sema_result.value.ast;
    const writer = std.io.getStdOut().writer();
    var printer = Printer.init(alloc, writer);
    defer printer.deinit();
    var ast_printer = AstPrinter.new(&printer, opts, source, &ast);
    var semantic_printer = SemanticPrinter.new(&printer);

    try printer.pushObject();
    defer printer.pop();
    try printer.pPropName("ast");
    try ast_printer.printAst();
    try printer.pPropName("symbols");
    try semantic_printer.printSymbolTable(&sema_result.value.symbols);
}

/// TODO: move to src/printer/AstPrinter.zig?
const AstPrinter = struct {
    opts: Options,
    source: Source,
    ast: *const Ast,
    printer: *Printer,
    max_node_id: NodeId,

    fn new(printer: *Printer, opts: Options, source: Source, ast: *const Ast) AstPrinter {
        return .{ .opts = opts, .source = source, .ast = ast, .printer = printer, .max_node_id = @intCast(ast.nodes.len - 1) };
    }

    fn printAst(self: *AstPrinter) !void {
        try self.printer.pushObject();
        defer self.printer.pop();

        try self.printPropNodeArray("root", self.ast.rootDecls());
    }

    fn printAstNode(self: *AstPrinter, node_id: NodeId) anyerror!void {
        if (node_id > self.max_node_id) {
            try self.printer.print("\"<out of bounds: {d}>\"", .{node_id});
            return;
        }

        const node = self.ast.nodes.get(node_id);
        if (node.tag == .root) {
            self.printer.pNull();
            self.printer.pComma();
            return;
        }

        // Node object curly braces
        try self.printer.pushObject();
        defer self.printer.pop();

        // Data common to all nodes
        {
            // NOTE: node.tag has something like `Ast.Node.Tag` as its prefix
            try self.printer.pPropWithNamespacedValue("tag", node.tag);
            try self.printer.pProp("id", "{d}", node_id);
        }

        // Print main token information. In verbose mode, we print all available
        // information (tag, id, location). Otherwise, we only print the tag.
        if (self.opts.verbose) {
            const main_token = self.ast.tokens.get(node.main_token);
            const main_token_loc = self.ast.tokenLocation(main_token.start, node.main_token);
            try self.printer.pPropName("main_token");
            try self.printer.pushObject();
            defer self.printer.pop();

            try self.printer.pPropWithNamespacedValue("tag", main_token.tag);
            try self.printer.pProp("id", "{d}", node.main_token);
            try self.printer.pPropJson("loc", main_token_loc);
        } else {
            const tag = self.ast.tokens.items(.tag)[node.main_token];
            try self.printer.pPropWithNamespacedValue("main_token", tag);
        }

        // Print node-specific data.
        switch (node.tag) {
            .string_literal => {
                const main_value = self.ast.tokenSlice(node.main_token);
                try self.printer.pPropStr("value", main_value);
            },
            .root => unreachable,
            else => {
                var call_buf: [1]NodeId = undefined;
                var container_buf: [2]NodeId = undefined;
                if (self.ast.fullVarDecl(node_id)) |decl| {
                    try self.printVarDecl(node, decl);
                } else if (self.ast.fullCall(&call_buf, node_id)) |call| {
                    try self.printCall(node, call);
                } else if (self.ast.fullContainerDecl(&container_buf, node_id)) |container| {
                    try self.printContainerDecl(node, container);
                }
            },
        }

        // Recurse down lhs/rhs. To keep things succinct, skip printing entirely if
        // at a leaf node.
        {
            if (node.data.lhs == NULL_NODE_ID and node.data.rhs == NULL_NODE_ID) {
                return;
            }

            try self.printer.pPropName("lhs");
            if (node.data.lhs == NULL_NODE_ID) {
                self.printer.pNull();
                self.printer.pComma();
            } else {
                try self.printAstNode(node.data.lhs);
            }

            try self.printer.pPropName("rhs");
            try self.printAstNode(node.data.rhs);
        }
    }

    fn printVarDecl(self: *AstPrinter, node: Node, var_decl: Ast.full.VarDecl) !void {
        const identifier_tok_id = node.main_token + 1;

        if (IS_DEBUG) {
            const id_tok = self.ast.tokens.get(identifier_tok_id);
            assert(id_tok.tag == .identifier);
        }

        const ident = self.ast.tokenSlice(identifier_tok_id);
        try self.printer.pPropStr("ident", ident);
        // const decl = ast.fullVarDecl(node_id) orelse unreachable;
        try self.printer.pPropJson("data", var_decl);
        const _init = var_decl.ast.init_node;
        try self.printer.pPropName("init");
        try self.printAstNode(_init);
    }

    fn printCall(self: *AstPrinter, _: Node, call: Ast.full.Call) !void {
        try self.printer.pProp("async_token", "{any}", call.async_token);
        //     try self.printPropNode("fn_node", call.ast.fn_expr);
        try self.printPropNodeArray("params", call.ast.params);
    }

    fn printContainerDecl(self: *AstPrinter, _: Node, container: Ast.full.ContainerDecl) !void {
        return self.printPropNodeArray("members", container.ast.members);
    }

    fn printPropNode(self: *AstPrinter, key: []const u8, node: NodeId) !void {
        try self.printer.pPropName(key);
        try self.printAstNode(node);
    }

    fn printPropNodeArray(self: *AstPrinter, key: []const u8, nodes: []const NodeId) !void {
        try self.printer.pPropName(key);
        try self.printer.pushArray();
        defer self.printer.pop();

        // try self.printer.pPropName(key);

        for (nodes) |node| {
            try self.printAstNode(node);
        }
    }
};
