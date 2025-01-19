//! ## What This Rule Does
//! Checks for `try` statements used outside of error-returning functions.
//!
//! As a `compiler`-level lint, this rule checks for errors also caught by the
//! Zig compiler.
//!
//! ## Examples
//!
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
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! fn foo() !void {
//!   var my_str = try std.heap.page_allocator.alloc(u8, 8);
//! }
//! ```
//!
//! Zig allows `try` in comptime scopes in or nested within functions. This rule
//! does not flag these cases.
//! ```zig
//! const std = @import("std");
//! fn foo(x: u32) void {
//!   comptime {
//!     // valid
//!     try bar(x);
//!   }
//! }
//! fn bar(x: u32) !void {
//!   return if (x == 0) error.Unreachable else void;
//! }
//! ```
//!
//! Zig also allows `try` on functions whose error union sets are empty. ZLint
//! does _not_ respect this case. Please refactor such functions to not return
//! an error union.
//! ```zig
//! const std = @import("std");
//! fn foo() !u32 {
//!   // compiles, but treated as a violation. `bar` should return `u32`.
//!   const x = try bar();
//!   return x + 1;
//! }
//! fn bar() u32 {
//!   return 1;
//! }
//! ```

const std = @import("std");
const util = @import("util");
const semantic = @import("../../semantic.zig");
const _rule = @import("../rule.zig");

const Ast = std.zig.Ast;
const Node = Ast.Node;
const Scope = semantic.Scope;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const NodeWrapper = _rule.NodeWrapper;
const Error = @import("../../Error.zig");
const Cow = util.Cow(false);

fn notInFnDiagnostic(ctx: *LinterContext, node: Node.Index) Error {
    return ctx.diagnostic("`try` cannot be used outside of a function or test block.", .{
        ctx.labelT(ctx.ast().firstToken(node), "there is nowhere to propagate errors to.", .{}),
    });
}

// Rule metadata
const HomelessTry = @This();
pub const meta: Rule.Meta = .{
    .name = "homeless-try",
    .category = .compiler,
    .default = .err,
};

// Runs on each node in the AST. Useful for syntax-based rules.
pub fn runOnNode(_: *const HomelessTry, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const scope_flags: []const Scope.Flags = ctx.scopes().scopes.items(.flags);

    const node = wrapper.node;
    if (node.tag != Node.Tag.@"try") return;

    const curr_scope = ctx.links().scopes.items[wrapper.idx];
    var it = ctx.scopes().iterParents(curr_scope);

    while (it.next()) |scope| {
        const flags = scope_flags[scope.int()];
        // `try` is allowed in non-error returning comptime code; it causes
        // a compilation error.
        if (flags.s_comptime) return;
        const is_function_sig = flags.s_function and !flags.s_block;
        // functions create two scopes: one for the signature (binds params,
        // return type references symbols here) and one for the function body.
        // We want to check at the function signature level
        if (is_function_sig) {
            checkFnDecl(ctx, scope, wrapper.idx);
            return;
        } else if (flags.s_test) {
            // test statements implicitly have !void signatures.
            return;
        }
        if (flags.isContainer()) break;
    }

    ctx.report(notInFnDiagnostic(ctx, wrapper.idx));
}

fn checkFnDecl(ctx: *LinterContext, scope: Scope.Id, try_node: Node.Index) void {
    const tags: []const Node.Tag = ctx.ast().nodes.items(.tag);
    const main_tokens: []const Ast.TokenIndex = ctx.ast().nodes.items(.main_token);
    const decl_node: Node.Index = ctx.scopes().scopes.items(.node)[scope.int()];

    if (tags[decl_node] != .fn_decl) {
        if (comptime util.IS_DEBUG) {
            util.assert(false, "function-bound scopes (w/o .s_block) should be bound to a function declaration node.", .{});
        } else {
            return;
        }
    }

    var buf: [1]Node.Index = undefined;
    const proto: Ast.full.FnProto = ctx.ast().fullFnProto(&buf, decl_node) orelse @panic(".fn_decl nodes always have a full fn proto available.");
    const return_type = proto.ast.return_type;

    switch (tags[return_type]) {
        // valid
        .error_union => return,
        else => {
            const tok_tags: []const std.zig.Token.Tag = ctx.ast().tokens.items(.tag);
            const prev_tok = ctx.ast().firstToken(return_type) - 1;
            if (tok_tags[prev_tok] == .bang) return;
        },
    }

    var e = ctx.diagnostic(
        "`try` cannot be used in functions that do not return errors.",
        .{
            if (proto.name_token) |name_token|
                ctx.labelT(name_token, "function `{s}` is declared here.", .{ctx.semantic.tokenSlice(name_token)})
            else
                ctx.labelT(main_tokens[decl_node], "function is declared here.", .{}),
            ctx.labelT(ctx.ast().firstToken(try_node), "it cannot propagate error unions.", .{}),
        },
    );
    const return_type_src = ctx.ast().getNodeSource(return_type);
    e.help = Cow.fmt(ctx.gpa, "Change the return type to `!{s}`.", .{return_type_src}) catch @panic("OOM");
    ctx.report(e);
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
        // try within catch and fn call. Caused a wonky error before.
        \\const std = @import("std");
        \\const alloc = std.heap.page_allocator;
        \\const Foo = struct {
        \\  pub fn foo(thing: bool) !void {
        \\    const ns = std.ArrayList(*u8).init(alloc) catch unreachable;
        \\    ns.append(try alloc.create(u8)) catch unreachable;
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
        ,
        // test statements
        \\const std = @import("std");
        \\test "foo" {
        \\  try std.testing.expectEqual(1, 1);
        \\}
        ,
        \\const std = @import("std");
        \\fn add(a: u32, b: u32) u32 { return a + b; }
        \\test add {
        \\  try std.testing.expectEqual(2, add(1, 1));
        \\}
        ,
        \\pub fn iterationCount(this: *const @This()) !u32 {
        \\  return try std.fmt.parseInt(u32, this.i, 0);
        \\}
        ,
        // comptime code
        \\const std = @import("std");
        \\fn foo(x: u32) void {
        \\  comptime {
        \\    try bar(x);
        \\  }
        \\}
        ,
        \\const std = @import("std");
        \\fn foo(x: bool) void {
        \\  comptime {
        \\    if (x) {
        \\      try bar(x);
        \\    }
        \\  }
        \\}
        ,
    };

    const fail = &[_][:0]const u8{
        \\const std = @import("std");
        \\fn foo() void {
        \\  const x = try std.heap.page_allocator.alloc(u8, 8);
        \\}
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
