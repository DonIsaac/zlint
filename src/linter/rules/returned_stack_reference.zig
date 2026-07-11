//! ## What This Rule Does
//! Checks for functions that return references to stack-allocated memory.
//!
//! :::warning
//!
//! This rule is still in early development. PRs to improve it are welcome.
//!
//! :::
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
const Semantic = @import("../../Semantic.zig");
const _rule = @import("../rule.zig");
const _span = @import("../../span.zig");
const walk = @import("../../visit/walk.zig");
const ast_util = @import("../ast_utils.zig");

const Ast = Semantic.Ast;
const Node = Ast.Node;
const Scope = Semantic.Scope;
const Span = _span.Span;
const LabeledSpan = _span.LabeledSpan;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const NodeWrapper = _rule.NodeWrapper;

const Error = @import("../../Error.zig");

// Rule metadata
const ReturnedStackReference = @This();
pub const meta: Rule.Meta = .{
    .name = "returned-stack-reference",
    // TODO: set the category to an appropriate value
    .category = .nursery,
    .default = .off,
};

fn stackRefDiagnostic(
    ctx: *LinterContext,
    node: Node.Index,
    decl_loc: ?Span,
    comptime is_slice: bool,
) Error {
    const msg = if (is_slice)
        "Returning a slice to stack-allocated memory is undefined behavior."
    else
        "Returning a reference to stack-allocated memory is undefined behavior.";

    const primary_label = if (is_slice)
        "This slice refers to a local variable"
    else
        "This pointer refers to a local variable";

    var labels: [2]LabeledSpan = undefined;
    labels[0] = ctx.labelN(node, primary_label, .{});
    if (decl_loc) |loc| {
        labels[1] = LabeledSpan{ .span = loc, .label = .static("Variable is declared locally here") };
    }
    const label_slice: []const LabeledSpan = labels[0..if (decl_loc) |_| 2 else 1];

    return ctx.diagnostic(
        msg,
        label_slice[0..],
    );
}

