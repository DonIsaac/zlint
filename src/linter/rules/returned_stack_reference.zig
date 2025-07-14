//! ## What This Rule Does
//! Checks for functions that return references to stack-allocated memory.
//!
//! > [!NOTE]
//! > This rule is still in early development. PRs to improve it are welcome.
//!
//! It is illegal to use stack-allocated memory outside of the function that
//! allocated it. Once that function returns and the stack is popped, the memory
//! is no longer valid and may cause segfaults or undefined behavior.
//!
//! ```zig
//! const std = @import("std");
//! fn foo() *u32 {
//!   var x: u32 = 1; // x is on the stack
//!   return &x;
//! }
//! fn bar() void {
//!   const x = foo();
//!   std.debug.print("{d}\n", .{x}); // crashes
//! }
//! ```
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! const std = @import("std");
//! fn foo() *u32 {
//!   var x: u32 = 1;
//!   return &x;
//! }
//! fn bar() []u32 {
//!   var x: [1]u32 = .{1};
//!   return x[0..];
//! }
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! fn foo() *u32 {
//!   var x = std.heap.page_allocator.create(u32);
//!   x.* = 1;
//!   return x;
//! }
//! ```

const std = @import("std");
const util = @import("util");
const _source = @import("../../source.zig");
const semantic = @import("../../semantic.zig");
const _rule = @import("../rule.zig");
const _span = @import("../../span.zig");
const ast_utils = @import("../ast_utils.zig");
const walk = @import("../../visit/walk.zig");

const Ast = std.zig.Ast;
const Node = Ast.Node;
const Symbol = semantic.Symbol;
const Scope = semantic.Scope;
const Loc = std.zig.Loc;
const Span = _span.Span;
const LabeledSpan = _span.LabeledSpan;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const NodeWrapper = _rule.NodeWrapper;

const Error = @import("../../Error.zig");
const Cow = util.Cow(false);

// Rule metadata
const ReturnedStackReference = @This();
pub const meta: Rule.Meta = .{
    .name = "returned-stack-reference",
    // TODO: set the category to an appropriate value
    .category = .nursery,
    .default = .off,
};

fn stackRefDiagnostic(ctx: *LinterContext, node: Node.Index, decl_loc: ?Span, comptime is_slice: bool) Error {
    const msg = if (is_slice)
        "Returning a slice to stack-allocated memory is undefined behavior."
    else
        "Returning a reference to stack-allocated memory is undefined behavior.";

    var labels: [2]LabeledSpan = undefined;
    labels[0] = ctx.spanN(node);
    if (decl_loc) |loc| {
        labels[1] = LabeledSpan{ .span = loc };
    }
    const label_slice: []const LabeledSpan = labels[0..if (decl_loc) |_| 2 else 1];

    return ctx.diagnostic(
        msg,
        label_slice[0..],
    );
}

pub fn runOnNode(_: *const ReturnedStackReference, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const node = wrapper.node;
    const node_id = wrapper.idx;
    if (node.tag != .fn_decl) return;

    // find the function's return type. we want pointer-like ones.
    var buffer: [1]Ast.Node.Index = undefined;
    const func = ctx.ast().fullFnProto(&buffer, node_id) orelse return;
    if (!ast_utils.isPointerType(ctx, func.ast.return_type)) return;

    const func_body = wrapper.node.data.rhs;
    std.debug.assert(func_body != semantic.Semantic.NULL_NODE);
    const links = &ctx.semantic.node_links;
    // FIXME: this is the fn body's parent
    const body_scope = links.getScope(func_body) orelse return;

    var stackfb = std.heap.stackFallback(256, ctx.gpa);
    const allocator = stackfb.get();

    var visitor = StackReferenceVisitor.init(
        ctx,
        Scope.Id.new(body_scope.int() + 1),
    );
    var walker = StackReferenceWalker.initAtNode(
        allocator,
        ctx.ast(),
        &visitor,
        func_body,
    ) catch return;
    defer walker.deinit();
    walker.walk() catch return;
}

const StackReferenceWalker = walk.Walker(StackReferenceVisitor, StackReferenceVisitor.Err);
const StackReferenceVisitor = struct {
    /// Scope created by the body of the visited function.
    fn_body_scope: Scope.Id,
    ctx: *LinterContext,
    tags: []const Node.Tag,
    data: []const Node.Data,

    // state
    /// How many `return` statements have been seen above the currently-visited node.
    return_depth: u8,
    /// How many `call` statements have been seen above the currently-visited node.
    call_depth: u8,

    fn init(ctx: *LinterContext, fn_body_scope: Scope.Id) StackReferenceVisitor {
        const nodes = ctx.ast().nodes;
        return .{
            .ctx = ctx,
            .return_depth = 0,
            .call_depth = 0,
            .tags = nodes.items(.tag),
            .data = nodes.items(.data),
            .fn_body_scope = fn_body_scope,
        };
    }

    pub const Err = error{};

    pub fn enterNode(self: *StackReferenceVisitor, node: Node.Index) Err!void {
        switch (self.tags[node]) {
            .@"return" => self.return_depth += 1,
            .call, .call_comma, .call_one, .call_one_comma => self.call_depth += 1,
            .slice, .slice_open, .slice_sentinel => {
                // todo: check inside slices and array literals for identifier references
            },
            else => {},
        }
    }

    pub fn exitNode(self: *StackReferenceVisitor, node: Node.Index) void {
        switch (self.tags[node]) {
            .@"return" => self.return_depth -= 1,
            .call, .call_comma, .call_one, .call_one_comma => self.call_depth -= 1,
            else => {},
        }
    }

    pub fn visit_address_of(self: *StackReferenceVisitor, node: Node.Index) Err!walk.WalkState {
        if (self.return_depth == 0 or self.call_depth > 0) return .Continue;

        const deref_target = self.data[node].lhs;
        const info = self.isDeclaredLocally(deref_target);
        if (info.is_local) {
            self.ctx.report(stackRefDiagnostic(self.ctx, node, info.decl_loc, false));
        }
        return .Continue;
    }

    const IsLocal = struct {
        is_local: bool,
        decl_loc: ?Span = null,
        const no: IsLocal = .{ .is_local = false };
    };

    /// Check if a variable referenced by `node` is declared within the visited
    /// function's body.
    ///
    /// Returns `no` if
    /// - `node` is not an identifier
    /// - declaration cannot be resolved
    /// - declaration is within a comptime scope
    /// - declaration is not declared within the current function's body
    pub fn isDeclaredLocally(
        self: *StackReferenceVisitor,
        node: Node.Index,
    ) IsLocal {
        const sema = self.ctx.semantic;
        std.debug.assert(node != semantic.Semantic.NULL_NODE);
        if (self.tags[node] != .identifier) return .no;

        const symbols = sema.symbols.symbols.slice();
        const scopes: []const Scope.Id = symbols.items(.scope);
        const tokens: []const util.NominalId(Ast.TokenIndex).Optional = symbols.items(.token);

        const scope_id = sema.node_links.getScope(node) orelse return .no;
        const name = sema.nodeSlice(node);
        const symbol_id = sema.resolveBinding(scope_id, name, .{}) orelse return .no;

        const declared_in: Scope.Id = scopes[symbol_id.into(usize)];
        const decl_scope_flags: Scope.Flags = sema.scopes.scopes.items(.flags)[declared_in.int()];
        if (decl_scope_flags.s_comptime) {
            return .no;
        }
        const ident_token = tokens[symbol_id.into(usize)].unwrap() orelse return .no;
        if (comptime util.IS_DEBUG) {
            const decl_ident = sema.tokenSlice(ident_token.int());
            util.assert(
                std.mem.eql(u8, decl_ident, name),
                "{s} != {s}",
                .{ decl_ident, name },
            );
        }

        const decl_span = sema.tokenSpan(ident_token.into(Ast.TokenIndex));
        const is_local = sema.scopes.isParentOf(self.fn_body_scope, declared_in);

        return .{ .is_local = is_local, .decl_loc = decl_span };
    }
};

pub fn rule(self: *ReturnedStackReference) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test ReturnedStackReference {
    const t = std.testing;

    var returned_stack_reference = ReturnedStackReference{};
    var runner = RuleTester.init(t.allocator, returned_stack_reference.rule());
    defer runner.deinit();

    // Code your rule should pass on
    const pass = &[_][:0]const u8{
        // TODO: add test cases
        \\const std = @import("std");
        \\fn foo(allocator: std.mem.Allocator) *u32 {
        \\  var x: *u32 = allocator.create(u32);
        \\  x.* = 1;
        \\  return x;
        \\}
        ,
        "fn foo(buf: []u8) []u8 { return buf[0..]; }",
        "fn foo() []u8  { return &[_]u8{}; }",
        "fn foo() [2]u8 { return [2]u8{1, 2}; }",
        \\fn len(slice: *[]const u8) usize {
        \\  return slice.len;
        \\}
        \\fn foo() []u8 {
        \\  var arr = [_]u8{1, 2, 3};
        \\  return len(&arr);
        \\}
        ,
        // returning stack references in comptime functions is tricky but ok
        \\pub inline fn pathLiteral(comptime literal: anytype) *const [literal.len:0]u8 {
        \\    if (!Environment.isWindows) return @ptrCast(literal);
        \\    return comptime {
        \\        var buf: [literal.len:0]u8 = undefined;
        \\        for (literal, 0..) |char, i| {
        \\            buf[i] = if (char == '/') '\\' else char;
        \\            assert(buf[i] != 0 and buf[i] < 128);
        \\        }
        \\        buf[buf.len] = 0;
        \\        const final = buf[0..buf.len :0].*;
        \\        return &final;
        \\    };
        \\}
    };

    // Code your rule should fail on
    const fail = &[_][:0]const u8{
        // TODO: add test cases
        "fn foo()  *u32 { var x: u32 = 1; return &x; }",
        "fn foo() !*u32 { var x: u32 = 1; return &x; }",
        "fn foo() ?*u32 { var x: u32 = 1; return &x; }",
        // FIXME
        // "fn foo() error{}!*u32 { var x: u32 = 1; return &x; }",
        // \\const Foo = struct { x: *u32 };
        // \\fn foo() Foo {
        // \\  const local: u32 = 1;
        // \\  return .{ .x = &local };
        // \\}
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
