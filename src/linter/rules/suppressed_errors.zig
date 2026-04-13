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
//! // Writer errors may be safely ignored
//! writer.print("{}", .{5}) catch {};
//!
//! // suppression is allowed in tests
//! test foo {
//!   foo() catch {};
//! }
//! ```

const std = @import("std");
const util = @import("util");
const Semantic = @import("../../Semantic.zig");
const _rule = @import("../rule.zig");
const _span = @import("../../span.zig");
const a = @import("../ast_utils.zig");

const Ast = Semantic.Ast;
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const Span = _span.Span;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const LabeledSpan = _span.LabeledSpan;
const NodeWrapper = _rule.NodeWrapper;
const NULL_NODE = Semantic.NULL_NODE;
const Error = @import("../../Error.zig");
const Cow = util.Cow(false);

// Rule metadata
const SuppressedErrors = @This();
pub const meta: Rule.Meta = .{
    .name = "suppressed-errors",
    .category = .suspicious,
    .default = .warning,
};

fn swallowedDiagnostic(ctx: *LinterContext, span: Span) Error {
    var e = ctx.diagnostic(
        "`catch` statement suppresses errors",
        .{LabeledSpan{ .span = span }},
    );
    e.help = Cow.static("Handle this error or propagate it to the caller with `try`.");
    return e;
}

fn unreachableDiagnostic(ctx: *LinterContext, span: Span) Error {
    var e = ctx.diagnostic(
        "Caught error is mishandled with `unreachable`",
        .{LabeledSpan{ .span = span }},
    );
    e.help = Cow.static("Use `try` to propagate this error. If this branch shouldn't happen, use `@panic` or `std.debug.panic` instead.");
    return e;
}

// Runs on each node in the AST. Useful for syntax-based rules.
pub fn runOnNode(_: *const SuppressedErrors, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const node = wrapper.node;
    if (node.tag != .@"catch") return;

    const ast = ctx.ast();

    const caught, const catch_body = node.data.node_and_node;
    switch (ast.nodeTag(catch_body)) {
        // .block is only ever constructed for blocks with > 2 statements.
        .block_two, .block_two_semicolon => {
            // .block_two data is .opt_node_and_opt_node
            const first, const second = ast.nodeData(catch_body).opt_node_and_opt_node;
            if (second != .none) return;

            // `catch {}`
            const first_stmt = first.unwrap() orelse {
                if (isSuppressingWriterError(ctx, caught)) return;
                if (a.isInTest(ctx, wrapper.idx)) return;
                const body_span = ast.nodeToSpan(catch_body);
                const catch_keyword_start: u32 = ast.tokens.items(.start)[node.main_token];
                const span = Span.new(catch_keyword_start, body_span.end);
                ctx.report(swallowedDiagnostic(ctx, span));
                return;
            };
            switch (ast.nodeTag(first_stmt)) {
                .unreachable_literal => {
                    if (isSuppressingWriterError(ctx, caught)) return;
                    if (a.isInTest(ctx, wrapper.idx)) return;
                    const span = ast.nodeToSpan(first_stmt);
                    ctx.report(unreachableDiagnostic(ctx, .{ .start = span.start, .end = span.end }));
                },
                else => return,
            }
        },
        .unreachable_literal => {
            if (isSuppressingWriterError(ctx, caught)) return;
            if (a.isInTest(ctx, wrapper.idx)) return;
            const unreachable_token = ast.nodeMainToken(catch_body);
            const start: u32 = ast.tokens.items(.start)[unreachable_token];
            ctx.report(unreachableDiagnostic(ctx, Span.sized(start, "unreachable".len)));
        },
        else => return,
    }
}

/// Is this catch suppressing errors from a `Writer` method?
fn isSuppressingWriterError(ctx: *const LinterContext, caught: Node.Index) bool {
    const ast = ctx.ast();

    const callee = switch (ast.nodeTag(caught)) {
        // .call/.call_comma data is .node_and_extra: [0]=callee
        .call, .call_comma => ast.nodeData(caught).node_and_extra[0],
        // .call_one/.call_one_comma data is .node_and_opt_node: [0]=callee
        .call_one, .call_one_comma => ast.nodeData(caught).node_and_opt_node[0],
        else => return false,
    };

    switch (ast.nodeTag(callee)) {
        .field_access => {
            // .field_access data is .node_and_token: [1]=field_token
            const member: TokenIndex = ast.nodeData(callee).node_and_token[1];
            return printMethods.has(ast.tokenSlice(member));
        },
        else => return false,
    }
}

const printMethods = std.StaticStringMap(void).initComptime(&[_]struct { []const u8 }{
    .{"print"},
    .{"write"},
    .{"writeAll"},
    .{"writeByte"},
    .{"writeByteNTimes"}, // note: removed in 0.15
    .{"writeBytesNTimes"}, // note: removed in 0.15
    .{"writeStruct"},
    .{"writeStructEndian"},
});

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

    const pass = &[_][:0]const u8{
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
        // suppressing writer errors is allowed
        \\fn foo(w: Writer) void {
        \\  w.writeAll("") catch {};
        \\}
        ,
        \\fn foo(w: Writer) void {
        \\  w.writeAll("") catch unreachable;
        \\}
        ,
        \\fn foo(w: Writer) void {
        \\  w.writeAll("") catch { unreachable; };
        \\}
        ,
        \\fn foo(w: Writer) void {
        \\  w.writeByte('x') catch {};
        \\}
        ,
        \\fn foo(w: Writer) void {
        \\  w.print("{s}\n", "foo") catch {};
        \\}
        ,
        \\fn foo(bar: *Foo) void {
        \\  bar.baz.writeAll("") catch {};
        \\}
        ,
        // suppression in tests is allowed
        \\test bar {
        \\  bar() catch {};
        \\}
        ,
        \\test bar {
        \\  bar() catch unreachable;
        \\}
        ,
    };

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
        \\fn foo(w: Writer) void {
        \\  const x = blk: {
        \\    break :blk w.print("{}", .{5}); 
        \\  } catch unreachable;
        \\}
        ,
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
