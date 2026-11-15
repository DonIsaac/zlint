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
//! fn bar() void {
//!     while (true) {
//!         break;
//!         std.debug.print("never printed", .{});
//!     }
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
const util = @import("util");
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
    // todo: make this `correctness
    .category = .nursery,
    .default = .err,
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

    for (flags, 0..) |flag, i| {
        if (!flag.b_unreachable or flag.b_entry or flag.b_exit) continue;
        const block_id: Cfg.BasicBlock.Id = .from(i);
        // Join blocks after an `if`/`switch` whose edges all exit won't have
        // instructions, and cleanup chains hanging off them only re-run
        // `defer`s.
        //
        // NOTE: we don't have type information, so we usually cannot tell if
        // `errdefers` are dead because `return`ing a fn call could
        // activate it if that fn returns an error union
        //
        // TODO: detect dead `errdefer`s in `!void` functions
        if (instructions[i].len == 0 or flag.b_cleanup) continue;
        if (!isRegionHead(cfg, flags, instructions, block_id)) continue;

        const node = cfg.instructionsOf(block_id).items(.node)[0];
        ctx.report(unreachableCodeDiagnostic(ctx, node));
    }
}

/// Report a dead region once, at its first block that carries code.
fn isRegionHead(
    cfg: *const Cfg,
    flags: []const Cfg.BasicBlock.Flags,
    instructions: []const Cfg.Instruction.Range,
    id: Cfg.BasicBlock.Id,
) bool {
    for (cfg.predecessorsOf(id)) |pred| {
        const p = pred.into(usize);
        if (flags[p].b_unreachable and instructions[p].len > 0) return false;
    }
    return true;
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
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
