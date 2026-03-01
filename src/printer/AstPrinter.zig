opts: Options,
source: Source,
ast: *const Ast,
printer: *Printer,
max_node_id: usize,
node_links: ?*const NodeLinks = null,

pub const Options = struct {
    verbose: bool = false,
};

pub fn new(
    printer: *Printer,
    opts: Options,
    source: Source,
    ast: *const Ast,
) AstPrinter {
    return .{
        .opts = opts,
        .source = source,
        .ast = ast,
        .printer = printer,
        .max_node_id = ast.nodes.len - 1,
    };
}

pub fn setNodeLinks(self: *AstPrinter, node_links: *const NodeLinks) void {
    assert(self.node_links == null);
    assert(node_links.parents.items.len == self.ast.nodes.len);
    self.node_links = node_links;
}

pub fn printAst(self: *AstPrinter) !void {
    try self.printer.pushObject();
    defer self.printer.pop();

    try self.printPropNodeArray("root", self.ast.rootDecls());
}

fn printAstNode(self: *AstPrinter, node_id: NodeId) anyerror!void {
    const idx = @intFromEnum(node_id);
    if (idx > self.max_node_id) {
        try self.printer.print("\"<out of bounds: {d}>\"", .{idx});
        return;
    }

    const tag = self.ast.nodeTag(node_id);
    if (tag == .root) {
        self.printer.pNull();
        self.printer.pComma();
        return;
    }

    const main_token = self.ast.nodeMainToken(node_id);

    try self.printer.pushObject();
    defer self.printer.pop();

    {
        try self.printer.pPropWithNamespacedValue("tag", tag);
        try self.printer.pProp("id", "{d}", idx);
        if (self.node_links) |node_links| {
            const parent = node_links.parents.items[idx];
            try self.printer.pProp("parent", "{d}", @intFromEnum(parent));
        }
    }

    if (self.opts.verbose) {
        const main_tok = self.ast.tokens.get(main_token);
        const main_token_loc = self.ast.tokenLocation(main_tok.start, main_token);
        try self.printer.pPropName("main_token");
        try self.printer.pushObject();
        defer self.printer.pop();

        try self.printer.pPropWithNamespacedValue("tag", main_tok.tag);
        try self.printer.pProp("id", "{d}", main_token);
        try self.printer.pPropJson("loc", main_token_loc);
    } else {
        const tok_tag = self.ast.tokens.items(.tag)[main_token];
        try self.printer.pPropWithNamespacedValue("main_token", tok_tag);
    }

    switch (tag) {
        .string_literal => {
            const main_value = self.ast.tokenSlice(main_token);
            try self.printer.pPropStr("value", main_value);
        },
        .identifier => {
            const name = self.ast.getNodeSource(node_id);
            try self.printer.pPropStr("name", name);
        },
        .fn_decl => return self.printFnDecl(node_id),
        .root => unreachable,
        else => {
            var call_buf: [1]NodeId = undefined;
            var container_buf: [2]NodeId = undefined;
            if (self.ast.fullVarDecl(node_id)) |decl| {
                try self.printVarDecl(main_token, decl);
            } else if (self.ast.fullCall(&call_buf, node_id)) |call| {
                try self.printCall(call);
            } else if (self.ast.fullContainerDecl(&container_buf, node_id)) |container| {
                try self.printContainerDecl(container);
            }
        },
    }
}

fn printVarDecl(self: *AstPrinter, main_token: Ast.TokenIndex, var_decl: Ast.full.VarDecl) !void {
    const identifier_tok_id = main_token + 1;

    if (IS_DEBUG) {
        const id_tok = self.ast.tokens.get(identifier_tok_id);
        assert(id_tok.tag == .identifier);
    }

    const ident = self.ast.tokenSlice(identifier_tok_id);
    try self.printer.pPropStr("ident", ident);
    try self.printer.pPropJson("data", var_decl);
    inline for (std.meta.fields(Ast.full.VarDecl.Components)) |field| {
        if (comptime std.mem.indexOf(u8, field.name, "_node")) |node_suffix_index| {
            const name: []const u8 = field.name[0..node_suffix_index];
            const val = @field(var_decl.ast, field.name);
            if (comptime @TypeOf(val) == Node.OptionalIndex) {
                if (val.unwrap()) |node_id| {
                    try self.printer.pPropName(name);
                    try self.printAstNode(node_id);
                }
            }
        }
    }
}

fn printCall(self: *AstPrinter, call: Ast.full.Call) !void {
    try self.printPropNodeArray("params", call.ast.params);
}

fn printFnDecl(self: *AstPrinter, node: NodeId) !void {
    const p = self.printer;
    var buf: [1]Node.Index = undefined;
    const proto: Ast.full.FnProto = self.ast.fullFnProto(&buf, node) orelse @panic("fn decls always have a fn prototype");
    if (proto.name_token) |n| {
        try p.pPropStr("name", self.ast.tokenSlice(n));
    } else {
        try p.pProp("name", "{any}", .{null});
    }
    try self.printPropNodeArray("params", proto.ast.params);
    if (proto.ast.return_type.unwrap()) |rt| {
        try self.printPropNode("return_type", rt);
    }
    const body = self.ast.nodeData(node).node_and_node[1];
    try self.printPropNode("body", body);
}

fn printContainerDecl(self: *AstPrinter, container: Ast.full.ContainerDecl) !void {
    return self.printPropNodeArray("members", container.ast.members);
}

fn printPropNode(self: *AstPrinter, key: []const u8, node: NodeId) !void {
    try self.printer.pPropName(key);
    try self.printAstNode(node);
}

fn printPropNodeArray(self: *AstPrinter, key: []const u8, nodes: []const NodeId) !void {
    try self.printer.pPropName(key);
    try self.printer.pushArray(true);
    defer self.printer.pop();

    for (nodes) |node| {
        try self.printAstNode(node);
    }
}

const IS_DEBUG = builtin.mode == .Debug;
const assert = std.debug.assert;

const AstPrinter = @This();

const std = @import("std");
const builtin = @import("builtin");
const Semantic = @import("../Semantic.zig");
const Ast = Semantic.Ast;
const NodeLinks = Semantic.NodeLinks;
const Node = Ast.Node;
const NodeId = Ast.Node.Index;
const Printer = @import("Printer.zig");
const Source = @import("../source.zig").Source;
