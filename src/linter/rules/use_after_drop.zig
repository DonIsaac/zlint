//! ## What This Rule Does
//!
//! Checks for variables used after their memory has been deallocated or
//! otherwise invalidated. In Rust terms, it looks for variables used after
//! being dropped.
const std = @import("std");
const _source = @import("../../source.zig");
const semantic = @import("../../semantic.zig");
const _rule = @import("../rule.zig");

const Ast = std.zig.Ast;
const Node = Ast.Node;
const Symbol = semantic.Symbol;
const Loc = std.zig.Loc;
const Span = _source.Span;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const NodeWrapper = _rule.NodeWrapper;
const assert = std.debug.assert;

// Rule metadata
const UseAfterDrop = @This();
pub const Name = "use-after-drop";

// Runs on each node in the AST. Useful for syntax-based rules.
pub fn runOnNode(_: *const UseAfterDrop, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const tags: []const Node.Tag = ctx.ast().nodes.items(.tag);
    const datas: []const Node.Data = ctx.ast().nodes.items(.data);
    const node = wrapper.node;

    switch (node.tag) {
        .@"return" => {
            const returned_expr = node.data.lhs;
            if (returned_expr == LinterContext.NULL_NODE) return;

            switch (tags[returned_expr]) {
                // return &<expr>
                .address_of => {
                    const addr_target = datas[returned_expr].lhs;
                    if (addr_target == LinterContext.NULL_NODE) return;
                    return checkReturnedPointer(addr_target, ctx);
                },
                else => {},
            }
        },
        // TODO: check for use after free.
        else => {
            // noop
        },
    }
}

/// Checks `return &<expr>`. `addr_target` is the expression within an
/// `.address_of` (e.g. `&`) node.
fn checkReturnedPointer(addr_target: Node.Index, ctx: *LinterContext) void {
    const tags: []const Node.Tag = ctx.ast().nodes.items(.tag);
    const datas: []const Node.Data = ctx.ast().nodes.items(.data);
    assert(addr_target != LinterContext.NULL_NODE);
    _ = tags;
    _ = datas;
    @panic("TODO: cehckReturnedPointer");
}

pub fn runOnSymbol(_: *const UseAfterDrop, symbol: Symbol.Id, ctx: *LinterContext) void {
    _ = symbol;
    _ = ctx;
    @panic("TODO: implement runOnSymbol, or remove it if not needed");
}

// Used by the Linter to register the rule so it can be run.
pub fn rule(self: *UseAfterDrop) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test UseAfterDrop {
    const t = std.testing;

    var use_after_drop = UseAfterDrop{};
    var runner = RuleTester.init(t.allocator, use_after_drop.rule());
    defer runner.deinit();

    // Code your rule should pass on
    const pass = &[_][:0]const u8{
        // TODO: add test cases
        "const x = 1",
    };

    // Code your rule should fail on
    const fail = &[_][:0]const u8{
        // TODO: add test cases
        "const x = 1",
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
