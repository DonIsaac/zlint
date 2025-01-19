//! ## What This Rule Does
//! Disallows initializing or assigning variables to `undefined`.
//!
//! Reading uninitialized memory is one of the most common sources of undefined
//! behavior. While debug builds come with runtime safety checks for `undefined`
//! access, they are otherwise undetectable and will not cause panics in release
//! builds.
//!
//! ### Allowed Scenarios
//!
//! There are some cases where using `undefined` makes sense, such as array
//! initialization. Some cases are implicitly allowed, but others should be
//! communicated to other programmers via a safety comment. Adding `SAFETY:
//! <reason>` before the line using `undefined` will not trigger a rule
//! violation.
//!
//! ```zig
//! // arrays may be set to undefined without a safety comment
//! var arr: [10]u8 = undefined;
//! @memset(&arr, 0);
//!
//! // SAFETY: foo is written to by `initializeFoo`, so `undefined` is never
//! // read.
//! var foo: u32 = undefined
//! initializeFoo(&foo);
//! ```
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! const x = undefined;
//!
//! // Consumers of `Foo` should be forced to initialize `x`.
//! const Foo = struct {
//!   x: *u32 = undefined,
//! };
//!
//! var y: *u32 = allocator.create(u32);
//! y.* = undefined;
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! const Foo = struct {
//!   x: *u32,
//!
//!   fn init(allocator: *std.mem.Allocator, value: u32) void {
//!     self.x = allocator.create(u32);
//!     self.x.* = value;
//!   }
//!
//!   fn deinit(self: *Foo, alloc: std.mem.Allocator) void {
//!     alloc.destroy(self.x);
//!     // SAFETY: Foo is being deinitialized, so `x` is no longer used.
//!     // setting to undefined allows for use-after-free detection in
//!     //debug builds.
//!     self.x = undefined;
//!   }
//! };
//! ```
const std = @import("std");
const util = @import("util");
const mem = std.mem;
const ascii = std.ascii;

const Semantic = @import("../../semantic.zig").Semantic;
const Ast = std.zig.Ast;
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const LinterContext = @import("../lint_context.zig");
const Rule = @import("../rule.zig").Rule;
const NodeWrapper = @import("../rule.zig").NodeWrapper;
const Error = @import("../../Error.zig");
const Cow = util.Cow(false);

allow_arrays: bool = true,

const NoUndefined = @This();
pub const meta: Rule.Meta = .{
    .name = "no-undefined",
    .category = .restriction,
    .default = .warning,
};

fn undefinedMissingSafetyComment(ctx: *LinterContext, undefined_tok: TokenIndex) Error {
    var e = ctx.diagnostic("`undefined` is missing a safety comment", .{ctx.spanT(undefined_tok)});
    e.help = Cow.static("Add a `SAFETY: <reason>` before this line explaining why this code is safe.");
    return e;
}
fn undefinedComparison(ctx: *LinterContext, undefined_tok: TokenIndex) Error {
    var e = ctx.diagnostic("`undefined` cannot be used in comparisons.", .{ctx.spanT(undefined_tok)});
    e.help = Cow.static("Uninitialized data can have any value. If you need to check that a value does not exist, use `null`.");
    return e;
}
fn undefinedDefault(ctx: *LinterContext, undefined_tok: TokenIndex) Error {
    var e = ctx.diagnostic("Do not use `undefined` as a default value", .{ctx.spanT(undefined_tok)});
    e.help = Cow.static("If this really can be `undefined`, do so explicitly during struct initialization.");
    return e;
}

pub fn runOnNode(self: *const NoUndefined, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const node = wrapper.node;
    const ast = ctx.ast();

    if (node.tag != .identifier) return;
    const name = ast.getNodeSource(wrapper.idx);
    if (!mem.eql(u8, name, "undefined")) return;

    const node_tags: []const Node.Tag = ast.nodes.items(.tag);
    const main_tokens: []const TokenIndex = ast.nodes.items(.main_token);

    var safety_comment_check = true;
    var has_safety_comment = false;
    var it = ctx.links().iterParentIds(wrapper.idx);
    var i: u32 = 0;
    while (it.next()) |parent| {
        defer i += 1;
        switch (node_tags[parent]) {
            // initializing arrays to undefined can be ok, e.g. when using
            // @memset.
            .global_var_decl,
            .local_var_decl,
            .aligned_var_decl,
            .simple_var_decl,
            => {
                // first parent?
                if (self.allow_arrays and i == 1) {
                    // SAFETY: tags in case guarantee that a full variable declaration
                    // is present.
                    const decl = ast.fullVarDecl(parent) orelse unreachable;
                    const ty = decl.ast.type_node;
                    if (ty == Semantic.NULL_NODE) break;
                    switch (node_tags[ty]) {
                        .array_type, .array_type_sentinel => return,
                        else => {},
                    }
                }
                if (has_safety_comment or (safety_comment_check and hasSafetyComment(ctx, main_tokens[parent]))) return;
                safety_comment_check = false;
            },

            // Using `undefined` as a field's default value
            .container_field_init,
            .container_field_align,
            .container_field,
            => {
                if (!has_safety_comment) {
                    ctx.report(undefinedDefault(ctx, node.main_token));
                }
                return;
            },

            // Comparison to undefined is unspecified behavior. NOTE: we
            // skip safety comment check b/c this is _never_ safe.
            .equal_equal,
            .bang_equal,
            .less_or_equal,
            .less_than,
            .greater_or_equal,
            .greater_than,
            => return ctx.report(undefinedComparison(ctx, node.main_token)),

            // `undefined` is safe in tests
            .test_decl => return,

            // short circuit. Nothing interesting is above these nodes.
            .fn_decl => break,
            else => {
                if (has_safety_comment) return;
                // `undefined` is ok if a `SAFETY: <reason>` comment is present before it.
                if (!has_safety_comment and safety_comment_check and hasSafetyComment(ctx, main_tokens[parent])) {
                    has_safety_comment = true;
                }
            },
        }
    }

    // early_exit: {
    //     if (ctx.semantic.node_links.getParent(wrapper.idx)) |parent| {
    //         const parent_tag = node_tags[parent];
    //         switch (parent_tag) {
    //             // initializing arrays to undefined can be ok, e.g. when using
    //             // @memset.
    //             .global_var_decl,
    //             .local_var_decl,
    //             .aligned_var_decl,
    //             .simple_var_decl,
    //             => if (self.allow_arrays) {
    //                 // SAFETY: tags in case guarantee that a full variable declaration
    //                 // is present.
    //                 const decl = ast.fullVarDecl(parent) orelse unreachable;
    //                 const ty = decl.ast.type_node;
    //                 if (ty == Semantic.NULL_NODE) break :early_exit;
    //                 switch (node_tags[ty]) {
    //                     .array_type, .array_type_sentinel => return,
    //                     else => {},
    //                 }
    //             },

    //             // Comparison to undefined is unspecified behavior. NOTE: we
    //             // skip safety comment check b/c this is _never_ safe.
    //             .equal_equal,
    //             .bang_equal,
    //             .less_or_equal,
    //             .less_than,
    //             .greater_or_equal,
    //             .greater_than,
    //             => return ctx.report(undefinedComparison(ctx, node.main_token)),
    //             else => {},
    //         }
    //     }
    // }

    // // `undefined` is ok if a `SAFETY: <reason>` comment is present before it.
    // if (ctx.commentsBefore(node.main_token)) |comment| {
    //     var lines = mem.splitScalar(u8, comment, '\n');
    //     while (lines.next()) |line| {
    //         const l = util.trimWhitespace(mem.trimLeft(u8, util.trimWhitespace(line), "//"));
    //         if (std.ascii.startsWithIgnoreCase(l, "SAFETY:")) return;
    //     }
    // }

    ctx.report(undefinedMissingSafetyComment(ctx, node.main_token));
}

/// `undefined` is ok if a `SAFETY: <reason>` comment is present before it.
fn hasSafetyComment(ctx: *const LinterContext, first_token: TokenIndex) bool {
    if (ctx.commentsBefore(first_token)) |comment| {
        var lines = mem.splitScalar(u8, comment, '\n');
        while (lines.next()) |line| {
            const l = util.trimWhitespace(mem.trimLeft(u8, util.trimWhitespace(line), "//"));
            if (ascii.startsWithIgnoreCase(l, "SAFETY:")) return true;
        }
    }
    return false;
}

pub fn rule(self: *NoUndefined) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test NoUndefined {
    const t = std.testing;

    var no_undefined = NoUndefined{};
    var runner = RuleTester.init(t.allocator, no_undefined.rule());
    defer runner.deinit();

    const pass = &[_][:0]const u8{
        "const x: ?u32 = null;",
        "const arr: [1]u8 = undefined;",
        "const arr: [1:0]u8 = undefined;",
        \\// SAFETY: this is safe because foo bar
        \\var x: []u8 = undefined;
        ,
        \\// safety: this is safe because foo bar
        \\var x: []u8 = undefined;
        ,
        \\// sAfEtY: this is safe because foo bar
        \\var x: []u8 = undefined;
        ,
        \\// SAFETY: this is safe because foo bar
        \\const x = Foo{
        \\  .foo = undefined,
        \\  .bar = undefined,
        \\};
        ,
        \\const Foo = struct {
        \\  // SAFETY: this is safe because foo bar
        \\  bar: u32 = undefined,
        \\};
        // `undefined` is safe in test blocks (except when comparing)
        \\ test "foo" {
        \\  var x: u32 = undefined;
        \\  x = 1;
        \\}
    };
    const fail = &[_][:0]const u8{
        "const x = undefined;",
        "const slice: []u8 = undefined;",
        "const slice: [:0]u8 = undefined;",
        "const many_ptr: [*]u8 = undefined;",
        "const many_ptr: [*:0]u8 = undefined;",
        \\const Foo = struct { bar: u32 = undefined };
        // comparing to undefined is never allowed, even in test blocks and with
        // safety comments
        \\fn foo(x: *Foo) void {
        \\  if (x == undefined) {
        \\    @import("std").debug.print("x is undefined\n", .{});
        \\  }
        \\}
        ,
        "fn foo(x: *Foo) void { if (x > undefined) {} }",
        "fn foo(x: *Foo) void { if (x >= undefined) {} }",
        "fn foo(x: *Foo) void { if (x != undefined) {} }",
        "fn foo(x: *Foo) void { if (x <= undefined) {} }",
        "fn foo(x: *Foo) void { if (x < undefined) {} }",
        \\ test "foo" {
        \\  var x: u32 = undefined;
        \\  if (x == undefined) {}
        \\}
        ,
        \\fn foo(x: *Foo) void {
        \\  // SAFETY: this is never safe, so this comment is ignored
        \\  if (x == undefined) {
        \\    @import("std").debug.print("x is undefined\n", .{});
        \\  }
        \\}
        ,
        // safety comments
        \\// This is not a safety comment
        \\const x = undefined;
        ,
        \\// SAFETY: foo
        \\const x: u32 = 1;
        \\var y: u32 = undefined;
        ,
        \\const x = Foo{
        \\  // SAFETY: this is safe because foo bar
        \\  .foo = undefined,
        \\  .bar = undefined,
        \\};
        ,
        \\// SAFETY: comments over fn decls aren't considered
        \\fn foo() void {
        \\  var x: u32 = undefined;
        \\}
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
