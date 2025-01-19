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
//! ```

const std = @import("std");
const util = @import("util");
const semantic = @import("../../semantic.zig");
const _rule = @import("../rule.zig");
const _span = @import("../../span.zig");

const Ast = std.zig.Ast;
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const Span = _span.Span;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const LabeledSpan = _span.LabeledSpan;
const NodeWrapper = _rule.NodeWrapper;
const NULL_NODE = semantic.Semantic.NULL_NODE;
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

    // const slice = ctx.ast().nodes.slice
    const ast = ctx.ast();
    const nodes = ast.nodes;
    const tags: []Node.Tag = nodes.items(.tag);

    const catch_body = node.data.rhs;
    const caught = node.data.lhs;
    switch (tags[catch_body]) {
        // .block is only ever constructed for blocks with > 2 statements.
        .block_two, .block_two_semicolon => {
            const stmts: Node.Data = nodes.items(.data)[catch_body];
            if (stmts.rhs != NULL_NODE) return;

            // `catch {}`
            if (stmts.lhs == NULL_NODE) {
                if (isSuppressingWriterError(ctx, caught)) return;
                const body_span = ast.nodeToSpan(catch_body);
                const catch_keyword_start: u32 = ast.tokens.items(.start)[node.main_token];
                const span = Span.new(catch_keyword_start, body_span.end);
                ctx.report(swallowedDiagnostic(ctx, span));
                return;
            }
            switch (tags[stmts.lhs]) {
                .unreachable_literal => {
                    if (isSuppressingWriterError(ctx, caught)) return;
                    const span = ast.nodeToSpan(stmts.lhs);
                    ctx.report(unreachableDiagnostic(ctx, .{ .start = span.start, .end = span.end }));
                },
                else => return,
            }
        },
        .unreachable_literal => {
            if (isSuppressingWriterError(ctx, caught)) return;
            // lexeme() exists
            const unreachable_token = ast.nodes.items(.main_token)[catch_body];
            const start: u32 = ast.tokens.items(.start)[unreachable_token];
            ctx.report(unreachableDiagnostic(ctx, Span.sized(start, "unreachable".len)));
        },
        else => return,
    }
}

/// Is this catch suppressing errors from a `Writer` method?
fn isSuppressingWriterError(ctx: *const LinterContext, caught: Node.Index) bool {
    const nodes = ctx.ast().nodes;
    const tags: []const Node.Tag = nodes.items(.tag);
    const datas: []const Node.Data = nodes.items(.data);

    switch (tags[caught]) {
        .call,
        .call_one,
        .call_one_comma,
        => {
            const callee = datas[caught].lhs;
            std.debug.assert(callee != NULL_NODE);
            switch (tags[callee]) {
                .field_access => {
                    // identifier token
                    const member: TokenIndex = datas[callee].rhs;
                    std.debug.assert(member != NULL_NODE);
                    return printMethods.has(ctx.ast().tokenSlice(member));
                },
                else => return false,
            }
        },
        else => |tag| {
            std.debug.print("{any}\n", .{tag});
            return false;
        },
    }
    unreachable;
}

const printMethods = std.StaticStringMap(void).initComptime(&[_]struct { []const u8 }{
    .{"print"},
    .{"write"},
    .{"writeAll"},
    .{"writeByte"},
    .{"writeByteNTimes"},
    .{"writeBytesNTimes"},
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
