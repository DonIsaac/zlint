//! ## What This Rule Does
//! Checks for `try` statements used outside of error-returning functions.
//!
//! As a `compiler`-level lint, this rule checks for errors also caught by the
//! Zig compiler.
//!
//! ## Examples
//! Examples of **incorrect** code for this rule:
//! ```zig
//! const std = @import("std");
//!
//! var not_in_a_function = try std.heap.page_allocator.alloc(u8, 8);
//!
//! fn foo() void {
//!   var my_str = try std.heap.page_allocator.alloc(u8, 8);
//! }
//!
//! fn bar() !void {
//!   const Baz = struct {
//!     property: u32 = try std.heap.page_allocator.alloc(u8, 8),
//!   };
//! }
//!```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! fn foo() !void {
//!   var my_str = try std.heap.page_allocator.alloc(u8, 8);
//! }
//!```

const std = @import("std");
const util = @import("util");
const _source = @import("../../source.zig");
const semantic = @import("../../semantic.zig");
const _rule = @import("../rule.zig");

const Ast = std.zig.Ast;
const Node = Ast.Node;
const Symbol = semantic.Symbol;
const Scope = semantic.Scope;
const Loc = std.zig.Loc;
const Span = _source.Span;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const NodeWrapper = _rule.NodeWrapper;

// Rule metadata
const HomelessTry = @This();
pub const meta: Rule.Meta = .{
    .name = "homeless-try",
    .category = .compiler,
};

const CONTAINER_FLAGS: Scope.Flags = .{ .s_struct = true, .s_enum = true, .s_union = true };

// Runs on each node in the AST. Useful for syntax-based rules.
pub fn runOnNode(_: *const HomelessTry, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const scope_flags: []const Scope.Flags = ctx.scopes().scopes.items(.flags);

    const node = wrapper.node;
    if (node.tag != Node.Tag.@"try") return;

    const curr_scope = ctx.links().scopes.items[wrapper.idx];
    var it = ctx.scopes().iterParents(curr_scope);

    while (it.next()) |scope| {
        const flags = scope_flags[scope.int()];
        const is_function = flags.s_function;
        const is_block = flags.s_block;
        if (is_function and !is_block) {
            checkFnDecl(ctx, scope, wrapper.idx);
            return;
        }
        if (flags.intersects(CONTAINER_FLAGS)) break;
    }

    ctx.diagnostic(
        "`try` cannot be used outside of a function.",
        .{ctx.spanT(ctx.ast().firstToken(wrapper.idx))},
    );
}
fn checkFnDecl(ctx: *LinterContext, scope: Scope.Id, try_node: Node.Index) void {
    const tags: []const Node.Tag = ctx.ast().nodes.items(.tag);
    const decl_node = ctx.scopes().scopes.items(.node)[scope.int()];

    if (tags[decl_node] != .fn_decl) {
        if (comptime util.IS_DEBUG) {
            util.assert(false, "function-bound scopes (w/o .s_block) should be bound to a function declaration node.", .{});
        } else {
            return;
        }
    }

    const return_type: Node.Index = blk: {
        var buf: [1]Node.Index = undefined;
        const proto: Ast.full.FnProto = ctx.ast().fullFnProto(&buf, decl_node) orelse @panic(".fn_decl nodes always have a full fn proto available.");
        break :blk proto.ast.return_type;
    };
    switch (tags[return_type]) {
        // valid
        .error_union => return,
        else => {
            const tok_tags: []const std.zig.Token.Tag = ctx.ast().tokens.items(.tag);
            const prev_tok = ctx.ast().firstToken(return_type) - 1;
            if (tok_tags[prev_tok] == .bang) return;
        },
    }

    ctx.diagnostic(
        "`try` cannot be used in functions that do not return errors.",
        .{ctx.spanT(ctx.ast().firstToken(try_node))},
    );
}

// Used by the Linter to register the rule so it can be run.
pub fn rule(self: *HomelessTry) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test HomelessTry {
    const t = std.testing;

    var homeless_try = HomelessTry{};
    var runner = RuleTester.init(t.allocator, homeless_try.rule());
    defer runner.deinit();

    // Code your rule should pass on
    const pass = &[_][:0]const u8{
        \\const std = @import("std");
        \\fn foo() std.mem.Allocator.Error!void {
        \\  _ = try std.heap.page_allocator.alloc(u8, 8);
        \\}
        ,
        \\const std = @import("std");
        \\fn foo() !void {
        \\  _ = try std.heap.page_allocator.alloc(u8, 8);
        \\}
        ,
        \\const std = @import("std");
        \\fn foo() anyerror!void {
        \\  _ = try std.heap.page_allocator.alloc(u8, 8);
        \\}
        ,
        \\fn foo() anyerror![]u8 {
        \\  const x = try std.heap.page_allocator.alloc(u8, 8);
        \\  return x;
        \\}
        ,
        \\const Foo = struct {
        \\  pub fn foo() anyerror![]u8 {
        \\    const x = try std.heap.page_allocator.alloc(u8, 8);
        \\    return x;
        \\  }
        \\};
        ,
        \\const std = @import("std");
        \\fn foo(alloc: ?std.mem.Allocator) ![]const u8 {
        \\  if (alloc) |a| {
        \\    const result = try a.alloc(u8, 8);
        \\    @memset(&result, 0);
        \\    return result;
        \\  } else {
        \\    return "foo";
        \\  }
        \\}
    };

    const fail = &[_][:0]const u8{
        \\const std = @import("std");
        \\fn foo() void {
        \\  _ = try std.heap.page_allocator.alloc(u8, 8);
        \\}",
        ,
        \\const std = @import("std");
        \\const x = try std.heap.page_allocator.alloc(u8, 8);
        ,
        \\const std = @import("std");
        \\fn foo() !void {
        \\  const Bar = struct {
        \\    baz: []u8 = try std.heap.page_allocator.alloc(u8, 8),
        \\  };
        \\}
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}