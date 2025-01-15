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
const source = @import("../../source.zig");

const Semantic = @import("../../semantic.zig").Semantic;
const Scope = Semantic.Scope;
const Ast = std.zig.Ast;
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const Loc = std.zig.Loc;
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
    e.help = Cow.static("uninitialized data can have any value. If you need to check that a value does not exist, use `null`.");
    return e;
}

pub fn runOnNode(self: *const NoUndefined, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const node = wrapper.node;
    const ast = ctx.ast();

    if (node.tag != .identifier) return;
    const name = ast.getNodeSource(wrapper.idx);
    if (!std.mem.eql(u8, name, "undefined")) return;

    const node_tags: []const Node.Tag = ast.nodes.items(.tag);

    early_exit: {
        if (ctx.semantic.node_links.getParent(wrapper.idx)) |parent| {
            const parent_tag = node_tags[parent];
            switch (parent_tag) {
                // initializing arrays to undefined can be ok, e.g. when using
                // @memset.
                .global_var_decl,
                .local_var_decl,
                .aligned_var_decl,
                .simple_var_decl,
                => if (self.allow_arrays) {
                    // SAFETY: tags in case guarantee that a full variable declaration
                    // is present.
                    const decl = ast.fullVarDecl(parent) orelse unreachable;
                    const ty = decl.ast.type_node;
                    if (ty == Semantic.NULL_NODE) break :early_exit;
                    switch (node_tags[ty]) {
                        .array_type, .array_type_sentinel => return,
                        else => {},
                    }
                },

                // Comparison to undefined is always U.B. NOTE: we skip safety
                // comment check b/c this is _never_ safe.
                .equal_equal, .bang_equal, .less_or_equal, .less_than, .greater_or_equal, .greater_than => return ctx.report(undefinedComparison(ctx, node.main_token)),
                else => {},
            }
        }
    }

    // `undefined` is ok if a `SAFETY: <reason>` comment is present before it.
    if (ctx.commentsBefore(node.main_token)) |comment| {
        var lines = mem.splitScalar(u8, comment, '\n');
        while (lines.next()) |line| {
            const l = util.trimWhitespace(mem.trimLeft(u8, util.trimWhitespace(line), "//"));
            if (std.ascii.startsWithIgnoreCase(l, "SAFETY:")) return;
        }
    }

    ctx.report(undefinedMissingSafetyComment(ctx, node.main_token));
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
    };
    const fail = &[_][:0]const u8{
        "const x = undefined;",
        "const slice: []u8 = undefined;",
        "const slice: [:0]u8 = undefined;",
        "const many_ptr: [*]u8 = undefined;",
        "const many_ptr: [*:0]u8 = undefined;",
        \\// This is not a safety comment
        \\const x = undefined;
        ,
        \\fn foo(x: *Foo) void {
        \\  if (x == undefined) {
        \\    @import("std").debug.print("x is undefined\n", .{});
        \\  }
        \\}
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