pub fn runOnNode(_: *const ReturnedStackReference, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const node = wrapper.node;
    if (node.tag != .fn_decl) return;
    const func_proto, const func_body = wrapper.node.data.node_and_node;
    const ast = ctx.ast();

    // note: we could pass the fn decl here, but since we know its an fn_decl
    // node, we can save a level of indirection by just passing the fn_proto
    // directly.
    var buffer: [1]Ast.Node.Index = undefined;
    const func: Ast.full.FnProto = ast.fullFnProto(&buffer, func_proto) orelse return;

    // filter out functions that probably don't return pointers or containers
    // with pointer fields.
    // todo: handle complex return types, e.g. `foo() if (comptime_cond) *u32 else void`
    do_we_care: {
        var curr = func.ast.return_type.unwrap() orelse return;
        while (true) {
            switch (ast.nodeTag(curr)) {
                Node.Tag.ptr_type,
                Node.Tag.ptr_type_aligned,
                Node.Tag.ptr_type_sentinel,
                Node.Tag.ptr_type_bit_range,
                => break :do_we_care,
                .optional_type => {
                    curr = ast.nodeData(curr).node;
                },
                .error_union => {
                    curr = ast.nodeData(curr).node_and_node[1];
                },
                .identifier => {
                    const name = ctx.semantic.tokenSlice(ast.nodeMainToken(curr));
                    if (name.len > 0 and std.ascii.isUpper(name[0])) {
                        break :do_we_care;
                    } else {
                        return;
                    }
                },
                else => return,
            }
        }
    }

    const links = &ctx.semantic.node_links;
    const scope_tree = &ctx.semantic.scopes;
    const param_scope = links.getScope(func_body) orelse return;
    const scope_nodes: []const Node.Index = scope_tree.scopes.items(.node);
    const body_scope: Scope.Id = blk: {
        for (scope_tree.children.items[param_scope.int()].items) |child| {
            if (scope_nodes[child.int()] == func_body) break :blk child;
        }
        return;
    };
    if (comptime util.IS_DEBUG) {
        const flags: Scope.Flags = scope_tree.scopes.items(.flags)[body_scope.int()];
        std.debug.assert(flags.s_function and flags.s_block);
    }

    var walk_stackfb = std.heap.stackFallback(256, ctx.gpa);
    var visitor = StackReferenceVisitor.init(ctx, body_scope);

    var walker = StackReferenceWalker.initAtNode(
        walk_stackfb.get(),
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
    ast: *const Ast,

    fn init(
        ctx: *LinterContext,
        fn_body_scope: Scope.Id,
    ) StackReferenceVisitor {
        return .{
            .ctx = ctx,
            .ast = ctx.ast(),
            .fn_body_scope = fn_body_scope,
        };
    }

    pub const Err = error{};

    pub fn visit_address_of(self: *StackReferenceVisitor, node: Node.Index) Err!walk.WalkState {
        if (self.returnFlow(node) != .escapes) return .Continue;

        const deref_target = self.ast.nodeData(node).node;
        if (self.baseIdentifier(deref_target)) |base| {
            const info = self.isDeclaredLocally(base.ident);
            // `&x` always references the variable's own (stack) memory, but
            // `&x[0]`/`&x.*` reference its pointee, which is only on the stack
            // when `x` is an array.
            if (info.is_local and (!base.pointee or info.is_stack_array)) {
                self.ctx.report(stackRefDiagnostic(self.ctx, node, info.decl_loc, false));
            }
            return .Skip;
        }
        return .Continue;
    }

    pub fn visitSlice(
        self: *StackReferenceVisitor,
        node: Node.Index,
        slice: *const Ast.full.Slice,
    ) Err!walk.WalkState {
        if (self.returnFlow(node) != .escapes) return .Continue;

        if (self.baseIdentifier(slice.ast.sliced)) |base| {
            const info = self.isDeclaredLocally(base.ident);
            // Slicing only yields a stack reference when the sliced variable
            // is an array. Slices/pointers point to memory owned elsewhere.
            if (info.is_local and info.is_stack_array) {
                self.ctx.report(stackRefDiagnostic(self.ctx, node, info.decl_loc, true));
            }
            return .Skip;
        }
        return .Continue;
    }

    const ReturnFlow = enum { escapes, consumed, unrelated };

    /// Classify whether `node` contributes a reference to an enclosing return
    /// value. This is intentionally syntactic: calls and unknown conversions
    /// consume their inputs because their escape behavior needs type/flow
    /// information that this rule does not have.
    fn returnFlow(self: *const StackReferenceVisitor, node: Node.Index) ReturnFlow {
        var child = node;
        const links = self.ctx.links();
        const data: []const Node.Data = self.ast.nodes.items(.data);
        while (links.getParent(child)) |parent| {
            const parent_data = data[@intFromEnum(parent)];
            switch (self.ast.nodeTag(parent)) {
                .@"return" => {
                    const returned = parent_data.opt_node.unwrap() orelse return .unrelated;
                    return if (returned == child) .escapes else .unrelated;
                },
                .if_simple => if (child == parent_data.node_and_node[0]) return .consumed,
                .@"if" => if (child == parent_data.node_and_extra[0]) return .consumed,
                .@"switch",
                .switch_comma,
                => if (child == parent_data.node_and_extra[0]) return .consumed,
                .switch_case_one,
                .switch_case_inline_one,
                => if (child != parent_data.opt_node_and_node[1]) return .consumed,
                .switch_case,
                .switch_case_inline,
                => if (child != parent_data.extra_and_node[1]) return .consumed,
                .slice_open => if (child != parent_data.node_and_node[0]) return .consumed,
                .slice, .slice_sentinel => if (child != parent_data.node_and_extra[0]) return .consumed,
                .while_simple,
                .while_cont,
                .@"while",
                .for_simple,
                .@"for",
                .call,
                .call_comma,
                .call_one,
                .call_one_comma,
                .builtin_call,
                .builtin_call_comma,
                .builtin_call_two,
                .builtin_call_two_comma,
                .array_access,
                => return .consumed,
                .field_access => {
                    const field_token = parent_data.node_and_token[1];
                    if (std.mem.eql(u8, self.ctx.semantic.tokenSlice(field_token), "len")) return .consumed;
                },
                .@"break" => {
                    const break_data = parent_data.opt_token_and_opt_node;
                    const value = break_data[1].unwrap() orelse return .consumed;
                    if (value != child) return .consumed;
                    child = self.breakTarget(parent, break_data[0].unwrap()) orelse return .consumed;
                    continue;
                },
                .block, .block_semicolon, .block_two, .block_two_semicolon => {
                    if (!self.isBlockResult(parent, child)) return .consumed;
                },
                .equal_equal,
                .bang_equal,
                .less_than,
                .greater_than,
                .less_or_equal,
                .greater_or_equal,
                .assign_mul,
                .assign_div,
                .assign_mod,
                .assign_add,
                .assign_sub,
                .assign_shl,
                .assign_shl_sat,
                .assign_shr,
                .assign_bit_and,
                .assign_bit_xor,
                .assign_bit_or,
                .assign_mul_wrap,
                .assign_add_wrap,
                .assign_sub_wrap,
                .assign_mul_sat,
                .assign_add_sat,
                .assign_sub_sat,
                .assign,
                .mul,
                .div,
                .mod,
                .array_mult,
                .mul_wrap,
                .mul_sat,
                .add,
                .sub,
                .array_cat,
                .add_wrap,
                .sub_wrap,
                .sub_sat,
                .shl,
                .shl_sat,
                .shr,
                .bit_and,
                .bit_xor,
                .bit_or,
                .bool_and,
                .bool_or,
                .bool_not,
                .negation,
                .negation_wrap,
                .bit_not,
                => return .consumed,
                .local_var_decl,
                .simple_var_decl,
                .aligned_var_decl,
                .global_var_decl,
                .@"defer",
                .@"errdefer",
                .@"continue",
                => return .consumed,
                else => {},
            }
            child = parent;
        }
        return .unrelated;
    }

    fn breakTarget(
        self: *const StackReferenceVisitor,
        break_node: Node.Index,
        label: ?Ast.TokenIndex,
    ) ?Node.Index {
        var ancestor = self.ctx.links().getParent(break_node);
        while (ancestor) |node| : (ancestor = self.ctx.links().getParent(node)) {
            const tag = self.ast.nodeTag(node);
            if (ast_util.isBlock(self.ast, node)) {
                const label_token = label orelse continue;
                const lbrace = self.ast.nodeMainToken(node);
                if (lbrace < 2 or self.ast.tokenTag(lbrace - 1) != .colon) continue;
                const label_name = self.ctx.semantic.tokenSlice(label_token);
                if (std.mem.eql(u8, label_name, self.ctx.semantic.tokenSlice(lbrace - 2))) return node;
            }
            switch (tag) {
                .while_simple, .while_cont, .@"while" => {
                    const loop = self.ast.fullWhile(node) orelse unreachable;
                    if (self.matchesBreakLabel(label, loop.label_token)) return node;
                },
                .for_simple, .@"for" => {
                    const loop = self.ast.fullFor(node) orelse unreachable;
                    if (self.matchesBreakLabel(label, loop.label_token)) return node;
                },
                .@"switch", .switch_comma => {
                    const switch_expr = self.ast.switchFull(node);
                    if (self.matchesBreakLabel(label, switch_expr.label_token)) return node;
                },
                else => {},
            }
        }
        return null;
    }

    fn tokenNamesEql(self: *const StackReferenceVisitor, a: Ast.TokenIndex, b: Ast.TokenIndex) bool {
        return std.mem.eql(u8, self.ctx.semantic.tokenSlice(a), self.ctx.semantic.tokenSlice(b));
    }

    fn matchesBreakLabel(
        self: *const StackReferenceVisitor,
        break_label: ?Ast.TokenIndex,
        target_label: ?Ast.TokenIndex,
    ) bool {
        const break_label_token = break_label orelse return true;
        const target_label_token = target_label orelse return false;
        return self.tokenNamesEql(target_label_token, break_label_token);
    }

    fn isBlockResult(self: *const StackReferenceVisitor, block: Node.Index, child: Node.Index) bool {
        return switch (self.ast.nodeTag(block)) {
            .block_semicolon, .block_two_semicolon => false,
            .block, .block_two => blk: {
                var buffer: [2]Node.Index = undefined;
                const statements = self.ast.blockStatements(&buffer, block) orelse unreachable;
                break :blk statements.len > 0 and statements[statements.len - 1] == child;
            },
            else => unreachable,
        };
    }

    const Base = struct {
        ident: Node.Index,
        /// `true` when the expression refers to the variable's pointee (via
        /// dereferencing or indexing) rather than the variable's own memory.
        pointee: bool,
    };

    /// Resolve the base expression of a slice or address-of to an identifier,
    /// if possible.
    fn baseIdentifier(self: *StackReferenceVisitor, node: Node.Index) ?Base {
        var curr = node;
        var pointee = false;
        while (true) {
            switch (self.ast.nodeTag(curr)) {
                .identifier => return .{ .ident = curr, .pointee = pointee },
                .grouped_expression => {
                    curr = self.ast.nodeData(curr).node_and_token[0];
                },
                .array_access => {
                    pointee = true;
                    curr = self.ast.nodeData(curr).node_and_node[0];
                },
                .deref => {
                    pointee = true;
                    curr = self.ast.nodeData(curr).node;
                },
                else => return null,
            }
        }
    }

    /// Container decls in expression position (e.g. `struct { fn f() ... }`)
    /// introduce new functions whose locals belong to them, not to the
    /// function being checked. Nested `fn_decl`s get their own `runOnNode`
    /// pass, so skipping avoids both false positives and duplicate reports.
    pub fn visitContainerDecl(
        _: *StackReferenceVisitor,
        _: Node.Index,
        _: *const Ast.full.ContainerDecl,
    ) Err!walk.WalkState {
        return .Skip;
    }

    pub fn visit_local_var_decl(_: *StackReferenceVisitor, _: Node.Index) Err!walk.WalkState {
        return .Skip;
    }
    pub fn visit_simple_var_decl(_: *StackReferenceVisitor, _: Node.Index) Err!walk.WalkState {
        return .Skip;
    }
    pub fn visit_aligned_var_decl(_: *StackReferenceVisitor, _: Node.Index) Err!walk.WalkState {
        return .Skip;
    }

    const IsLocal = struct {
        is_local: bool,
        decl_loc: ?Span = null,
        /// `true` when the declaration proves the variable is a stack array
        /// (array type annotation or explicitly-typed array literal init).
        is_stack_array: bool = false,
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
        std.debug.assert(node != Semantic.NULL_NODE);
        if (self.ast.nodeTag(node) != .identifier) return .no;

        const symbols = sema.symbols.symbols.slice();
        const scopes: []const Scope.Id = symbols.items(.scope);
        const tokens: []const util.NominalId(Ast.TokenIndex).Optional = symbols.items(.token);

        const scope_id = sema.node_links.getScope(node) orelse return .no;
        const name = sema.nodeSlice(node);
        const symbol_id = (sema.resolveBinding(scope_id, name, .{}) orelse return .no).into(usize);

        const declared_in: Scope.Id = scopes[symbol_id];
        const decl_scope_flags: Scope.Flags = sema.scopes.scopes.items(.flags)[declared_in.int()];
        if (decl_scope_flags.s_comptime) {
            return .no;
        }
        const is_local = sema.scopes.isParentOf(self.fn_body_scope, declared_in);
        const decl_node: Node.Index = symbols.items(.decl)[symbol_id];

        // check for allowed cases
        var is_stack_array = false;
        switch (self.ast.nodeTag(decl_node)) {
            .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                const var_decl = self.ast.fullVarDecl(decl_node) orelse unreachable;
                if (var_decl.ast.type_node.unwrap()) |type_node| {
                    switch (self.ast.nodeTag(type_node)) {
                        .array_type, .array_type_sentinel => is_stack_array = true,
                        else => {},
                    }
                }

                const var_init = var_decl.ast.init_node.unwrap() orelse return .no;
                const init_tag = self.ast.nodeTag(var_init);
                if (ast_util.isContainerDecl(init_tag)) return .no;
                if (ast_util.isArrayInit(init_tag)) is_stack_array = true;

                switch (init_tag) {
                    // references to comptime variables are ok
                    //
                    //   const x: u32 = comptime blk: { break :blk 1; };
                    //   return &x;
                    .@"comptime" => return .no,
                    .field_access => {
                        const inner = ast_util.getLeftmostNode(self.ctx, var_init, true);
                        // references to local container decls are comptime
                        if (ast_util.isContainerDecl(self.ast.nodeTag(inner))) {
                            return .no;
                        }
                    },

                    else => {},
                }
            },
            else => {},
        }

        const ident_token = tokens[symbol_id].unwrap() orelse return .no;
        if (comptime util.IS_DEBUG) {
            const decl_ident = sema.tokenSlice(ident_token.int());
            util.assert(
                std.mem.eql(u8, decl_ident, name),
                "{s} != {s}",
                .{ decl_ident, name },
            );
        }

        return .{
            .is_local = is_local,
            .decl_loc = sema.tokenSpan(ident_token.into(Ast.TokenIndex)),
            .is_stack_array = is_stack_array,
        };
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

    const pass = &[_][:0]const u8{
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
        ,
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\fn checkPath(pathbuf: []const u8) bool {
        \\  var buf: [1024]u8 = undefined;
        \\  return switch (builtin.target.os.tag) {
        \\    .windows => blk: {
        \\      var curr: usize = 0;
        \\      for (pathbuf) |char| {
        \\        if (char == '/' or char == '\\') continue;
        \\        buf[curr] = char;
        \\        curr += 1;
        \\      }
        \\      buf[curr] = 0;
        \\      var thing = SomeStruct { .x = &buf };
        \\      return thing.bar();
        \\    },
        \\    else => pathbuf.len > 0,
        \\  };
        \\}
        ,
        \\fn foo() *const u32 {
        \\  const x: u32 = comptime blk: {
        \\    comptime var i = 0;
        \\    i += 1;
        \\    break :blk i;
        \\  };
        \\  return &x;
        \\}
        ,
        \\const std = @import("std");
        \\fn foo(al: std.mem.Allocator) []u8 {
        \\  const buf = al.alloc(u8, 16) catch @panic("oom");
        \\  return buf[0..8];
        \\}
        ,
        "fn foo(s: []u8) []u8 { const t: []u8 = s; return t[0..]; }",
        "fn foo(p: *u32) *u32 { var q = p; return &q.*; }",
        "fn foo(s: []u8) *u8 { const t = s; return &t[0]; }",
        "fn foo(other: []u8) []u8 { var x: [1]u8 = .{0}; return if (x[0..].len == 1) other else other; }",
        "fn foo(other: []u8) []u8 { var x: [1]u8 = .{0}; return switch (x[0..].len) { 1 => other, else => other }; }",
        \\const Result = struct { len: usize, value: []u8 };
        \\fn foo(other: []u8) Result {
        \\  var x: [1]u8 = .{0};
        \\  return .{ .len = x[0..].len, .value = other };
        \\}
        ,
        \\fn foo(other: []u8) []u8 {
        \\  var x: [1]u8 = .{0};
        \\  return blk: {
        \\    const ignored = inner: { break :inner x[0..]; };
        \\    _ = ignored;
        \\    break :blk other;
        \\  };
        \\}
        ,
        \\const Handler = struct { f: *const fn ([]u8) []u8 };
        \\fn foo() Handler {
        \\  return .{ .f = struct {
        \\    fn g(s: []u8) []u8 {
        \\      return s[0..1];
        \\    }
        \\  }.g };
        \\}
        ,
        // FIXME: `bar` is a comptime-known function value; `&bar` has static
        // lifetime.
        \\ const F = fn (a: bool) u32;
        \\fn foo() *const F {
        \\  const bar = struct {
        \\    fn barImpl(a: bool) u32 {
        \\      return if (a) 1 else 2;
        \\    }
        \\  }.barImpl;
        \\  return &bar;
        \\}
        ,
        \\ const F = fn (a: bool) u32;
        \\fn foo() *const F {
        \\  const bar = enum(u8) {
        \\    a,
        \\    b,
        \\    fn barImpl(a: bool) u32 {
        \\      return if (a) 1 else 2;
        \\    }
        \\  }.barImpl;
        \\  return &bar;
        \\}
        ,
        \\const F = fn (a: bool) u32;
        \\fn foo() *const F {
        \\  const bar = union(enum) {
        \\    none: void,
        \\    fn barImpl(a: bool) u32 {
        \\      return if (a) 1 else 2;
        \\    }
        \\  }.barImpl;
        \\  return &bar;
        \\}
    };

    const fail = &[_][:0]const u8{
        "fn foo()  *u32 { var x: u32 = 1; return &x; }",
        "fn foo() !*u32 { var x: u32 = 1; return &x; }",
        "fn foo() ?*u32 { var x: u32 = 1; return &x; }",
        \\const X = struct { p: *u32 };
        \\fn foo() X {
        \\  var x: u32 = 1;
        \\  return .{ .p = &x };
        \\}
        ,
        \\fn foo(a: bool) *u32 {
        \\  var x: u32 = 1;
        \\  return if (a) &x else @panic("ahh");
        \\}
        ,
        \\fn foo(a: bool) *u32 {
        \\  var x: u32 = 1;
        \\  return blk: {
        \\    x += 1;
        \\    break :blk &x;
        \\  };
        \\}
        ,
        "fn foo() error{}!*u32 { var x: u32 = 1; return &x; }",
        "fn foo() error{Oops}!*u32 { var x: u32 = 1; return &x; }",
        \\fn foo(e: error{Bad}) *u32 {
        \\  var x: u32 = 1;
        \\  _ = e;
        \\  return &x;
        \\}
        ,
        "fn foo() *u8 { var x: [4]u8 = undefined; return &x[0]; }",
        "fn foo() []u8 { var x = [_]u8{1, 2}; return x[0..1]; }",
        "fn foo() *u32 { var x: u32 = 1; return &(x); }",
        "fn foo() [:0]u8 { var x: [4:0]u8 = undefined; return x[0..]; }",
        \\const Handler = struct { f: *const fn () *u32 };
        \\fn foo() Handler {
        \\  return .{ .f = struct {
        \\    fn g() *u32 {
        \\      var y: u32 = 1;
        \\      return &y;
        \\    }
        \\  }.g };
        \\}
        ,
        \\const Foo = struct { x: *u32 };
        \\fn foo() Foo {
        \\  const local: u32 = 1;
        \\  return .{ .x = &local };
        \\}
        ,
        "fn foo() []u32 { var x: [1]u32 = .{1}; return x[0..]; }",
        "fn foo() []u32 { var x: [4]u32 = .{1, 2, 3, 4}; return x[1..3]; }",
        "fn foo() ![]u32 { var x: [1]u32 = .{1}; return x[0..]; }",
        "fn foo() []u8 { var x: [1]u8 = .{0}; return x[0..][0..]; }",
        "fn foo() [*]u8 { var x: [1]u8 = .{0}; return x[0..].ptr; }",
        "fn foo(other: []u8) []u8 { var x: [1]u8 = .{0}; const maybe: ?[]u8 = other; return maybe orelse x[0..]; }",
        "fn foo(other: []u8) ![]u8 { var x: [1]u8 = .{0}; return other catch x[0..]; }",
        "fn foo() []u8 { var x: [1]u8 = .{0}; return (&x)[0..]; }",
        "fn foo() []u8 { var x: [1]u8 = .{0}; return while (true) { break x[0..]; } else unreachable; }",
        \\fn foo(a: bool) []u32 {
        \\  var x: [1]u32 = .{1};
        \\  return if (a) x[0..] else &[_]u32{};
        \\}
        ,
        \\fn foo() []u32 {
        \\  var x: [1]u32 = .{1};
        \\  return blk: {
        \\    break :blk x[0..];
        \\  };
        \\}
        ,
        "fn foo() []u8 { var arr = [_]u8{1, 2, 3}; return arr[0..]; }",
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
