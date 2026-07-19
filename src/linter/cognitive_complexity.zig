//! Cognitive complexity scoring, shared by the `cognitive-complexity` and
//! `cognitive-complexity-file` rules.
//!
//! Implements the SonarSource "Cognitive Complexity" white paper as realized
//! by gocognit and SonarSource's analyzers (rule S3776), mapped to Zig AST:
//!
//! - Structural increments (+1 + nesting, and raise nesting for their
//!   subtree): `if`, `while`, `for`, `switch`, and `catch` with a block
//!   handler.
//! - Hybrid increments (+1, do not raise nesting): `else if` and plain `else`
//!   (on both `if` and loops).
//! - Fundamental increments (+1): each maximal sequence of like `and`/`or`
//!   operators, labeled `break`/`continue`, and each direct self-recursive
//!   call.
//! - Ignored (shorthand): `orelse`, `try`, non-block `catch` handlers, early
//!   `return`, unlabeled `break`/`continue`, `defer`/`errdefer`.
//!
//! Functions are scored independently: code in a `fn` (or `test`) declared
//! inside a container inside a function body never rolls up into the
//! enclosing function's score.

const std = @import("std");
const Semantic = @import("../Semantic.zig");
const walk = @import("../visit/walk.zig");
const a = @import("ast_utils.zig");

const Ast = Semantic.Ast;
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const LinterContext = @import("lint_context.zig");

/// A single scored construct. Used to render secondary diagnostic labels.
pub const Increment = struct {
    /// The construct's keyword token (`if`, `while`, `catch`, ...).
    token: TokenIndex,
    /// Points added, including any nesting penalty.
    inc: u32,
    /// The nesting penalty included in `inc`. 0 for flat increments.
    nesting: u32,
};

pub const Result = struct {
    score: u32,
    /// Owned by the caller. Free with `ctx.gpa.free(result.increments)`.
    increments: []const Increment,
};

const Mode = enum {
    /// Score a single function body. Nested `fn`/`test` declarations are
    /// skipped; they are scored independently by their own `runOnNode`.
    function,
    /// Score an entire file. Nesting resets to 0 at each `fn`/`test`
    /// boundary, and all scores sum into one total.
    file,
};

/// Score the body of a `.fn_decl` or `.test_decl` node.
pub fn scoreFunction(ctx: *LinterContext, decl: Node.Index) Result {
    const ast = ctx.ast();
    const body = switch (ast.nodeTag(decl)) {
        .fn_decl => ast.nodeData(decl).node_and_node[1],
        .test_decl => ast.nodeData(decl).opt_token_and_node[1],
        else => unreachable,
    };

    var scorer = Scorer.new(ctx, .function);
    defer scorer.deinit();
    // Recursion context for the scored function. The walker starts at the
    // body, so `visit_fn_decl` never fires for the function itself.
    scorer.fn_stack.append(ctx.gpa, .{ .decl = decl, .saved_nesting = 0 }) catch @panic("OOM");

    var stack_alloc = std.heap.stackFallback(512, ctx.gpa);
    var walker = walk.Walker(Scorer, Scorer.VisitError).initAtNode(
        stack_alloc.get(),
        ast,
        &scorer,
        body,
    ) catch @panic("oom");
    defer walker.deinit();
    walker.walk() catch @panic("oom");

    return scorer.intoResult();
}

/// Score an entire source file: all functions, test blocks, and
/// container-level code (e.g. `comptime` blocks, global initializers).
pub fn scoreFile(ctx: *LinterContext) Result {
    var scorer = Scorer.new(ctx, .file);
    defer scorer.deinit();

    var stack_alloc = std.heap.stackFallback(512, ctx.gpa);
    var walker = walk.Walker(Scorer, Scorer.VisitError).init(
        stack_alloc.get(),
        ctx.ast(),
        &scorer,
    ) catch @panic("oom");
    defer walker.deinit();
    walker.walk() catch @panic("oom");

    return scorer.intoResult();
}

