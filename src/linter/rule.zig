const std = @import("std");
const util = @import("util");
const semantic = @import("../semantic.zig");

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const string = util.string;
const Symbol = semantic.Symbol;
const Severity = @import("../Error.zig").Severity;

const LinterContext = @import("lint_context.zig");

pub const NodeWrapper = struct {
    node: *const Ast.Node,
    idx: Ast.Node.Index,

    pub inline fn getMainTokenOffset(self: *const NodeWrapper, ast: *const Ast) u32 {
        const starts = ast.tokens.items(.start);
        return starts[self.node.main_token];
    }
};

const RunOnNodeFn = *const fn (ptr: *const anyopaque, node: NodeWrapper, ctx: *LinterContext) anyerror!void;
const RunOnSymbolFn = *const fn (ptr: *const anyopaque, symbol: Symbol.Id, ctx: *LinterContext) anyerror!void;

/// A single lint rule.
///
/// ## Creating Rules
/// Rules are structs (or anything else that can have methods) that have 1 or
/// more of the following methods:
/// - `runOnNode(*self, node, *ctx)`
/// - `runOnSymbol(*self, symbol, *ctx)`
/// `Rule` provides a uniform interface to `Linter`. `Rule.init` will look for
/// those methods and, if they exist, stores pointers to them. These then get
/// used by the `Linter` to check for violations.
pub const Rule = struct {
    // name: string,
    meta: Meta,
    ptr: *anyopaque,
    runOnNodeFn: RunOnNodeFn,
    runOnSymbolFn: RunOnSymbolFn,

    /// Rules must have a constant with this name of type `Rule.Meta`.
    const META_FIELD_NAME = "meta";
    pub const Meta = struct {
        name: string,
        category: Category,
        default: Severity = .off,
    };

    pub const Category = enum {
        /// Re-implements a check already performed by the Zig compiler.
        compiler,
        correctness,
        suspicious,
        restriction,
        pedantic,
    };

    pub fn init(ptr: anytype) Rule {
        const T = @TypeOf(ptr);
        const ptr_info = comptime blk: {
            const info = @typeInfo(T);
            break :blk switch (info) {
                .Pointer => info.Pointer,
                else => @compileLog("Rule.init takes a pointer to a rule implementation, found an " ++ @tagName(info)),
            };
        };

        const meta: Meta = if (@hasDecl(ptr_info.child, META_FIELD_NAME))
            @field(ptr_info.child, META_FIELD_NAME)
        else {
            @compileError("Rule must have a `pub const " ++ META_FIELD_NAME ++ " Rule.Meta` field");
        };

        const gen = struct {
            pub fn runOnNode(pointer: *const anyopaque, node: NodeWrapper, ctx: *LinterContext) anyerror!void {
                if (@hasDecl(ptr_info.child, "runOnNode")) {
                    const self: T = @ptrCast(@constCast(pointer));
                    return ptr_info.child.runOnNode(self, node, ctx);
                }
            }
            pub fn runOnSymbol(pointer: *const anyopaque, symbol: Symbol.Id, ctx: *LinterContext) anyerror!void {
                if (@hasDecl(ptr_info.child, "runOnSymbol")) {
                    const self: T = @ptrCast(@constCast(pointer));
                    return ptr_info.child.runOnSymbol(self, symbol, ctx);
                }
            }
        };

        return .{
            .meta = meta,
            .ptr = ptr,
            .runOnNodeFn = gen.runOnNode,
            .runOnSymbolFn = gen.runOnSymbol,
        };
    }

    pub fn runOnNode(self: *const Rule, node: NodeWrapper, ctx: *LinterContext) !void {
        return self.runOnNodeFn(self.ptr, node, ctx);
    }

    pub fn runOnSymbol(self: *const Rule, symbol: Symbol.Id, ctx: *LinterContext) !void {
        return self.runOnSymbolFn(self.ptr, symbol, ctx);
    }
};

fn getRuleName(ty: std.builtin.Type) string {
    switch (ty) {
        .Pointer => {
            const child = ty.Pointer.child;
            if (!@hasDecl(child, "Name")) {
                @panic("Rule must have a `pub const Name: []const u8` field");
            }
            return child.Name;
        },
        else => @panic("Rule must be a pointer"),
    }
}
