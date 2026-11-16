//! ## What This Rule Does
//! Finds code that can never run because every path leading to it has already
//! exited: a `return`, `break`, `continue`, `unreachable`, or a call to a
//! `noreturn` function.
//!
//! Dead code is usually a leftover from a refactor. It misleads readers into
//! thinking it matters, and the compiler never checks that it still makes sense.
//!
//! `unreachable` statements themselves are not flagged; they are how Zig
//! documents that a path is impossible.
//!
//! ## Known Limitations
//! - ZLint does not support cross-file analysis, so `noreturn` functions
//!   declared in other files are not considered.
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! fn foo(x: u32) u32 {
//!     if (x > 10) {
//!         return 1;
//!     } else {
//!         return x;
//!     }
//!     return 3; // never runs
//! }
//!
//! fn fail() noreturn {
//!     @panic("oops");
//! }
//!
//! fn bar() void {
//!     fail();
//!     std.debug.print("never printed", .{});
//! }
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! fn foo(x: u32) u32 {
//!     if (x > 10) return 1;
//!     return x;
//! }
//!
//! fn bar(x: u32) u32 {
//!     switch (x) {
//!         0 => return 1,
//!         else => unreachable,
//!     }
//! }
//! ```

const std = @import("std");
const _rule = @import("../rule.zig");

const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;

const Semantic = @import("../../Semantic.zig");
const Cfg = Semantic.Cfg;
const Ast = Semantic.Ast;
const Node = Ast.Node;

const Error = @import("../../Error.zig");

const UnreachableCode = @This();
pub const meta: Rule.Meta = .{
    .name = "unreachable-code",
    // TODO: make this `correctness`
    .category = .nursery,
    .default = .off,
    .needs_cfg = true,
};

fn unreachableCodeDiagnostic(ctx: *LinterContext, node: Node.Index) Error {
    return ctx.diagnostic(
        "This code is unreachable.",
        .{ctx.labelN(node, "every path leading here has already exited", .{})},
    );
}

pub fn runOnce(_: *const UnreachableCode, ctx: *LinterContext) void {
    const cfg = ctx.cfg();
    const flags: []const Cfg.BasicBlock.Flags = cfg.blocks.items(.flags);
    const instructions: []const Cfg.Instruction.Range = cfg.blocks.items(.instructions);

    const first = for (flags, instructions, 0..) |flag, range, i| {
        if (isDeadCode(flag, range)) break i;
    } else return;

    // Dead blocks that other dead code flows into. A dead region is reported
    // once, at the code nothing else dead leads to.
    var downstream = std.DynamicBitSetUnmanaged.initEmpty(ctx.gpa, flags.len) catch @panic("OOM");
    defer downstream.deinit(ctx.gpa);
    var stack: std.ArrayList(Cfg.BasicBlock.Id) = .empty;
    defer stack.deinit(ctx.gpa);

    for (first..flags.len) |i| {
        if (downstream.isSet(i) or !isDeadCode(flags[i], instructions[i])) continue;
        stack.append(ctx.gpa, .from(i)) catch @panic("OOM");
        while (stack.pop()) |id| {
            for (cfg.successorsOf(id)) |edge| {
                // Otherwise a dead loop flows into its own header.
                if (edge.kind == .back) continue;
                const dest = edge.dest.into(usize);
                if (!flags[dest].b_unreachable or downstream.isSet(dest)) continue;
                downstream.set(dest);
                stack.append(ctx.gpa, edge.dest) catch @panic("OOM");
            }
        }
    }

    // Join blocks are created before the branches that flow into them, so
    // reporting must wait until every region has been walked.
    for (first..flags.len) |i| {
        if (downstream.isSet(i) or !isDeadCode(flags[i], instructions[i])) continue;
        const node = cfg.instructionsOf(.from(i)).items(.node)[0];
        ctx.report(unreachableCodeDiagnostic(ctx, node));
    }
}

/// A dead block holding code the user wrote. Cleanup blocks only replay
/// `defer` bodies, which are lowered on their own.
///
/// NOTE: we don't have type information, so we usually cannot tell if
/// `errdefer`s are dead because `return`ing a fn call could activate them if
/// that fn returns an error union.
///
/// TODO: detect dead `errdefer`s in `!void` functions
fn isDeadCode(flags: Cfg.BasicBlock.Flags, instructions: Cfg.Instruction.Range) bool {
    return flags.b_unreachable and !flags.b_cleanup and instructions.len > 0;
}

pub fn rule(self: *UnreachableCode) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test UnreachableCode {
    const t = std.testing;

    var unreachable_code = UnreachableCode{};
    var runner = RuleTester.init(t.allocator, unreachable_code.rule());
    defer runner.deinit();

    const pass = &[_][:0]const u8{
        \\fn foo(x: u32) u32 {
        \\    if (x > 10) {
        \\        return 1;
        \\    } else {
        \\        return x;
        \\    }
        \\}
        ,
        \\fn foo(x: u32) u32 {
        \\    switch (x) {
        \\        0 => return 1,
        \\        else => unreachable,
        \\    }
        \\}
        ,
        \\fn foo(x: anyerror!u32) u32 {
        \\    const y = x catch |e| switch (e) {
        \\        error.OutOfMemory => return 0,
        \\        else => return 1,
        \\    };
        \\    return y;
        \\}
        ,
        \\fn foo() void {
        \\    defer {
        \\        for (0..3) |_| bar();
        \\        if (baz()) qux() else quux();
        \\    }
        \\    bar();
        \\}
        ,
        \\fn foo() !void {
        \\    errdefer if (bar()) |b| {
        \\        for (b) |x| x.deinit();
        \\    };
        \\    try baz();
        \\}
        ,
        "fn foo() noreturn { unreachable; }",
        \\fn foo(x: u32) u32 {
        \\    defer bar();
        \\    if (x > 10) {
        \\        return 1;
        \\    } else {
        \\        return x;
        \\    }
        \\}
        ,
        // the error path of a `!noreturn` call falls through
        \\fn foo() void {
        \\    serve() catch {};
        \\    bar();
        \\}
        \\fn serve() !noreturn {
        \\    return error.Oops;
        \\}
        ,
        // method calls only resolve against the receiver's own container
        \\fn die() noreturn {
        \\    @panic("oops");
        \\}
        \\const S = struct {
        \\    fn die() void {}
        \\};
        \\fn foo(s: anytype, ss: []const S) void {
        \\    S.die();
        \\    s.die();
        \\    ss.die();
        \\    bar();
        \\}
        ,
    };

    const fail = &[_][:0]const u8{
        \\fn foo(x: u32) u32 {
        \\    if (x > 10) {
        \\        return 1;
        \\    } else {
        \\        return x;
        \\    }
        \\    return 3;
        \\}
        ,
        "fn foo() u32 { return 1; return 2; }",
        \\fn foo() void {
        \\    while (true) {
        \\        break;
        \\        bar();
        \\    }
        \\}
        ,
        \\fn foo() void {
        \\    return;
        \\    while (bar()) {
        \\        baz();
        \\    }
        \\    qux();
        \\}
        ,
        \\fn foo(x: u32) void {
        \\    switch (x) {
        \\        0 => return,
        \\        else => unreachable,
        \\    }
        \\    bar();
        \\}
        ,
        \\fn foo() void {
        \\    defer {
        \\        return;
        \\        bar();
        \\    }
        \\}
        ,
        \\fn die() noreturn {
        \\    @panic("oops");
        \\}
        \\fn foo() void {
        \\    die();
        \\    bar();
        \\}
        ,
        // one region: empty branch arms must not split it
        \\fn foo(x: bool) void {
        \\    if (x) return else return;
        \\    if (x) bar() else baz();
        \\    qux();
        \\}
        ,
        // dead code reached only through an empty, dead join
        \\fn foo(x: bool, y: bool) void {
        \\    if (x) {
        \\        if (y) return else return;
        \\    } else return;
        \\    bar();
        \\}
        ,
        \\fn foo(x: bool) void {
        \\    die();
        \\    if (x) bar();
        \\}
        \\fn die() noreturn {
        \\    @panic("oops");
        \\}
        ,
        \\fn foo() !void {
        \\    die();
        \\    try bar();
        \\}
        \\fn die() noreturn {
        \\    @panic("oops");
        \\}
        ,
        \\fn foo() void {
        \\    defer {
        \\        die();
        \\        bar();
        \\    }
        \\}
        \\fn die() noreturn {
        \\    @panic("oops");
        \\}
        ,
        // TODO: needs the callee's return type while lowering `try`/`catch`,
        // which a separate reference binding pass will provide.
        // \\fn foo() !void {
        // \\    try serve();
        // \\    bar();
        // \\}
        // \\fn serve() !noreturn {
        // \\    return error.Oops;
        // \\}
        // ,
        // \\fn foo() void {
        // \\    serve() catch return;
        // \\    bar();
        // \\}
        // \\fn serve() error{Oops}!noreturn {
        // \\    return error.Oops;
        // \\}
        // ,
        \\fn foo(comptime T: type) void {
        \\    if (T == u8) @compileError("a") else @compileError("b");
        \\    bar();
        \\}
        ,
        // TODO: needs member lookup on a receiver while lowering calls, which
        // a separate reference binding pass will provide.
        // \\const Self = @This();
        // \\fn foo() void {
        // \\    Self.die();
        // \\    bar();
        // \\}
        // \\fn die() noreturn {
        // \\    @panic("oops");
        // \\}
        // ,
        // \\const S = struct {
        // \\    fn foo(self: *const S) void {
        // \\        self.die();
        // \\        bar();
        // \\    }
        // \\    fn die(_: S) noreturn {
        // \\        @panic("oops");
        // \\    }
        // \\};
        // ,
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
