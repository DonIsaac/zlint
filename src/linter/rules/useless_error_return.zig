//! ## What This Rule Does
//! Explain what this rule checks for. Also explain why this is a problem.
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! ```

const std = @import("std");
const util = @import("util");
const _source = @import("../../source.zig");
const semantic = @import("../../semantic.zig");
const _rule = @import("../rule.zig");
const _span = @import("../../span.zig");
const a = @import("../ast_utils.zig");
const walk = @import("../../visit/walk.zig");

const Ast = std.zig.Ast;
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const Symbol = semantic.Symbol;
const Semantic = semantic.Semantic;
const Loc = std.zig.Loc;
const Span = _span.Span;
const LabeledSpan = _span.LabeledSpan;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const NodeWrapper = _rule.NodeWrapper;

const Error = @import("../../Error.zig");
const Cow = util.Cow(false);

// Rule metadata
const UselessErrorReturn = @This();
pub const meta: Rule.Meta = .{
    .name = "useless-error-return",
    // TODO: set the category to an appropriate value
    .category = .suspicious,
    .default = .warning,
};

fn neverErrorsDiagnostic(
    ctx: *LinterContext,
    fn_name: []const u8,
    fn_identifier: TokenIndex,
) Error {
    var e = ctx.diagnosticf(
        "Function '{s}' has an error union return type but never returns an error.",
        .{fn_name},
        .{ctx.labelT(fn_identifier, "'{s}' is declared here", .{fn_name})},
    );
    e.help = Cow.static("Remove the error union return type.");
    return e;
}

fn suppressesErrorsDiagnostic(
    ctx: *LinterContext,
    fn_name: []const u8,
    fn_identifier: TokenIndex,
    catch_node: Node.Index,
) Error {
    const main_tokens = ctx.ast().nodes.items(.main_token);
    var e = ctx.diagnosticf(
        "Function '{s}' has an error union return type but suppresses all its errors.",
        .{fn_name},
        .{
            ctx.labelT(fn_identifier, "'{s}' is declared here", .{fn_name}),
            ctx.labelT(main_tokens[catch_node], "It suppresses errors here", .{}),
        },
    );
    e.help = Cow.static("Use `try` to propagate errors to the caller.");
    return e;
}

pub fn runOnSymbol(_: *const UselessErrorReturn, symbol: Symbol.Id, ctx: *LinterContext) void {
    const nodes = ctx.ast().nodes;
    const symbols = ctx.symbols().symbols.slice();
    const symbol_flags: []const Symbol.Flags = symbols.items(.flags);
    const id = symbol.into(usize);

    // 1. look for function declarations

    const flags = symbol_flags[symbol.into(usize)];
    if (!flags.s_fn) return;

    // skip non-function declarations
    const tags: []const Node.Tag = nodes.items(.tag);
    const decl: Node.Index = symbols.items(.decl)[id];
    const tag: Node.Tag = tags[decl];
    if (tag != .fn_decl) return; // could be .fn_proto for e.g. fn types

    // skip declarations w/o a body (e.g. extern fns)
    const data: Node.Data = nodes.items(.data)[decl];
    const body = data.rhs;
    if (!a.isBlock(tags, body)) return;

    // 2. check if they return an error union

    var buf: [1]Node.Index = undefined;
    // SAFETY: LHS of a fn_decl is always some variant of fn_proto
    const fn_proto = ctx.ast().fullFnProto(&buf, data.lhs) orelse unreachable;
    util.debugAssert(fn_proto.ast.return_type != Semantic.NULL_NODE, "fns always have a return type", .{});
    if (!a.hasErrorUnion(ctx.ast(), fn_proto.ast.return_type)) return;

    // 3. look for fail-y things
    var visitor = Visitor{ .ast = ctx.ast() };
    {
        var arena = std.heap.ArenaAllocator.init(ctx.gpa);
        defer arena.deinit();
        var stackfb = std.heap.stackFallback(512, arena.allocator());
        const alloc = stackfb.get();

        var walker = walk.Walker(Visitor, error{}).init(alloc, ctx.ast(), &visitor) catch @panic("OOM");
        // walker.deinit() not needed b/c arena
        walker.walk() catch @panic("Walk failed");

        if (visitor.hasFallible()) return;
    }

    const fn_name = symbols.items(.name)[id];
    const fn_identifier: TokenIndex = symbols.items(.token)[id].unwrap().?.int();
    if (comptime util.IS_DEBUG)
        std.debug.assert(ctx.tokens().items(.tag)[fn_identifier] == .identifier);

    ctx.report(if (a.unwrapNode(visitor.first_catch)) |catch_node|
        suppressesErrorsDiagnostic(ctx, fn_name, fn_identifier, catch_node)
    else
        neverErrorsDiagnostic(ctx, fn_name, fn_identifier));
}

const Visitor = struct {
    curr_return: Node.Index = Semantic.NULL_NODE,
    first_catch: Node.Index = Semantic.NULL_NODE,
    /// seen `return foo()`;
    seen_return_call: bool = false,
    seen_error_value: bool = false,
    /// seen a `try` block
    seen_try: bool = false,
    ast: *const Ast,

    inline fn inReturn(self: *const Visitor) bool {
        return self.curr_return != Semantic.NULL_NODE;
    }

    inline fn hasFallible(self: *const Visitor) bool {
        return self.seen_return_call or self.seen_error_value or self.seen_try;
    }

    pub fn enterNode(self: *Visitor, node: Node.Index) void {
        // todo: nested returns/functions
        if (self.inReturn()) return;
        const tag: Node.Tag = self.ast.nodes.items(.tag)[node];
        if (tag == .@"return") self.curr_return = node;
    }

    pub fn exitNode(self: *Visitor, node: Node.Index) void {
        if (self.curr_return == node) {
            // TODO: @branchHint(.unlikely) after 0.14 is released
            util.debugAssert(node != Semantic.NULL_NODE, "null node should never be visited", .{});
            self.curr_return = Semantic.NULL_NODE;
        }
    }

    pub fn visit_try(self: *Visitor, _: Node.Index) error{}!walk.WalkState {
        self.seen_try = true;
        return .Stop;
    }

    pub fn visit_catch(self: *Visitor, node: Node.Index) error{}!walk.WalkState {
        if (self.first_catch == Semantic.NULL_NODE) {
            self.first_catch = node;
        }
        return .Continue;
    }

    pub fn visit_error_value(self: *Visitor, _: Node.Index) error{}!walk.WalkState {
        if (self.inReturn()) {
            self.seen_error_value = true;
            return .Stop;
        } else {
            return .Continue;
        }
    }

    pub fn visitCall(self: *Visitor, _: Node.Index, _: *const Ast.full.Call) error{}!walk.WalkState {
        if (self.curr_return == Semantic.NULL_NODE) {
            return .Continue;
        } else {
            self.seen_return_call = true;
            return .Stop;
        }
    }
};

// Used by the Linter to register the rule so it can be run.
pub fn rule(self: *UselessErrorReturn) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test UselessErrorReturn {
    const t = std.testing;

    var useless_error_return = UselessErrorReturn{};
    var runner = RuleTester.init(t.allocator, useless_error_return.rule());
    defer runner.deinit();

    // Code your rule should pass on
    const pass = &[_][:0]const u8{
        "fn foo() void { return; }",
        \\const std = @import("std");
        \\fn newList() ![]u8 { return std.heap.page_allocator.alloc(u8, 4); }
        \\fn foo() !void { return newList(); }
        ,
        \\fn positive(n: i32) !void {
        \\  if (n < 0) return error.NegativeNumber;
        \\}
        ,
        // TODO

        // \\fn foo() !void {
        // \\  bar() catch |e| switch (e) {
        // \\    error.OutOfMemory => @panic("OOM"),
        // \\    else => |e| return e,
        // \\  };
        // \\}
    };

    // Code your rule should fail on
    const fail = &[_][:0]const u8{
        "fn foo() !void { return; }",
        \\const std = @import("std");
        \\pub const Foo = struct {
        \\  pub fn init(allocator: std.mem.Allocator) !Foo {
        \\    const new = allocator.create(Foo) catch @panic("OOM");
        \\    new.* = .{};
        \\    return new;
        \\  }
        \\};
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
