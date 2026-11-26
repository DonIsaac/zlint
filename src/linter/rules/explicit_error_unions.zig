//! ## What This Rule Does
//! Disallows `pub` functions that return an error union with an inferred
//! error set (`!T`).
//!
//! An inferred error set changes whenever the function body changes. For a
//! public function, that set is part of the API: adding a new `try` can add a
//! new error that callers must now handle, without any change to the
//! signature. Naming the error set keeps that contract explicit and stable.
//! This is most useful for library authors.
//!
//! Only `pub` functions are checked. Private functions may keep using
//! inferred error sets.
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! pub fn foo() !void {
//!   // ...
//! }
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! pub fn foo() Allocator.Error!void {
//!   // ...
//! }
//!
//! pub fn bar() error{ OutOfMemory, InvalidInput }!u32 {
//!   // ...
//! }
//!
//! fn baz() !void {
//!   // ...
//! }
//! ```

const std = @import("std");
const util = @import("util");
const _rule = @import("../rule.zig");

const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const NodeWrapper = _rule.NodeWrapper;

const Semantic = @import("../../Semantic.zig");
const Ast = Semantic.Ast;
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;

const Error = @import("../../Error.zig");
const Cow = util.Cow(false);

// Rule metadata
const ExplicitErrorUnions = @This();
pub const meta: Rule.Meta = .{
    .name = "explicit-error-unions",
    .category = .pedantic,
    .default = .off,
};

fn explicitErrorUnionsDiagnostic(ctx: *LinterContext, name_token: ?TokenIndex, bang: TokenIndex) Error {
    var e = if (name_token) |name|
        ctx.diagnosticf(
            "Public function `{s}` returns an inferred error set.",
            .{ctx.semantic.tokenSlice(name)},
            .{ctx.labelT(bang, "error set is inferred here", .{})},
        )
    else
        ctx.diagnostic(
            "Public function returns an inferred error set.",
            .{ctx.labelT(bang, "error set is inferred here", .{})},
        );
    e.help = Cow.static("Name the errors it can return, e.g. `Allocator.Error!T` or `error{OutOfMemory}!T`.");
    return e;
}

// Runs on each node in the AST. Useful for syntax-based rules.
pub fn runOnNode(_: *const ExplicitErrorUnions, wrapper: NodeWrapper, ctx: *LinterContext) void {
    // Only function declarations can have inferred error sets. Function types
    // (`fn () !void`) and extern functions without a body cannot.
    if (wrapper.node.tag != .fn_decl) return;

    const ast = ctx.ast();
    var buf: [1]Node.Index = undefined;
    const proto_node = ast.nodeData(wrapper.idx).node_and_node[0];
    const fn_proto = ast.fullFnProto(&buf, proto_node) orelse return;
    if (fn_proto.visib_token == null) return;

    const return_type = fn_proto.ast.return_type.unwrap() orelse return;
    // `!T` parses as a return type of `T` with a `!` token right before it.
    // `E!T` parses as an `error_union` node, so the token before it is `)`.
    const first = ast.firstToken(return_type);
    if (first == 0) return;
    const bang = first - 1;
    if (ast.tokenTag(bang) != .bang) return;

    ctx.report(explicitErrorUnionsDiagnostic(ctx, fn_proto.name_token, bang));
}

// Used by the Linter to register the rule so it can be run.
pub fn rule(self: *ExplicitErrorUnions) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test ExplicitErrorUnions {
    const t = std.testing;

    var explicit_error_unions = ExplicitErrorUnions{};
    var runner = RuleTester.init(t.allocator, explicit_error_unions.rule());
    defer runner.deinit();

    // Code your rule should pass on
    const pass = &[_][:0]const u8{
        "pub fn foo() Allocator.Error!void {}",
        "pub fn foo() std.mem.Allocator.Error!void {}",
        "pub fn foo() error{OutOfMemory}!u32 { return 1; }",
        "pub fn foo() anyerror!void {}",
        "pub fn foo() (A || B)!void {}",
        "pub fn foo() void {}",
        "pub fn foo() u32 { return 1; }",
        "pub fn foo() ?u32 { return null; }",
        // private functions may infer their error set
        "fn foo() !void {}",
        "fn foo(x: u32) !u32 { return x; }",
        "const Foo = struct { fn bar() !void {} };",
        // function types and extern functions have no inferred error set
        "pub const F = *const fn () anyerror!void;",
        "pub extern fn foo() void;",
        // the `!` is not part of the return type
        "pub fn foo(x: bool) bool { return !x; }",
        \\const Foo = struct {
        \\  pub fn bar(self: *Foo) error{Oops}!void {
        \\    _ = self;
        \\    return error.Oops;
        \\  }
        \\};
        ,
    };

    // Code your rule should fail on
    const fail = &[_][:0]const u8{
        "pub fn foo() !void {}",
        "pub fn foo(x: u32) !u32 { return x; }",
        "pub fn foo() !?*const u8 { return null; }",
        "pub inline fn foo() !void {}",
        "pub fn foo(allocator: Allocator, x: u32) ![]u8 { return allocator.alloc(u8, x); }",
        \\const Foo = struct {
        \\  pub fn bar(self: *Foo) !void {
        \\    _ = self;
        \\  }
        \\};
        ,
        \\pub fn Generic(comptime T: type) type {
        \\  return struct {
        \\    pub fn get() !T {
        \\      return error.Oops;
        \\    }
        \\  };
        \\}
        ,
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