const Scorer = struct {
    ctx: *LinterContext,
    ast: *const Ast,
    mode: Mode,
    score: u32 = 0,
    nesting: u32 = 0,
    /// Nodes that raised nesting, unwound in `exitNode`.
    nesting_stack: std.ArrayListUnmanaged(Node.Index) = .empty,
    /// Enclosing functions, for recursion detection and file-mode nesting
    /// resets. Unwound in `exitNode`.
    fn_stack: std.ArrayListUnmanaged(FnContext) = .empty,
    /// `if` nodes that are the direct `else` child of another `if`, marked
    /// by their parent before they are visited.
    else_ifs: std.AutoHashMapUnmanaged(Node.Index, void) = .empty,
    /// `and`/`or` nodes continuing an already-counted operator sequence,
    /// marked by their parent before they are visited.
    logical_conts: std.AutoHashMapUnmanaged(Node.Index, void) = .empty,
    increments: std.ArrayListUnmanaged(Increment) = .empty,

    const FnContext = struct {
        decl: Node.Index,
        saved_nesting: u32,
    };

    pub const VisitError = error{};

    fn new(ctx: *LinterContext, mode: Mode) Scorer {
        return .{ .ctx = ctx, .ast = ctx.ast(), .mode = mode };
    }

    fn deinit(self: *Scorer) void {
        const gpa = self.ctx.gpa;
        self.nesting_stack.deinit(gpa);
        self.fn_stack.deinit(gpa);
        self.else_ifs.deinit(gpa);
        self.logical_conts.deinit(gpa);
        // not `self.increments`: ownership moves to the caller in intoResult
    }

    fn intoResult(self: *Scorer) Result {
        return .{
            .score = self.score,
            .increments = self.increments.toOwnedSlice(self.ctx.gpa) catch @panic("OOM"),
        };
    }

    /// Flat increment: +1, unaffected by nesting.
    fn addFlat(self: *Scorer, token: TokenIndex) void {
        self.score += 1;
        self.increments.append(self.ctx.gpa, .{ .token = token, .inc = 1, .nesting = 0 }) catch @panic("OOM");
    }

    /// Structural increment: +1 plus the current nesting level.
    fn addStructural(self: *Scorer, token: TokenIndex) void {
        const inc = 1 + self.nesting;
        self.score += inc;
        self.increments.append(self.ctx.gpa, .{ .token = token, .inc = inc, .nesting = self.nesting }) catch @panic("OOM");
    }

    fn pushNesting(self: *Scorer, node: Node.Index) void {
        self.nesting_stack.append(self.ctx.gpa, node) catch @panic("OOM");
        self.nesting += 1;
    }

    pub fn exitNode(self: *Scorer, node: Node.Index) void {
        if (self.nesting_stack.items.len > 0 and
            self.nesting_stack.items[self.nesting_stack.items.len - 1] == node)
        {
            _ = self.nesting_stack.pop();
            self.nesting -= 1;
            return;
        }
        if (self.fn_stack.items.len > 0 and
            self.fn_stack.items[self.fn_stack.items.len - 1].decl == node)
        {
            const fn_ctx = self.fn_stack.pop().?;
            self.nesting = fn_ctx.saved_nesting;
        }
    }

    pub fn visitIf(self: *Scorer, node: Node.Index, if_node: *const Ast.full.If) VisitError!walk.WalkState {
        if (self.else_ifs.contains(node)) {
            // `else if`: hybrid increment. Does not raise nesting; the
            // enclosing `if` already did.
            self.addFlat(if_node.ast.if_token);
        } else {
            self.addStructural(if_node.ast.if_token);
            self.pushNesting(node);
        }
        if (if_node.ast.else_expr.unwrap()) |else_expr| {
            switch (self.ast.nodeTag(else_expr)) {
                .@"if", .if_simple => self.else_ifs.put(self.ctx.gpa, else_expr, {}) catch @panic("OOM"),
                // plain `else`: hybrid increment
                else => self.addFlat(if_node.else_token),
            }
        }
        return .Continue;
    }

    pub fn visitWhile(self: *Scorer, node: Node.Index, while_node: *const Ast.full.While) VisitError!walk.WalkState {
        self.addStructural(while_node.ast.while_token);
        self.pushNesting(node);
        // `while (...) { ... } else { ... }`: hybrid increment
        if (while_node.ast.else_expr.unwrap() != null) self.addFlat(while_node.else_token);
        return .Continue;
    }

    pub fn visitFor(self: *Scorer, node: Node.Index, for_node: *const Ast.full.For) VisitError!walk.WalkState {
        self.addStructural(for_node.ast.for_token);
        self.pushNesting(node);
        // `for (...) { ... } else { ... }`: hybrid increment. Note
        // `else_token` is undefined unless `else_expr` is set.
        if (for_node.ast.else_expr.unwrap() != null) {
            self.addFlat(for_node.else_token orelse unreachable);
        }
        return .Continue;
    }

    pub fn visit_switch(self: *Scorer, node: Node.Index) VisitError!walk.WalkState {
        // A switch and all its cases combined are a single increment.
        self.addStructural(self.ast.nodeMainToken(node));
        self.pushNesting(node);
        return .Continue;
    }

    pub fn visit_switch_comma(self: *Scorer, node: Node.Index) VisitError!walk.WalkState {
        return self.visit_switch(node);
    }

    pub fn visit_bool_and(self: *Scorer, node: Node.Index) VisitError!walk.WalkState {
        return self.onBoolSequence(node);
    }

    pub fn visit_bool_or(self: *Scorer, node: Node.Index) VisitError!walk.WalkState {
        return self.onBoolSequence(node);
    }

    /// +1 for each maximal sequence of like binary logical operators:
    /// `a and b and c` is +1, `a and b or c` is +2.
    fn onBoolSequence(self: *Scorer, node: Node.Index) VisitError!walk.WalkState {
        if (self.logical_conts.contains(node)) return .Continue;
        self.addFlat(self.ast.nodeMainToken(node));
        const tag = self.ast.nodeTag(node);
        const data = self.ast.nodeData(node).node_and_node;
        inline for (.{ data[0], data[1] }) |child| {
            if (self.ast.nodeTag(child) == tag) {
                self.logical_conts.put(self.ctx.gpa, child, {}) catch @panic("OOM");
            }
        }
        return .Continue;
    }

    /// `catch` with a block handler is a catch clause. Shorthand handlers
    /// (`catch unreachable`, `catch return err`, `catch default`) are
    /// idiomatic control flow shorthand and do not increment.
    pub fn visit_catch(self: *Scorer, node: Node.Index) VisitError!walk.WalkState {
        const rhs = self.ast.nodeData(node).node_and_node[1];
        if (a.isBlock(self.ast, rhs)) {
            self.addStructural(self.ast.nodeMainToken(node));
            self.pushNesting(node);
        }
        return .Continue;
    }

    pub fn visit_break(self: *Scorer, node: Node.Index) VisitError!walk.WalkState {
        return self.onLabeledJump(node);
    }

    pub fn visit_continue(self: *Scorer, node: Node.Index) VisitError!walk.WalkState {
        return self.onLabeledJump(node);
    }

    /// Jumps to a label (`break :label`, `continue :label`) are +1. Other
    /// jumps and early exits (unlabeled `break`, early `return`) are free.
    fn onLabeledJump(self: *Scorer, node: Node.Index) VisitError!walk.WalkState {
        if (self.ast.nodeData(node).opt_token_and_opt_node[0].unwrap() != null) {
            self.addFlat(self.ast.nodeMainToken(node));
        }
        return .Continue;
    }

    pub fn visit_fn_decl(self: *Scorer, node: Node.Index) VisitError!walk.WalkState {
        return self.onFnBoundary(node);
    }

    pub fn visit_test_decl(self: *Scorer, node: Node.Index) VisitError!walk.WalkState {
        return self.onFnBoundary(node);
    }

    fn onFnBoundary(self: *Scorer, node: Node.Index) VisitError!walk.WalkState {
        switch (self.mode) {
            // Nested functions are scored independently by their own
            // `runOnNode`; never roll their complexity into the parent.
            .function => return .Skip,
            .file => {
                self.fn_stack.append(self.ctx.gpa, .{ .decl = node, .saved_nesting = self.nesting }) catch @panic("OOM");
                self.nesting = 0;
                return .Continue;
            },
        }
    }

    /// Direct self-recursion: +1 per recursive call site.
    pub fn visitCall(self: *Scorer, _: Node.Index, call: *const Ast.full.Call) VisitError!walk.WalkState {
        if (self.fn_stack.items.len == 0) return .Continue;
        const fn_ctx = self.fn_stack.items[self.fn_stack.items.len - 1];

        const callee = call.ast.fn_expr;
        if (self.ast.nodeTag(callee) != .identifier) return .Continue;
        const name_tok = self.ast.nodeMainToken(callee);

        const scope = self.ctx.links().getScope(callee) orelse return .Continue;
        const sym = self.ctx.semantic.resolveBinding(
            scope,
            self.ctx.semantic.tokenSlice(name_tok),
            .{ .exclude = .{ .s_variable = true } },
        ) orelse return .Continue;
        const decl = self.ctx.symbols().symbols.items(.decl)[sym.into(usize)];
        if (decl == fn_ctx.decl) self.addFlat(name_tok);
        return .Continue;
    }
};
