const std = @import("std");

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

const string = @import("util").string;
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

pub const Rule = struct {
    name: string,
    ptr: *anyopaque,
    runOnNodeFn: RunOnNodeFn,

    pub fn init(ptr: anytype) Rule {
        const T = @TypeOf(ptr);
        const ptr_info = @typeInfo(T);
        const name = getRuleName(ptr_info);

        const gen = struct {
            pub fn runOnNode(pointer: *const anyopaque, node: NodeWrapper, ctx: *LinterContext) anyerror!void {
                // TODO
                // if (@hasDecl(T, "runOnNode")) {
                // const self: T = @ptrCast(@alignCast(pointer));
                const self: T = @ptrCast(@constCast(pointer));
                return ptr_info.Pointer.child.runOnNode(self, node, ctx);
                // }
            }
        };

        return .{
            .name = name,
            .ptr = ptr,
            .runOnNodeFn = gen.runOnNode,
        };
    }

    pub fn runOnNode(self: *const Rule, node: NodeWrapper, ctx: *LinterContext) !void {
        return self.runOnNodeFn(self.ptr, node, ctx);
    }
};

// test "simple rules" {
//     const NoUndefined = struct {
//         pub const Name = "NoUndefined";
//
//         pub fn runOnNode(self: *NoUndefined, node: *const Ast.Node) void {
//             switch (node.tag) {
//                 .identifier => {
//                     node.main_token
//                     if (ident == "undefined") {
//                         std.debug.print("Error: found 'undefined' identifier\n", .{});
//                     }
//                 },
//                 else => {},
//                 },
//                 else => {},
//             }
//             node.tag
//             const decl = node.?;
//             if (decl == null) {
//                 return;
//             }
//             if (decl.NodeType == Ast.NodeTypeVariableDeclaration) {
//                 const var_decl = decl.VariableDeclaration;
//                 if (var_decl.type == null) {
//                     std.debug.print("Error: variable declaration has no type\n", .{});
//                 }
//             }
//         }
//     };
//     }
// }

fn getRuleName(ty: std.builtin.Type) string {
    switch (ty) {
        .Pointer => {
            const child = ty.Pointer.child;
            if (!@hasDecl(child, "Name")) {
                @panic("Rule must have a Name field");
            }
            return child.Name;
        },
        else => @panic("Rule must be a pointer"),
    }
}
