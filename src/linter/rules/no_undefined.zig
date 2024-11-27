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
//! initialization. Such cases should be communicated to other programmers via a
//! safety comment. Adding `SAFETY: <reason>` before the line using `undefined`
//! will not trigger a rule violation.
//!
//! ```zig
//! // SAFETY: arr is immediately initialized after declaration.
//! var arr: [10]u8 = undefined;
//! @memset(&arr, 0);
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

const Ast = std.zig.Ast;
const Node = Ast.Node;
const Loc = std.zig.Loc;
const Span = source.Span;
const LinterContext = @import("../lint_context.zig");
const Rule = @import("../rule.zig").Rule;
const NodeWrapper = @import("../rule.zig").NodeWrapper;

const NoUndefined = @This();
pub const meta: Rule.Meta = .{
    .name = "no-undefined",
    .category = .restriction,
    .default = .warning,
};

pub fn runOnNode(_: *const NoUndefined, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const node = wrapper.node;
    const ast = ctx.ast();

    if (node.tag != .identifier) return;
    const name = ast.getNodeSource(wrapper.idx);
    if (!std.mem.eql(u8, name, "undefined")) return;

    // `undefined` is ok if a `SAFETY: <reason>` comment is present before it.
    if (ctx.commentsBefore(node.main_token)) |comment| {
        var lines = mem.splitScalar(u8, comment, '\n');
        while (lines.next()) |line| {
            const l = util.trimWhitespace(mem.trimLeft(u8, util.trimWhitespace(line), "//"));
            if (mem.startsWith(u8, l, "SAFETY:")) return;
        }
    }

    const e = ctx.diagnostic("`undefined` is missing a safety comment", .{ctx.spanT(node.main_token)});
    e.help = .{
        .str = "Add a `SAFETY: <reason>` before this line explaining why this code is safe.",
        .static = true,
    };
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
        \\// SAFETY: this is safe because foo bar
        \\var x: []u8 = undefined;
    };
    const fail = &[_][:0]const u8{
        "const x = undefined;",
        \\// This is not a safety comment
        \\const x = undefined;
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
