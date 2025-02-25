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

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Token = Semantic.Token;
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
const assert = std.debug.assert;

// Rule metadata
const UselessErrorReturn = @This();
pub const meta: Rule.Meta = .{
    .name = "useless-error-return",
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
            ctx.labelT(main_tokens[catch_node], "It catches errors here", .{}),
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
    const datas: []const Node.Data = nodes.items(.data);
    const data: Node.Data = datas[decl];
    const body = data.rhs;
    if (!a.isBlock(tags, body)) return;

    // 2. check if they return an error union

    var buf: [1]Node.Index = undefined;
    // SAFETY: LHS of a fn_decl is always some variant of fn_proto
    const fn_proto = ctx.ast().fullFnProto(&buf, data.lhs) orelse unreachable;
    util.debugAssert(fn_proto.ast.return_type != Semantic.NULL_NODE, "fns always have a return type", .{});
    const err_type = a.unwrapNode(a.getErrorUnion(ctx.ast(), fn_proto.ast.return_type)) orelse return;

    // allow for `error{}!ty` return types
    // len check is a hack b/c something is returning a token index when it
    // should be a node index
    if (err_type < ctx.ast().nodes.len and tags[err_type] == .error_union) {
        const left = datas[err_type].lhs;
        if (tags[left] == .error_set_decl) {
            const maybe_lbrace = datas[left].rhs -| 1;
            if (ctx.ast().tokens.items(.tag)[maybe_lbrace] == .l_brace) return;
        }
    }

    // 3. look for fail-y things
    // var visitor = Visitor{ .ast = ctx.ast(), .err_stack = std.ArrayList.init(Allocator.heap()) };
    var visitorfb = std.heap.stackFallback(8, ctx.gpa);
    var visitor = Visitor.init(ctx.ast(), visitorfb.get());
    defer visitor.err_stack.deinit();
    {
        var arena = std.heap.ArenaAllocator.init(ctx.gpa);
        defer arena.deinit();
        var stackfb = std.heap.stackFallback(512, arena.allocator());
        const alloc = stackfb.get();

        var walker = walk.Walker(Visitor, Visitor.VisitError).init(alloc, ctx.ast(), &visitor) catch @panic("OOM");
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
    ast: *const Ast,

    // state
    curr_return: Node.Index = Semantic.NULL_NODE,
    err_stack: std.ArrayList(ErrState),

    seen_return_call: bool = false, // seen `return foo()`;
    seen_error_value: bool = false, // seen `error.Foo`
    seen_try: bool = false, //         seen a try expression
    seen_return_err: bool = false, //  seen return of err payload variable

    /// location of first `catch` block found. used for error reporting.
    first_catch: Node.Index = Semantic.NULL_NODE,

    const ErrState = struct {
        // may be `null` if catch has no payload
        payload: TokenIndex,
        /// Node that produced the error payload. usually a catch, but
        /// can be a switch case when switching over errors.
        node: Node.Index,
    };
    const VisitError = Allocator.Error;

    fn init(ast: *const Ast, alloc: Allocator) Visitor {
        return Visitor{
            .ast = ast,
            .err_stack = std.ArrayList(ErrState).init(alloc),
        };
    }

    inline fn inReturn(self: *const Visitor) bool {
        return self.curr_return != Semantic.NULL_NODE;
    }

    inline fn inCatch(self: *const Visitor) bool {
        return self.err_stack.items.len > 0;
    }

    inline fn hasFallible(self: *const Visitor) bool {
        return self.seen_return_call or
            self.seen_error_value or
            self.seen_try or
            self.seen_return_err;
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
        } else if (self.err_stack.getLastOrNull()) |err| {
            if (err.node == node) {
                _ = self.err_stack.pop();
            }
        }
    }

    pub fn visit_try(self: *Visitor, _: Node.Index) VisitError!walk.WalkState {
        self.seen_try = true;
        return .Stop;
    }

    pub fn visit_error_value(self: *Visitor, _: Node.Index) VisitError!walk.WalkState {
        if (self.inReturn()) {
            self.seen_error_value = true;
            return .Stop;
        }
        return .Continue;
    }

    /// look for switches over error payloads and push them into the error stack
    ///
    /// ```zig
    /// catch |e| switch (e)
    ///   // ...
    ///   else => |e| someExpression,
    /// //         ^
    /// }
    /// ```
    pub fn visit_switch_case_one(self: *Visitor, node: Node.Index) VisitError!walk.WalkState {
        if (!self.inCatch()) return .Continue;
        // LHS being null means `else` branch
        if (self.ast.nodes.items(.data)[node].lhs != Semantic.NULL_NODE) return .Continue;

        const tok_tags: []const Token.Tag = self.ast.tokens.items(.tag);

        const main_tok: TokenIndex = self.ast.nodes.items(.main_token)[node];
        if (tok_tags[main_tok + 1] != .pipe) return .Continue;

        const identifier = main_tok + 2;
        if (comptime util.IS_DEBUG) assert(tok_tags[identifier] == .identifier);
        try self.err_stack.append(ErrState{ .node = node, .payload = identifier });

        return .Continue;
    }

    pub fn visit_switch_case_one_inline(self: *Visitor, node: Node.Index) VisitError!walk.WalkState {
        return self.visit_switch_case_one(self, node);
    }

    pub fn visit_catch(self: *Visitor, node: Node.Index) VisitError!walk.WalkState {
        if (self.first_catch == Semantic.NULL_NODE) {
            self.first_catch = node;
        }

        const data: Node.Data = self.ast.nodes.items(.data)[node];
        const fallback_first: TokenIndex = self.ast.firstToken(data.rhs);

        const tok_tags: []const Token.Tag = self.ast.tokens.items(.tag);
        const main_token = self.ast.nodes.items(.main_token)[node];
        // look for `catch |e|`, add `e` to the stack
        if (tok_tags[fallback_first -| 1] == .pipe) {
            const payload = main_token + 2;
            if (comptime util.IS_DEBUG) std.debug.assert(tok_tags[payload] == .identifier);
            try self.err_stack.append(ErrState{ .payload = payload, .node = node });
        }

        return .Continue;
    }

    pub fn visit_identifier(self: *Visitor, node: Node.Index) VisitError!walk.WalkState {
        if (!self.inReturn()) return .Continue;

        for (self.err_stack.items) |curr_err| {
            const ident_token = self.ast.nodes.items(.main_token)[node];
            const payload_name = self.ast.tokenSlice(curr_err.payload);
            const ident_name = self.ast.tokenSlice(ident_token);
            if (std.mem.eql(u8, payload_name, ident_name)) {
                self.seen_error_value = true;
                return .Stop;
            }
        }

        return .Continue;
    }

    pub fn visitCall(self: *Visitor, _: Node.Index, _: *const Ast.full.Call) VisitError!walk.WalkState {
        if (self.curr_return == Semantic.NULL_NODE) return .Continue;

        self.seen_return_call = true;
        return .Stop;
    }
};

pub fn rule(self: *UselessErrorReturn) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test UselessErrorReturn {
    const t = std.testing;

    var useless_error_return = UselessErrorReturn{};
    var runner = RuleTester.init(t.allocator, useless_error_return.rule());
    defer runner.deinit();

    const pass = &[_][:0]const u8{
        "fn foo() void { return; }",
        "fn foo() !void { return error.Oops; }",
        "fn foo() !void { return bar(); }",
        "fn foo() !void { bar() catch |e| return e; }",
        "fn foo(x: bool) !void { return if (x) error.Oops else {};  }",
        \\const std = @import("std");
        \\fn newList() ![]u8 { return std.heap.page_allocator.alloc(u8, 4); }
        \\fn foo() !void { return newList(); }
        ,
        \\fn foo() !void {
        \\  bar() catch |err| switch (err) {
        \\    error.OutOfMemory => @panic("OOM"),
        \\    else => |e| return e,
        \\  };
        \\}
        ,
        // functions explicitly returning empty error sets are allowed
        "fn foo() error{}!void { }",
    };

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
