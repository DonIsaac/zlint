//! ## What This Rule Does
//! Checks for `try` statements used outside of error-returning functions.
//!
//! As a `compiler`-level lint, this rule checks for errors also caught by the
//! Zig compiler.
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! const std = @import("std");
//!
//! var not_in_a_function = try std.heap.page_allocator.alloc(u8, 8);
//!
//! fn foo() void {
//!   var my_str = try std.heap.page_allocator.alloc(u8, 8);
//! }
//!
//! fn bar() !void {
//!   const Baz = struct {
//!     property: u32 = try std.heap.page_allocator.alloc(u8, 8),
//!   };
//! }
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! fn foo() !void {
//!   var my_str = try std.heap.page_allocator.alloc(u8, 8);
//! }
//! ```
//!
//! Zig allows `try` in comptime scopes in or nested within functions. This rule
//! does not flag these cases.
//! ```zig
//! const std = @import("std");
//! fn foo(x: u32) void {
//!   comptime {
//!     // valid
//!     try bar(x);
//!   }
//! }
//! fn bar(x: u32) !void {
//!   return if (x == 0) error.Unreachable else void;
//! }
//! ```
//!
//! Zig also allows `try` on functions whose error union sets are empty. ZLint
//! does _not_ respect this case. Please refactor such functions to not return
//! an error union.
//! ```zig
//! const std = @import("std");
//! fn foo() !u32 {
//!   // compiles, but treated as a violation. `bar` should return `u32`.
//!   const x = try bar();
//!   return x + 1;
//! }
//! fn bar() u32 {
//!   return 1;
//! }
//! ```
//!
//! Named aliases for error unions are resolved through the semantic model, so
//! functions returning them are not flagged.
//! ```zig
//! const Error = error{Oops};
//! const Result = Error!void;
//! fn foo() Result {
//!   try bar();
//! }
//! ```
//!
//! Return types that this rule cannot statically resolve (imported types,
//! generic instantiations, etc.) are never flagged, since doing so risks a
//! false positive.

const std = @import("std");
const util = @import("util");
const Semantic = @import("../../Semantic.zig");
const builtins = @import("../../Semantic/builtins.zig");
const _rule = @import("../rule.zig");
const a = @import("../ast_utils.zig");

const Ast = Semantic.Ast;
const Node = Ast.Node;
const Scope = Semantic.Scope;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const NodeWrapper = _rule.NodeWrapper;
const Error = @import("../../Error.zig");
const Cow = util.Cow(false);

fn notInFnDiagnostic(ctx: *LinterContext, node: Node.Index) Error {
    return ctx.diagnostic("`try` cannot be used outside of a function or test block.", .{
        ctx.labelT(ctx.ast().firstToken(node), "there is nowhere to propagate errors to.", .{}),
    });
}

// Rule metadata
const HomelessTry = @This();
pub const meta: Rule.Meta = .{
    .name = "homeless-try",
    .category = .compiler,
    .default = .err,
};

// Runs on each node in the AST. Useful for syntax-based rules.
pub fn runOnNode(_: *const HomelessTry, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const scope_flags: []const Scope.Flags = ctx.scopes().scopes.items(.flags);

    const node = wrapper.node;
    if (node.tag != Node.Tag.@"try") return;

    const curr_scope = ctx.links().scopes.items[@intFromEnum(wrapper.idx)];
    var it = ctx.scopes().iterParents(curr_scope);

    while (it.next()) |scope| {
        const flags = scope_flags[scope.int()];
        // `try` is allowed in non-error returning comptime code; it causes
        // a compilation error.
        if (flags.s_comptime) return;
        const is_function_sig = flags.s_function and !flags.s_block;
        // functions create two scopes: one for the signature (binds params,
        // return type references symbols here) and one for the function body.
        // We want to check at the function signature level
        if (is_function_sig) {
            checkFnDecl(ctx, scope, wrapper.idx);
            return;
        } else if (flags.s_test) {
            // test statements implicitly have !void signatures.
            return;
        }
        if (flags.isContainer()) break;
    }

    ctx.report(notInFnDiagnostic(ctx, wrapper.idx));
}

/// Max const/var alias hops to follow. Bounds recursion, so alias cycles
/// (`const A = B; const B = A;`) terminate as `null` (unknown) instead of
/// blowing the stack. No visited-set needed.
const MAX_ALIAS_DEPTH: u8 = 8;

/// Whether `node` is a type expression that can never be an error union.
///
/// Only sound because callers check `hasErrorUnion` first: that handles the
/// `!T` prefix, so e.g. a `.ptr_type` node reaching here is known not to be
/// the payload of an error union.
fn isNeverErrorUnion(ctx: *LinterContext, node: Node.Index) bool {
    const ast = ctx.ast();
    return switch (ast.nodeTag(node)) {
        // struct/enum/union/opaque declarations
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        // pointers, slices, arrays, optionals, fn pointers, frames
        .ptr_type,
        .ptr_type_aligned,
        .ptr_type_sentinel,
        .ptr_type_bit_range,
        .array_type,
        .array_type_sentinel,
        .optional_type,
        .anyframe_type,
        .fn_proto,
        .fn_proto_simple,
        .fn_proto_multi,
        .fn_proto_one,
        => true,
        // `const Self = @This();`. Other builtins (`@Type`, `@FieldType`, ...)
        // can evaluate to anything, so they stay unclassifiable.
        .builtin_call_two, .builtin_call_two_comma => std.mem.eql(
            u8,
            ctx.semantic.tokenSlice(ast.nodeMainToken(node)),
            "@This",
        ),
        else => false,
    };
}

/// Classify a type node as an error union, following named `const`/`var`
/// aliases through the semantic model.
///
/// - `true`  — is, or resolves through aliases to, an error union
/// - `false` — definitively not an error union (a primitive, a fully resolved
///             concrete type, or — at depth 0 only — a return type that is
///             syntactically not an error union)
/// - `null`  — not statically classifiable (unresolved identifier, or an alias
///             chain we failed to follow to the end). Callers must treat this
///             like `true` and stay silent.
fn resolveAliasErrorUnion(ctx: *LinterContext, node: Node.Index, depth: u8) ?bool {
    const ast = ctx.ast();

    if (a.hasErrorUnion(ast, node)) return true;
    if (a.getRightmostIdentifier(ctx, node)) |ident| {
        if (std.mem.endsWith(u8, ident, "Error")) return true;
    }
    // Structural type expressions that definitively cannot be an error union.
    // Without this, aliases like `const Self = @This();` or
    // `const Str = []const u8;` would fall into the conservative bail below
    // and silently lose real violations.
    if (isNeverErrorUnion(ctx, node)) return false;

    // Field access (`mod.Result`), generic instantiation (`std.ArrayList(u8)`),
    // conditional return types, other builtin calls. We don't evaluate types,
    // so we can't rule out an error union.
    //
    // At depth 0 this is the return type as written: it is syntactically not an
    // error union, so report it — that is what the rule has always done. Past
    // depth 0 we're inside an alias chain we failed to follow, so bail rather
    // than risk a false positive on a `.compiler` rule.
    if (ast.nodeTag(node) != .identifier) return if (depth == 0) false else null;

    // Primitives are never in the symbol table (see the TODO in
    // `Semantic/Builder.zig`), so they're a terminal "definitely not fallible".
    const name = ctx.semantic.tokenSlice(ast.nodeMainToken(node));
    if (builtins.isPrimitiveType(name)) return false;

    if (depth >= MAX_ALIAS_DEPTH) return null;
    const init_node = a.resolveConstAlias(ctx, node) orelse return null;
    return resolveAliasErrorUnion(ctx, init_node, depth + 1);
}

fn checkFnDecl(ctx: *LinterContext, scope: Scope.Id, try_node: Node.Index) void {
    const ast = ctx.ast();
    const decl_node: Node.Index = ctx.scopes().scopes.items(.node)[scope.int()];

    if (ast.nodeTag(decl_node) != .fn_decl) {
        if (comptime util.IS_DEBUG) {
            util.assert(false, "function-bound scopes (w/o .s_block) should be bound to a function declaration node.", .{});
        } else {
            return;
        }
    }

    var buf: [1]Node.Index = undefined;
    const proto: Ast.full.FnProto = ast.fullFnProto(&buf, decl_node) orelse @panic(".fn_decl nodes always have a full fn proto available.");
    const return_type: Node.Index = proto.ast.return_type.unwrap() orelse return;

    // https://github.com/DonIsaac/zlint/issues/365
    //
    // `null` (unclassifiable) is deliberately treated as fallible; a false
    // negative is preferable to a build-failing false positive.
    if (resolveAliasErrorUnion(ctx, return_type, 0) orelse true) return;

    var e = ctx.diagnostic(
        "`try` cannot be used in functions that do not return errors.",
        .{
            if (proto.name_token) |name_token|
                ctx.labelT(name_token, "function `{s}` is declared here.", .{ctx.semantic.tokenSlice(name_token)})
            else
                ctx.labelT(ast.nodeMainToken(decl_node), "function is declared here.", .{}),
            ctx.labelT(ast.firstToken(try_node), "it cannot propagate error unions.", .{}),
        },
    );
    const return_type_src = ast.getNodeSource(return_type);
    e.help = Cow.fmt(ctx.gpa, "Change the return type to `!{s}`.", .{return_type_src}) catch @panic("OOM");
    ctx.report(e);
}

// Used by the Linter to register the rule so it can be run.
pub fn rule(self: *HomelessTry) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test HomelessTry {
    const t = std.testing;

    var homeless_try = HomelessTry{};
    var runner = RuleTester.init(t.allocator, homeless_try.rule());
    defer runner.deinit();

    // Code your rule should pass on
    const pass = &[_][:0]const u8{
        \\const std = @import("std");
        \\fn foo() std.mem.Allocator.Error!void {
        \\  _ = try std.heap.page_allocator.alloc(u8, 8);
        \\}
        ,
        \\const std = @import("std");
        \\fn foo() !void {
        \\  _ = try std.heap.page_allocator.alloc(u8, 8);
        \\}
        ,
        \\const std = @import("std");
        \\fn foo() anyerror!void {
        \\  _ = try std.heap.page_allocator.alloc(u8, 8);
        \\}
        ,
        \\fn foo() anyerror![]u8 {
        \\  const x = try std.heap.page_allocator.alloc(u8, 8);
        \\  return x;
        \\}
        ,
        \\const Foo = struct {
        \\  pub fn foo() anyerror![]u8 {
        \\    const x = try std.heap.page_allocator.alloc(u8, 8);
        \\    return x;
        \\  }
        \\};
        ,
        \\const Foo = struct {
        \\  const Error = error{ Bar };
        \\  pub fn foo() (Foo.Error || Allocator.Error)![]u8 {
        \\    const x = try std.heap.page_allocator.alloc(u8, 8);
        \\    return x;
        \\  }
        \\};
        ,
        // try within catch and fn call. Caused a wonky error before.
        \\const std = @import("std");
        \\const alloc = std.heap.page_allocator;
        \\const Foo = struct {
        \\  pub fn foo(thing: bool) !void {
        \\    const ns = std.array_list.Managed(*u8).init(alloc) catch unreachable;
        \\    ns.append(try alloc.create(u8)) catch unreachable;
        \\  }
        \\};
        ,
        \\const std = @import("std");
        \\fn foo(alloc: ?std.mem.Allocator) ![]const u8 {
        \\  if (alloc) |a| {
        \\    const result = try a.alloc(u8, 8);
        \\    @memset(&result, 0);
        \\    return result;
        \\  } else {
        \\    return "foo";
        \\  }
        \\}
        ,
        // test statements
        \\const std = @import("std");
        \\test "foo" {
        \\  try std.testing.expectEqual(1, 1);
        \\}
        ,
        \\const std = @import("std");
        \\fn add(a: u32, b: u32) u32 { return a + b; }
        \\test add {
        \\  try std.testing.expectEqual(2, add(1, 1));
        \\}
        ,
        \\pub fn iterationCount(this: *const @This()) !u32 {
        \\  return try std.fmt.parseInt(u32, this.i, 0);
        \\}
        ,
        // comptime code
        \\const std = @import("std");
        \\fn foo(x: u32) void {
        \\  comptime {
        \\    try bar(x);
        \\  }
        \\}
        ,
        \\const std = @import("std");
        \\fn foo(x: bool) void {
        \\  comptime {
        \\    if (x) {
        \\      try bar(x);
        \\    }
        \\  }
        \\}
        ,
        // conditional error union, or error union over a conditional
        \\const std = @import("std");
        \\pub fn push(list: std.array_list.Managed(u32), x: u32, comptime assume_capacity: bool) if(assume_capacity) void else Allocator.Error!void {
        \\  if (comptime assume_capacity) {
        \\    list.appendAssumeCapacity(x);
        \\  } else {
        \\    try list.append(x);
        \\  }
        \\}
        ,
        \\const std = @import("std");
        \\pub fn push(list: std.array_list.Managed(u32), x: u32, comptime assume_capacity: bool) if(!assume_capacity) Allocator.Error!void {
        \\  if (comptime assume_capacity) {
        \\    list.appendAssumeCapacity(x);
        \\  } else {
        \\    try list.append(x);
        \\  }
        \\}
        ,
        \\pub fn thing(comptime x: bool) !if (x) void else u32 {
        \\  if (x) {
        \\    try thing2();
        \\    return;
        \\  }
        \\  return 0;
        \\}
        ,
        // returning errors directly
        \\const FooError = error{ Foo, Bar };
        \\pub fn foo() FooError {
        \\  return FooError.Foo;
        \\}
        \\fn bar() FooError {
        \\  try foo();
        \\  return error.Bar;
        \\}
        ,
        //https://github.com/DonIsaac/zlint/issues/258
        \\fn getValue(value: u8) !u8 {
        \\    if (value == 1) return error.Test;
        \\
        \\    return value - 1;
        \\}
        \\
        \\pub fn main() !void {
        \\    loop: switch (3) {
        \\        3 => continue :loop try getValue(3),
        \\        2 => continue :loop try getValue(2),
        \\        1 => {},
        \\        else => unreachable
        \\    }
        \\}
        ,
        // https://github.com/DonIsaac/zlint/issues/365
        // named alias for an error union
        \\const E = error{A};
        \\const Result = E!void;
        \\fn bar() E!void { return error.A; }
        \\pub fn foo() Result {
        \\  try bar();
        \\}
        ,
        // chain of aliases
        \\const E = error{A};
        \\const Inner = E!void;
        \\const Result = Inner;
        \\fn bar() E!void { return error.A; }
        \\pub fn foo() Result {
        \\  try bar();
        \\}
        ,
        // aliases declared after the function that uses them
        \\pub fn foo() Result {
        \\  try bar();
        \\}
        \\fn bar() E!void { return error.A; }
        \\const E = error{A};
        \\const Result = E!void;
        ,
        // aliases we cannot resolve stay silent rather than risk a false
        // positive
        \\const mod = struct { pub const Result = error{A}!void; };
        \\const Result = mod.Result;
        \\fn bar() mod.Result { return error.A; }
        \\pub fn foo() Result {
        \\  try bar();
        \\}
        ,
        // an alias to a bare error set. matches how the inline form
        // (`fn foo() error{A}`) has always behaved.
        \\const E = error{A};
        \\fn bar() E!void { return error.A; }
        \\pub fn foo() E {
        \\  try bar();
        \\}
        ,
        // aliases resolve from the scope of the reference, so the inner
        // `Result` shadows the outer one
        \\const E = error{A};
        \\fn bar() E!void { return error.A; }
        \\const Result = void;
        \\const Inner = struct {
        \\  const Result = E!void;
        \\  pub fn foo() Result {
        \\    try bar();
        \\  }
        \\};
        ,
        // a return type with no binding at all is unclassifiable, so it stays
        // silent
        \\fn bar() error{A}!void { return error.A; }
        \\pub fn foo() Undeclared {
        \\  try bar();
        \\}
        ,
        // `var` aliases resolve the same way `const` ones do. not valid Zig
        // (a `type` binding must be `const`), but the resolver does not care
        // and neither should this rule.
        \\const E = error{A};
        \\var Result = E!void;
        \\fn bar() E!void { return error.A; }
        \\pub fn foo() Result {
        \\  try bar();
        \\}
    };

    const fail = &[_][:0]const u8{
        \\const std = @import("std");
        \\fn foo() void {
        \\  const x = try std.heap.page_allocator.alloc(u8, 8);
        \\}
        ,
        \\const std = @import("std");
        \\const x = try std.heap.page_allocator.alloc(u8, 8);
        ,
        \\const std = @import("std");
        \\fn foo() !void {
        \\  const Bar = struct {
        \\    baz: []u8 = try std.heap.page_allocator.alloc(u8, 8),
        \\  };
        \\}
        ,
        // conditional error union
        \\const std = @import("std");
        \\pub fn push(list: std.array_list.Managed(u32), x: u32, comptime assume_capacity: bool) if(assume_capacity) void else void {
        \\  if (comptime assume_capacity) {
        \\    list.appendAssumeCapacity(x);
        \\  } else {
        \\    try list.append(x);
        \\  }
        \\}
        ,
        // alias resolves to a primitive, so it is definitively not fallible
        \\const std = @import("std");
        \\const Result = void;
        \\fn foo() Result {
        \\  _ = try std.heap.page_allocator.alloc(u8, 8);
        \\}
        ,
        // aliases to structural types are still definitively not fallible
        \\const std = @import("std");
        \\const Foo = struct { x: u32 };
        \\fn foo() Foo {
        \\  _ = try std.heap.page_allocator.alloc(u8, 8);
        \\}
        ,
        \\const std = @import("std");
        \\const Str = []const u8;
        \\fn foo() Str {
        \\  _ = try std.heap.page_allocator.alloc(u8, 8);
        \\}
        ,
        \\const std = @import("std");
        \\const Foo = struct {
        \\  const Self = @This();
        \\  pub fn foo() Self {
        \\    _ = try std.heap.page_allocator.alloc(u8, 8);
        \\  }
        \\};
        ,
        // field-access return types are unresolvable, but still reported
        \\const mod = struct { pub const Result = void; };
        \\fn bar() !void {}
        \\fn foo() mod.Result {
        \\  try bar();
        \\}
        ,
        // generic instantiation, likewise
        \\const std = @import("std");
        \\fn foo() std.array_list.Managed(u8) {
        \\  _ = try std.heap.page_allocator.alloc(u8, 8);
        \\}
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
