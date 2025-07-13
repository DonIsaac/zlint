//! ## What This Rule Does
//! Checks for functions that return references to stack-allocated memory.
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
    fn_body_scope: Scope.Id,
    ctx: *LinterContext,
    return_depth: u8,
    tags: []const Node.Tag,
    data: []const Node.Data,

    fn init(ctx: *LinterContext, fn_body_scope: Scope.Id) StackReferenceVisitor {
        return .{
            .ctx = ctx,
            .return_depth = 0,
            .tags = ctx.ast().nodes.items(.tag),
            .data = ctx.ast().nodes.items(.data),
            .fn_body_scope = fn_body_scope,
        };
    }

    pub const Err = error{};

    pub fn enterNode(self: *StackReferenceVisitor, node: Node.Index) Err!void {
        switch (self.tags[node]) {
            .@"return" => {
                self.return_depth += 1;
            },
            .address_of,
            => |tag| {
                if (self.return_depth == 0) return;
                const deref_target = self.data[node].lhs;
                const info = self.isDeclaredLocally(deref_target);
                if (info.is_local) {
                    const diagnostic = if (tag == .address_of)
                        stackRefDiagnostic(self.ctx, node, info.decl_loc, false)
                    else
                        stackRefDiagnostic(self.ctx, node, info.decl_loc, true);
                    self.ctx.report(diagnostic);
                }
            },
            .slice,
            .slice_open,
            .slice_sentinel,
            => {
                // todo: check inside slices and array literals for identifier references
            },
            else => {},
        }
    }

    pub fn exitNode(self: *StackReferenceVisitor, node: Node.Index) void {
        if (self.tags[node] == .@"return") {
            self.return_depth -= 1;
        }
    }

    const IsLocal = struct {
        is_local: bool,
        decl_loc: ?Span = null,
        const no: IsLocal = .{ .is_local = false };
    };
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
        const ident_token = tokens[symbol_id.into(usize)].unwrap() orelse return .no;
        if (comptime util.IS_DEBUG) {
            const decl_ident = self.ctx.semantic.tokenSlice(ident_token.int());
            util.assert(std.mem.eql(u8, decl_ident, name), "{s} != {s}", .{ decl_ident, name });
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
        "fn foo() []u8 { return &[_]u8{}; }",
    };

    // Code your rule should fail on
    const fail = &[_][:0]const u8{
        // TODO: add test cases
        "fn foo() *u32 { var x: u32 = 1; return &x; }",
        "fn foo() !*u32 { var x: u32 = 1; return &x; }",
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
