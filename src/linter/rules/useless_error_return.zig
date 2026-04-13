//! ## What This Rule Does
//!
//! Detects functions that have an error union return type but never actually return an error.
//! This can happen in two ways:
//! 1. The function never returns an error value
//! 2. The function catches all errors internally and never propagates them to the caller
//!
//! Having an error union return type when errors are never returned makes the code less clear
//! and forces callers to handle errors that will never occur.
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! // Function declares error return but only returns void
//! fn foo() !void {
//!     return;
//! }
//!
//! // Function catches all errors internally
//! pub fn init(allocator: std.mem.Allocator) !Foo {
//!     const new = allocator.create(Foo) catch @panic("OOM");
//!     new.* = .{};
//!     return new;
//! }
//!
//! // Function only returns success value
//! fn bar() !void {
//!     const e = baz();
//!     return e;
//! }
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! // Function properly propagates errors
//! fn foo() !void {
//!     return error.Oops;
//! }
//!
//! // Function returns result of fallible operation
//! fn bar() !void {
//!     return baz();
//! }
//!
//! // Function propagates caught errors
//! fn qux() !void {
//!     bar() catch |e| return e;
//! }
//!
//! // Function with conditional error return
//! fn check(x: bool) !void {
//!     return if (x) error.Invalid else {};
//! }
//!
//! // Empty error set is explicitly allowed
//! fn noErrors() error{}!void {}
//! ```

const std = @import("std");
const util = @import("util");

const Semantic = @import("../../Semantic.zig");
const _rule = @import("../rule.zig");
const a = @import("../ast_utils.zig");
const walk = @import("../../visit/walk.zig");

const Allocator = std.mem.Allocator;

const Ast = Semantic.Ast;
const Node = Ast.Node;
const Token = Semantic.Token;
const TokenIndex = Ast.TokenIndex;
const Symbol = Semantic.Symbol;

const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;

const Error = @import("../../Error.zig");
const Cow = util.Cow(false);
const assert = std.debug.assert;

// Rule metadata
const UselessErrorReturn = @This();
pub const meta: Rule.Meta = .{
    .name = "useless-error-return",
    .category = .suspicious,
    .default = .off, // TODO: change to .warning when we're its stable
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
    var e = ctx.diagnosticf(
        "Function '{s}' has an error union return type but suppresses all its errors.",
        .{fn_name},
        .{
            ctx.labelT(fn_identifier, "'{s}' is declared here", .{fn_name}),
            ctx.labelT(ctx.ast().nodeMainToken(catch_node), "It catches errors here", .{}),
        },
    );
    e.help = Cow.static("Use `try` to propagate errors to the caller.");
    return e;
}

