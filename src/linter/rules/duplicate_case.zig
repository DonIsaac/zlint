//! ## What This Rule Does
//! Checks for duplicate cases in switch statements.
//!
//! This rule identifies when switch statements have case branches that could
//! be merged together without affecting program behavior. It does _not_ check
//! that the value being switched over is the same; rather it checks whether
//! the target expressions are duplicates.
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! fn foo() void {
//!   const x = switch (1) {
//!     1 => 1,
//!     else => 1,
//!   };
//! }
//!
//! fn bar(y: u32) void {
//!   const x = switch (y) {
//!     1 => y + 1,
//!     2 => 1 + y,
//!     else => y * 2,
//!   };
//! }
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! fn foo() void {
//!   const x = switch (1) {
//!     1 => 1,
//!     2 => 2,
//!   };
//! }
//!
//! fn bar(y: u32) void {
//!   const x = switch (y) {
//!     1 => y + 1,
//!     2 => y * 2,
//!     3 => y - 1,
//!   };
//! }
//! ```

const std = @import("std");
const util = @import("util");
const ast_utils = @import("../ast_utils.zig");
const _source = @import("../../source.zig");
const _rule = @import("../rule.zig");
const _span = @import("../../span.zig");
const zig = @import("../../zig.zig").@"0.14.1";

const Loc = zig.Token.Loc;
const Span = _span.Span;
const LabeledSpan = _span.LabeledSpan;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const NodeWrapper = _rule.NodeWrapper;

const Semantic = @import("../../Semantic.zig");
const Ast = Semantic.Ast;
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const Symbol = Semantic.Symbol;
const Scope = Semantic.Scope;

const Error = @import("../../Error.zig");
const Cow = util.Cow(false);
const AstComparator = @import("../../visit/AstComparator.zig");

const DuplicateCase = @This();
pub const meta: Rule.Meta = .{
    .name = "duplicate-case",
    .category = .suspicious,
    .default = .off,
};

fn duplicateCaseDiagnostic(ctx: *LinterContext, first: Node.Index, second: Node.Index) Error {
    return ctx.diagnostic(
        "Switch statement has duplicate cases",
        .{ ctx.spanN(first), ctx.spanN(second) },
    );
}

pub fn runOnNode(_: *const DuplicateCase, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const ast = ctx.ast();
    const switchStmt = ast.fullSwitch(wrapper.idx) orelse return;
    const cases = switchStmt.ast.cases;

    // check each case statement against each other
    for (cases, 0..) |case, i| {
        for ((i + 1)..cases.len) |j| {
            const other = cases[j];
            const a = ast.fullSwitchCase(case) orelse unreachable;
            const b = ast.fullSwitchCase(other) orelse unreachable;
            if (AstComparator.eql(ast, a.ast.target_expr, b.ast.target_expr)) {
                ctx.report(duplicateCaseDiagnostic(ctx, case, other));
            }
        }
    }
}

pub fn rule(self: *DuplicateCase) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test DuplicateCase {
    const t = std.testing;

    var duplicate_case = DuplicateCase{};
    var runner = RuleTester.init(t.allocator, duplicate_case.rule());
    defer runner.deinit();

    const pass = &[_][:0]const u8{
        \\fn foo() void {
        \\  const x = switch (1) {
        \\    1 => 1,
        \\    2 => 2,
        \\    else => 3,
        \\  };
        \\}
        ,
        \\fn foo(y: u32) void {
        \\  const x = switch (1) {
        \\    1 => y - 1,
        \\    else => 1 - y,
        \\  };
        \\}
        ,
        // empty switch
        \\fn foo() void {
        \\  const x = switch (1) {
        \\  };
        \\}
        ,
        // calls
        \\ const thing = @import("./thing.zig");
        \\fn foo(bar: u32, cond: bool) u32 {
        \\  const x = switch (bar) {
        \\    1 => thing.f(bar),
        \\    2 => thing.g(bar),
        \\    else => 0,
        \\  };
        \\  return x;
        \\}
        ,
        \\ const thing = @import("./thing.zig");
        \\fn foo(bar: u32, cond: bool) u32 {
        \\  const x = switch (bar) {
        \\    1 => thing.f(bar),
        \\    2 => thing.f(bar, bar),
        \\    else => 0,
        \\  };
        \\  return x;
        \\}
        ,
        // if statements
        \\fn foo(bar: u32, cond: bool) u32 {
        \\  const x = switch (bar) {
        \\    1 => if (cond) 1 else 2,  
        \\    2 => if (cond) 2 else 1,  
        \\    else => 0
        \\  };
        \\  return x;
        \\}
        ,
    };

    const fail = &[_][:0]const u8{
        \\fn foo() void {
        \\  const x = switch (1) {
        \\    1 => 1,
        \\    else => 1,
        \\  };
        \\}
        ,
        // reflexive binary expressions
        \\fn foo(y: u32) void {
        \\  const x = switch (1) {
        \\    1 => y + 1,
        \\    else => 1 + y,
        \\  };
        \\}
        ,
        \\fn foo(y: u32) void {
        \\  const x = switch (y) {
        \\    1 => 1 * y + 1,
        \\    else => 1 + y * 1,
        \\  };
        \\}
        ,
        \\fn foo(y: u32) void {
        \\  const x = switch (1) {
        \\    1 => y == 1,
        \\    else => 1 == y,
        \\  };
        \\}
        ,
        \\fn foo(y: u32) void {
        \\  const x = switch (1) {
        \\    1 => ~y,
        \\    else => ~y,
        \\  };
        \\}
        ,

        // calls
        \\const thing = @import("./thing.zig");
        \\const f = thing.f;
        \\fn foo(bar: u32, cond: bool) u32 {
        \\  const x = switch (bar) {
        \\    1 => f(bar),
        \\    2 => f(bar),
        \\    else => 0,
        \\  };
        \\  return x;
        \\}
        ,
        \\const thing = @import("./thing.zig");
        \\fn foo(bar: u32, cond: bool) u32 {
        \\  const x = switch (bar) {
        \\    1 => thing.f(bar),
        \\    2 => thing.f(bar),
        \\    else => 0,
        \\  };
        \\  return x;
        \\}
        ,
        // if statements
        \\fn foo(bar: u32, cond: bool) u32 {
        \\  const x = switch (bar) {
        \\    1 => if (cond) 1 else 2,
        \\    2 => if (cond) 1 else 2,
        \\    else => 0
        \\  };
        \\  return x;
        \\}
        ,
        \\fn foo(bar: u32, cond: bool) u32 {
        \\  const x = switch (bar) {
        \\    1 => { return 1; },
        \\    2 => { return 1; },
        \\    else => 0
        \\  };
        \\  return x;
        \\}
        ,
        \\fn foo(bar: u32, cond: bool) u32 {
        \\  const x = switch (bar) {
        \\    1 => {
        \\      if (cond) {
        \\        const y = x + 2;
        \\        return y;
        \\      }
        \\      return 0;
        \\    },
        \\    2 => {
        \\      if (cond) {
        \\        const y = x + 2;
        \\        return y;
        \\      }
        \\      return 0;
        \\    },
        \\    else => 0
        \\  };
        \\  return x;
        \\}
        ,
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
