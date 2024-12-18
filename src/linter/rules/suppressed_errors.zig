//! ## What This Rule Does
//! Disallows suppressing or otherwise mishandling caught errors.
//!
//! Functions that return error unions could error during "normal" execution.
//! If they didn't, they would not return an error or would panic instead.
//!
//! This rule enforces that errors are
//! 1. Propagated up to callers either implicitly or by returning a new error,
//!    ```zig
//!    const a = try foo();
//!    const b = foo catch |e| {
//!        switch (e) {
//!            FooError.OutOfMemory => error.OutOfMemory,
//!            // ...
//!        }
//!    }
//!    ```
//! 2. Are inspected and handled to continue normal execution
//!    ```zig
//!    /// It's fine if users are missing a config file, and open() + err
//!    // handling is faster than stat() then open()
//!    var config?: Config = openConfig() catch null;
//!    ```
//! 3. Caught and `panic`ed on to provide better crash diagnostics
//!    ```zig
//!    const str = try allocator.alloc(u8, size) catch @panic("Out of memory");
//!    ```
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! const x = foo() catch {};
//! const y = foo() catch {
//!   // comments within empty catch blocks are still considered violations.
//! };
//! // `unreachable` is for code that will never be reached due to invariants.
//! const y = foo() catch unreachable
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! const x = foo() catch @panic("foo failed.");
//! const y = foo() catch {
//!   std.debug.print("Foo failed.\n", .{});
//! };
//! const z = foo() catch null;
//! ```

const std = @import("std");
const _source = @import("../../source.zig");
const semantic = @import("../../semantic.zig");
const _rule = @import("../rule.zig");
const _span = @import("../../span.zig");

const Ast = std.zig.Ast;
const Node = Ast.Node;
const Symbol = semantic.Symbol;
const Loc = std.zig.Loc;
const Span = _span.Span;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const LabeledSpan = _span.LabeledSpan;
const NodeWrapper = _rule.NodeWrapper;
const NULL_NODE = semantic.Semantic.NULL_NODE;

// Rule metadata
const SuppressedErrors = @This();
pub const meta: Rule.Meta = .{
    .name = "suppressed-errors",
    .category = .suspicious,
    .default = .warning,
};

fn swallowedDiagnostic(ctx: *LinterContext, span: Span) void {
    const e = ctx.diagnostic(
        "`catch` statement suppresses errors",
        .{LabeledSpan{ .span = span }},
    );
    e.help = .{ .str = "Handle this error or propagate it to the caller with `try`." };
}

fn unreachableDiagnostic(ctx: *LinterContext, span: Span) void {
    const e = ctx.diagnostic(
        "Caught error is mishandled with `unreachable`",
        .{LabeledSpan{ .span = span }},
    );
    e.help = .{ .str = "Use `try` to propagate this error. If this branch shouldn't happen, use `@panic` or `std.debug.panic` instead." };
}

// Runs on each node in the AST. Useful for syntax-based rules.
pub fn runOnNode(_: *const SuppressedErrors, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const node = wrapper.node;
    if (node.tag != .@"catch") return;

    // const slice = ctx.ast().nodes.slice
    const ast = ctx.ast();
    const nodes = ast.nodes;
    const tags: []Node.Tag = nodes.items(.tag);

    const catch_body = node.data.rhs;
    switch (tags[catch_body]) {
        // .block is only ever constructed for blocks with > 2 statements.
        .block_two, .block_two_semicolon => {
            const stmts: Node.Data = nodes.items(.data)[catch_body];
            if (stmts.rhs != NULL_NODE) return;

            // `catch {}`
            if (stmts.lhs == NULL_NODE) {
                const body_span = ast.nodeToSpan(catch_body);
                const catch_keyword_start: u32 = ast.tokens.items(.start)[node.main_token];
                const span = Span.new(catch_keyword_start, body_span.end);
                swallowedDiagnostic(ctx, span);
                return;
            }
            switch (tags[stmts.lhs]) {
                .unreachable_literal => {
                    const span = ast.nodeToSpan(stmts.lhs);
                    unreachableDiagnostic(ctx, .{ .start = span.start, .end = span.end });
                },
                else => return,
            }
        },
        .unreachable_literal => {
            // lexeme() exists
            const unreachable_token = ast.nodes.items(.main_token)[catch_body];
            const start: u32 = ast.tokens.items(.start)[unreachable_token];
            unreachableDiagnostic(ctx, Span.sized(start, "unreachable".len));
        },
        else => return,
    }
}

// Used by the Linter to register the rule so it can be run.
pub fn rule(self: *SuppressedErrors) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test SuppressedErrors {
    const t = std.testing;

    var suppressed_errors = SuppressedErrors{};
    var runner = RuleTester.init(t.allocator, suppressed_errors.rule());
    defer runner.deinit();

    // Code your rule should pass on
    const pass = &[_][:0]const u8{
        // TODO: add test cases
        // "const x = 1",
        \\fn foo() void {
        \\  try bar();
        \\}
        ,
        \\fn foo() void {
        \\  bar() catch @panic("OOM");
        \\}
        ,
        \\ const std = @import("std");
        \\fn foo() void {
        \\  bar() catch std.debug.panic("OOM", .{});
        \\}
        ,
        \\fn foo() void {
        \\  bar() catch { std.debug.print("Something bad happened", .{}); };
        \\}
        ,
    };

    // Code your rule should fail on
    const fail = &[_][:0]const u8{
        // swallowed
        \\fn foo() void {
        \\  bar() catch {};
        \\}
        ,
        \\fn foo() void {
        \\  bar() catch |_| {};
        \\}
        ,
        \\fn foo() void {
        \\  bar() catch {
        \\    // ignore
        \\  };
        \\}
        ,
        // unreachable
        \\fn foo() void {
        \\  bar() catch unreachable;
        \\}
        ,
        \\fn foo() void {
        \\  bar() catch { unreachable; };
        \\}
        ,
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
