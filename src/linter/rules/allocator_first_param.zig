//! ## What This Rule Does
//!
//! Checks that functions taking allocators as parameters have the allocator as
//! the first parameter. This conforms to common Zig conventions.
//!
//! ## Rule Details
//! This rule looks for functions take an `Allocator` parameter and reports a
//! violation if
//! - it is not the first parameter, or
//! - there is a `self` parameter, and the allocator does not immediately follow it.
//!
//! Parameters are considered to be an allocator if
//! - the are named `allocator`, `alloc`, `gpa`, or `arena`, or one of those
//!   with leading/trailing underscores,
//! - their type ends with `Allocator`
//!
//! Parameters are considered to be a `self` parameter if
//! - they are named `self`, `this`, or one of those with leading/trailing underscores.
//! - their type is `@This()`, `*@This()`, etc.
//! - their type is a Capitalized and the function is within the definition of a
//!   similarly named container (e.g. a struct).
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! fn foo(x: u32, allocator: Allocator) !*u32 {
//!   const heap_x = try allocator.create(u32);
//!   heap_x.* = x;
//!   return heap_x;
//! }
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! fn foo(allocator: Allocator, x: u32) !*u32 {
//!   const heap_x = try allocator.create(u32);
//!   heap_x.* = x;
//!   return heap_x;
//! }
//! const Foo = struct {
//!   list: std.ArrayListUnmanaged(u32) = .{},
//!   // when writing methods, `self` must be the first parameter
//!   pub fn expandCapacity(self: *Foo, allocator: Allocator, new_len: usize) !void {
//!     try self.list.ensureTotalCapacity(allocator, new_len);
//!   }
//! };
//! ```

const std = @import("std");
const util = @import("util");
const Semantic = @import("../../Semantic.zig");
const _rule = @import("../rule.zig");
const _span = @import("../../span.zig");
const ast_utils = @import("../ast_utils.zig");

const Ast = std.zig.Ast;
const Node = Ast.Node;
const Scope = Semantic.Scope;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const NodeWrapper = _rule.NodeWrapper;

const Error = @import("../../Error.zig");

// Rule metadata
const AllocatorFirstParam = @This();

/// List of function names to ignore.
ignore: []const []const u8 = &[_][]const u8{},

pub const meta: Rule.Meta = .{
    .name = "allocator-first-param",
    .category = .style,
    .default = .off,
};

fn allocatorFirstParamDiagnostic(ctx: *LinterContext, param: Ast.TokenIndex) Error {
    return ctx.diagnostic(
        "Allocators should be the first parameter of a function",
        .{ctx.spanT(param)},
    );
}

const self_names = std.StaticStringMap(void).initComptime(&[_]struct { []const u8 }{
    .{"self"},
    .{"self_"},
    .{"_self"},
    .{"this"},
    .{"this_"},
    .{"_this"},
});
const allocator_names = std.StaticStringMap(void).initComptime(&[_]struct { []const u8 }{
    .{"allocator"},
    .{"allocator_"},
    .{"_allocator"},
    .{"alloc"},
    .{"alloc_"},
    .{"_alloc"},
    .{"gpa"},
    .{"gpa_"},
    .{"_gpa"},
    .{"arena"},
    .{"arena_"},
    .{"_arena"},
});

pub fn runOnNode(self: *const AllocatorFirstParam, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const node = wrapper.node;
    const node_id = wrapper.idx;
    const ast = ctx.ast();

    const fn_proto: Ast.full.FnProto = switch (node.tag) {
        // note: we ignore .fn_proto_simple and .fn_proto_one b/c they take a 0
        // or 1 parameter(s), which can never be a violation
        .fn_proto => ast.fnProto(node_id),
        .fn_proto_multi => ast.fnProtoMulti(node_id),
        else => return,
    };

    var self_pos: ?u32 = null;
    var allocator_pos: ?u32 = null;
    var alloc_name_token: ?Ast.TokenIndex = null;
    var it = fn_proto.iterate(ast);
    var i: u32 = 0;

    while (it.next()) |param| {
        defer i += 1;
        if (self_pos != null and allocator_pos != null) {
            break;
        }

        const name_token = param.name_token orelse continue;
        const type_expr = param.type_expr;
        const name = ctx.semantic.tokenSlice(name_token);

        // look for a self parameter
        check_self: {
            if (self_pos == null) {
                if (self_names.get(name) != null) {
                    self_pos = i;
                    continue;
                }

                // `?*@This()` -> `@This()`
                const ty = ast_utils.getInnerType(ast, type_expr);
                const tag: Node.Tag = ast.nodes.items(.tag)[ty];
                switch (tag) {
                    // check for `@This()`. we can ignore .builtin_call b/c
                    // @This() will never have >2 parameters
                    .builtin_call_two, .builtin_call_two_comma => {
                        const builtin_name = ctx.semantic.tokenSlice(ast.nodes.items(.main_token)[ty]);
                        if (std.mem.eql(u8, builtin_name, "@This")) {
                            self_pos = i;
                            continue;
                        }
                    },
                    .identifier => {
                        // name of referenced type
                        const type_name = ctx.semantic.tokenSlice(ast.nodes.items(.main_token)[ty]);
                        // assume struct names start with uppercase letters
                        if (std.ascii.isLower(type_name[0])) break :check_self;
                        const scope: Scope.Id = ctx.links().getScope(ty) orelse break :check_self;
                        // find where it's declared
                        const symbol_id = ctx.semantic.resolveBinding(scope, type_name, .{}) orelse break :check_self;
                        const decl_node: Node.Index = ctx.symbols().symbols.items(.decl)[symbol_id.int()];
                        var parents = ctx.links().iterParentIds(ty);
                        while (parents.next()) |parent| {
                            if (parent == decl_node) {
                                self_pos = i;
                                break :check_self;
                            }
                        }
                    },
                    else => {},
                }
            }
        }

        // look for an allocator parameter
        if (allocator_pos == null) {
            const is_named_alloc = allocator_names.get(name) != null;
            if (is_named_alloc) {
                allocator_pos = i;
                alloc_name_token = name_token;
            } else {
                const right_ident = ast_utils.getRightmostIdentifier(ctx, param.type_expr) orelse continue;
                if (std.mem.endsWith(u8, right_ident, "Allocator")) {
                    allocator_pos = i;
                    alloc_name_token = name_token;
                }
            }
        }
    }

    const alloc_param_pos = allocator_pos orelse return;
    const expected_pos: u32 = if (self_pos) |self_param_pos| blk: {
        break :blk if (self_param_pos == alloc_param_pos)
            0
        else
            1;
    } else 0;

    if (alloc_param_pos != expected_pos) {
        if (self.ignore.len > 0 and fn_proto.name_token != null) {
            const fn_name = ctx.semantic.tokenSlice(fn_proto.name_token.?);
            for (self.ignore) |ignored| {
                if (std.mem.eql(u8, fn_name, ignored)) {
                    return;
                }
            }
        }
        ctx.report(allocatorFirstParamDiagnostic(ctx, alloc_name_token.?));
    }
}

// Used by the Linter to register the rule so it can be run.
pub fn rule(self: *AllocatorFirstParam) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test AllocatorFirstParam {
    const t = std.testing;

    var allocator_first_param = AllocatorFirstParam{};
    var runner = RuleTester.init(t.allocator, allocator_first_param.rule());
    defer runner.deinit();

    const pass = &[_][:0]const u8{
        "fn foo() void { }",
        "fn foo(allocator: Allocator) void { _ = allocator;}",
        "fn foo(gpa: Allocator, arena: Allocator) void { _ = gpa; _ = arena; }",
        "fn foo(self: Allocator) void { _ = self; }",
        "fn foo(allocator: Allocator, x: u32) void { _ = allocator; _ = x; }",
        "const Foo = struct { pub fn bar(self: *Foo, allocator: Allocator, x: u32) void {} };",
        \\const Foo = struct {
        \\  pub fn doThing(self: *Foo, allocator: Allocator) void {
        \\    _ = allocator;
        \\    _ = self;
        \\  }
        \\};
        ,
        \\const Foo = struct {
        \\  pub fn doThing(this: *Foo, allocator: Allocator) void {
        \\    _ = allocator;
        \\    _ = this;
        \\  }
        \\};
        ,
        \\const Foo = struct {
        \\  pub fn doThing(foo: *@This(), allocator: Allocator) void {
        \\    _ = allocator;
        \\    _ = foo;
        \\  }
        \\};
        ,
        \\const Foo = struct {
        \\  pub fn doThing(foo: Foo, allocator: Allocator) void { }
        \\};
        ,
        \\const Foo = struct {
        \\  pub fn doThing(foo: *Foo, allocator: Allocator) void { }
        \\};
        ,
    };

    const fail = &[_][:0]const u8{
        "fn foo(x: u32, allocator: Allocator) void { }",
        "fn foo(x: u32, allocator: SomeExoticAllocatorThatIsWeird) void { }",
        "fn foo(x: u32, thingy: Allocator) void {  }",
        "fn foo(x: u32, thingy: std.mem.Allocator) void {  }",
        "fn foo(x: u32, y: std.heap.ArenaAllocator) void {  }",
        "const Foo = struct { pub fn bar(self: *Foo, x: u32, allocator: Allocator) void {} };",
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