pub fn runOnSymbol(_: *const UselessErrorReturn, symbol: Symbol.Id, ctx: *LinterContext) void {
    const ast = ctx.ast();
    const symbols = ctx.symbols().symbols.slice();
    const symbol_flags: []const Symbol.Flags = symbols.items(.flags);
    const id = symbol.into(usize);

    // 1. look for function declarations

    const flags = symbol_flags[symbol.into(usize)];
    if (!flags.s_fn) return;

    // skip non-function declarations
    const decl: Node.Index = symbols.items(.decl)[id];
    const tag: Node.Tag = ast.nodeTag(decl);
    if (tag != .fn_decl) return; // could be .fn_proto for e.g. fn types

    // skip declarations w/o a body (e.g. extern fns)
    const decl_data = ast.nodeData(decl).node_and_node;
    const body = decl_data[1];
    if (!a.isBlock(ast, body)) return;

    // 2. check if they return an error union

    var buf: [1]Node.Index = undefined;
    const fn_proto = ast.fullFnProto(&buf, decl_data[0]) orelse unreachable;
    const return_type = fn_proto.ast.return_type.unwrap() orelse unreachable;
    const err_type: Node.Index = a.unwrapNode(a.getErrorUnion(ast, return_type)) orelse return;
    const err_ident: ?[]const u8 = switch (ast.nodeTag(err_type)) {
        .error_union => blk: {
            const eu_data = ast.nodeData(err_type).node_and_node;
            const error_expr = a.unwrapNode(eu_data[0]) orelse break :blk null;
            break :blk switch (ast.nodeTag(error_expr)) {
                .identifier => ast.getNodeSource(error_expr),
                .field_access => ctx.semantic.tokenSlice(ast.nodeData(error_expr).node_and_token[1]),
                .error_set_decl => ctx.semantic.tokenSlice(ast.nodeMainToken(error_expr)),
                else => null,
            };
        },
        else => null,
    };

    // allow for `error{}!ty` return types
    if (@intFromEnum(err_type) < ast.nodes.len and ast.nodeTag(err_type) == .error_union) {
        const left = ast.nodeData(err_type).node_and_node[0];
        if (ast.nodeTag(left) == .error_set_decl) {
            const maybe_lbrace = ast.nodeData(left).token_and_token[1] -| 1;
            if (ast.tokens.items(.tag)[maybe_lbrace] == .l_brace) return;
        }
    }

    // 3. look for fail-y things
    var visitorfb = std.heap.stackFallback(8, ctx.gpa);
    var visitor = Visitor.init(ctx.ast(), err_ident, visitorfb.get());
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
    err_stack: std.array_list.Managed(ErrState),

    /// Known name of error type.
    ///
    /// ```zig
    /// fn foo() Error!void { ... }
    /// //       ^^^^^
    /// ```
    ///
    /// This is the rightmost identifier for member expressions. We make a
    /// best-effort attempt to find this. it may also not be present (`!void`)
    err_name: ?[]const u8,

    seen: Seen = .{},

    /// location of first `catch` block found. used for error reporting.
    first_catch: Node.Index = Semantic.NULL_NODE,

    const Seen = packed struct {
        return_call: bool = false, // `return foo()`;
        error_value: bool = false, // `error.Foo`
        @"try": bool = false, // try expression
        return_err: bool = false, // return of err payload variable
        container_field_named_error: bool = false, // MyStruct.SomeError
        known_error_struct_access: bool = false, // `fn foo() SomeError!anytype { return SomeError.DoesNotLookLikeError; }

        const Repr = @typeInfo(Seen).@"struct".backing_integer orelse {
            @compileError("packed structs should have backing integer");
        };

        inline fn seenAny(self: Seen) bool {
            return @as(Repr, @bitCast(self)) > 0;
        }
    };

    const ErrState = struct {
        // may be `null` if catch has no payload
        payload: TokenIndex,
        /// Node that produced the error payload. usually a catch, but
        /// can be a switch case when switching over errors.
        node: Node.Index,
    };
    const VisitError = Allocator.Error;

    fn init(ast: *const Ast, err_name: ?[]const u8, alloc: Allocator) Visitor {
        return Visitor{
            .ast = ast,
            .err_name = err_name,
            .err_stack = std.array_list.Managed(ErrState).init(alloc),
        };
    }

    inline fn inReturn(self: *const Visitor) bool {
        return self.curr_return != Semantic.NULL_NODE;
    }

    inline fn inCatch(self: *const Visitor) bool {
        return self.err_stack.items.len > 0;
    }

    inline fn hasFallible(self: *const Visitor) bool {
        return self.seen.seenAny();
    }

    pub fn enterNode(self: *Visitor, node: Node.Index) void {
        // todo: nested returns/functions
        if (self.inReturn()) return;
        if (self.ast.nodeTag(node) == .@"return") self.curr_return = node;
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
        self.seen.@"try" = true;
        return .Stop;
    }

    pub fn visit_error_value(self: *Visitor, _: Node.Index) VisitError!walk.WalkState {
        if (self.inReturn()) {
            self.seen.error_value = true;
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
        // LHS being .none means `else` branch
        const case_data = self.ast.nodeData(node).opt_node_and_node;
        if (case_data[0] != .none) return .Continue;

        const tok_tags: []const Token.Tag = self.ast.tokens.items(.tag);

        const main_tok: TokenIndex = self.ast.nodeMainToken(node);
        if (tok_tags[main_tok + 1] != .pipe) return .Continue;

        const identifier = main_tok + 2;
        if (comptime util.IS_DEBUG) assert(tok_tags[identifier] == .identifier);
        try self.err_stack.append(ErrState{ .node = node, .payload = identifier });

        return .Continue;
    }

    pub fn visit_switch_case_one_inline(self: *Visitor, node: Node.Index) VisitError!walk.WalkState {
        return self.visit_switch_case_one(node);
    }

    pub fn visit_catch(self: *Visitor, node: Node.Index) VisitError!walk.WalkState {
        if (self.first_catch == Semantic.NULL_NODE) {
            self.first_catch = node;
        }

        const catch_data = self.ast.nodeData(node).node_and_node;
        const fallback_first: TokenIndex = self.ast.firstToken(catch_data[1]);

        const tok_tags: []const Token.Tag = self.ast.tokens.items(.tag);
        const main_token = self.ast.nodeMainToken(node);
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
            const ident_token = self.ast.nodeMainToken(node);
            const payload_name = self.ast.tokenSlice(curr_err.payload); // fixme: this re-tokenizes
            const ident_name = self.ast.tokenSlice(ident_token);
            if (std.mem.eql(u8, payload_name, ident_name)) {
                self.seen.error_value = true;
                return .Stop;
            }
        }

        return .Continue;
    }

    pub fn visit_field_access(self: *Visitor, node: Node.Index) VisitError!walk.WalkState {
        if (!self.inReturn()) return .Continue;

        const fa_data = self.ast.nodeData(node).node_and_token;
        const obj = fa_data[0];
        const field_token = fa_data[1];

        const field_name = self.ast.tokenSlice(field_token);
        if (std.ascii.endsWithIgnoreCase(field_name, "error")) {
            self.seen.container_field_named_error = true;
            return .Stop;
        }

        const err_name = self.err_name orelse return .Continue;

        switch (self.ast.nodeTag(obj)) {
            .identifier => {
                const ident = self.ast.getNodeSource(obj);
                if (std.mem.eql(u8, err_name, ident)) {
                    self.seen.known_error_struct_access = true;
                    return .Stop;
                }
            },
            .container_field => {
                // `SomeNamespace.SomeStruct.SomeError` <-- and we saw SomeError in return signature
                if (std.mem.eql(
                    u8,
                    self.ast.tokenSlice(self.ast.nodeMainToken(obj)),
                    err_name,
                )) {
                    self.seen.known_error_struct_access = true;
                    return .Stop;
                }
            },
            else => {},
        }
        return .Continue;
    }

    pub fn visitCall(self: *Visitor, _: Node.Index, _: *const Ast.full.Call) VisitError!walk.WalkState {
        if (self.curr_return == Semantic.NULL_NODE) return .Continue;

        self.seen.return_call = true;
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

    const debug = &[_][:0]const u8{
        \\const Error = error { Oops };
        \\fn foo() Error!void { return Error.Oops; }
    };

    const pass = &[_][:0]const u8{
        "fn foo() void { return; }",
        "fn foo() !void { return error.Oops; }",
        "fn foo() !void { return bar(); }",
        "fn foo() !void { bar() catch |e| return e; }",
        "fn foo(x: bool) !void { return if (x) error.Oops else {};  }",
        \\const Error = error { Oops };
        \\fn foo() Error!void { return Error.Oops; }
        ,
        \\const SomethingBad = error { FooError };
        \\fn foo() !void { return SomethingBad.FooError; }
        ,
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
        ,
        \\fn foo() !void {
        \\  const e = bar();
        \\  return e;
        \\}
    };

    _ = debug;
    // _ = pass;
    // _ = fail;
    try runner
        // .withPass(debug)
        .withPass(pass)
        .withFail(fail)
        .run();
}
