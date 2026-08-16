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
const _rule = @import("../rule.zig");

const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const NodeWrapper = _rule.NodeWrapper;

const Semantic = @import("../../Semantic.zig");
const Ast = Semantic.Ast;
const Node = Ast.Node;

const Error = @import("../../Error.zig");
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

            // Combining captured prongs can change the capture's peer-resolved
            // type. Without type information, assume captured prongs differ.
            if (a.payload_token != null or b.payload_token != null) continue;

            // An inline prong can observe values at comptime, so combining it
            // with a non-inline prong is not necessarily behavior preserving.
            if ((a.inline_token == null) != (b.inline_token == null)) continue;

            if (AstComparator.eql(ast, a.ast.target_expr, b.ast.target_expr)) {
                ctx.report(duplicateCaseDiagnostic(ctx, a.ast.target_expr, b.ast.target_expr));
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
        // Pointer captures with different bindings are not equivalent.
        \\fn foo(key: u8, optional: ?u32) void {
        \\  const x: u32 = 1;
        \\  _ = switch (key) {
        \\    1 => if (optional) |*x| x else null,
        \\    2 => if (optional) |*y| x else null,
        \\    else => null,
        \\  };
        \\}
        ,
        // Variable mutability is part of structural equality.
        \\fn foo(key: u8) void {
        \\  _ = switch (key) {
        \\    1 => { var value: u8 = 1; _ = &value; },
        \\    2 => { const value: u8 = 1; _ = &value; },
        \\    else => {},
        \\  };
        \\}
        ,
        \\fn foo(key: u8, value: u8) u8 {
        \\  return switch (key) {
        \\    1 => @max(value, 1),
        \\    2 => @min(value, 1),
        \\    else => 0,
        \\  };
        \\}
        ,
        \\fn foo(key: u8, values: []const u8) []const u8 {
        \\  return switch (key) {
        \\    1 => values[1..],
        \\    2 => values[2..],
        \\    else => values,
        \\  };
        \\}
        ,
        \\fn foo(key: u8) anyerror {
        \\  return switch (key) {
        \\    1 => error.Foo,
        \\    2 => error.Bar,
        \\    else => error.Baz,
        \\  };
        \\}
        ,
        // Captured payloads with identical target syntax can have different
        // peer-resolved types when their prongs are combined.
        \\const Value = union(enum) {
        \\  small: u8,
        \\  large: u64,
        \\};
        \\fn width(value: anytype) usize {
        \\  return @sizeOf(@TypeOf(value));
        \\}
        \\fn foo(value: Value) usize {
        \\  return switch (value) {
        \\    .small => |payload| width(payload),
        \\    .large => |payload| width(payload),
        \\  };
        \\}
        ,
        // Inline and non-inline prongs are not safely interchangeable.
        \\fn foo(value: u8) u8 {
        \\  return switch (value) {
        \\    inline 1 => 1,
        \\    2 => 1,
        \\    else => 0,
        \\  };
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
        // Ordered and unary expression families.
        \\fn foo(key: u8, first: u8, second: u8) bool {
        \\  return switch (key) {
        \\    1 => !(first < second),
        \\    2 => !(first < second),
        \\    else => false,
        \\  };
        \\}
        ,
        // Trailing commas do not change calls or builtin calls.
        \\fn foo(key: u8, value: u8) u8 {
        \\  return switch (key) {
        \\    1 => identity(value),
        \\    2 => identity(value,),
        \\    else => 0,
        \\  };
        \\}
        ,
        \\fn foo(key: u8, value: u8) u8 {
        \\  return switch (key) {
        \\    1 => @max(value, 1),
        \\    2 => @max(value, 1,),
        \\    else => 0,
        \\  };
        \\}
        ,
        // Array initializers and slices use normalized full-node data.
        \\fn foo(key: u8) [2]u8 {
        \\  return switch (key) {
        \\    1 => [_]u8{ 1, 2 },
        \\    2 => [_]u8{ 1, 2, },
        \\    else => .{ 0, 0 },
        \\  };
        \\}
        ,
        \\fn foo(key: u8, values: []const u8) []const u8 {
        \\  return switch (key) {
        \\    1 => values[1..],
        \\    2 => values[1..],
        \\    else => values,
        \\  };
        \\}
        ,
        // Multi-item prongs must highlight only the shared body, not every tag.
        \\fn foo(tag: u8) u8 {
        \\  return switch (tag) {
        \\    1, 2, 3, 4, 5,
        \\    6, 7, 8, 9, 10 => 0,
        \\    11 => 0,
        \\    else => 1,
        \\  };
        \\}
        ,
        // Same, but the shared body is a multi-line block.
        \\fn foo(tag: u8) u8 {
        \\  return switch (tag) {
        \\    1, 2, 3,
        \\    4, 5, 6 => {
        \\      const value = tag + 1;
        \\      return value;
        \\    },
        \\    7 => {
        \\      const value = tag + 1;
        \\      return value;
        \\    },
        \\    else => 0,
        \\  };
        \\}
        ,
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
