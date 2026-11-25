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
//!
//! fn qux() !void {
//!   defer try std.fs.cwd().deleteFile("tmp.txt");
//!   errdefer {
//!     try std.fs.cwd().deleteFile("tmp.txt");
//!   }
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
//! Zig allows `try` in comptime blocks and expressions within functions, since
//! returned errors become compile errors. This rule does not flag these cases.
//! ```zig
//! const std = @import("std");
//! fn foo(x: u32) void {
//!   comptime {
//!     // valid
//!     try bar(x);
//!   }
//!   // also valid
//!   _ = comptime try bar(1);
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
//! Named aliases for error unions declared in the same file, including ones
//! inside a container, are resolved, so functions returning them are not
//! flagged.
//! ```zig
//! const Error = error{Oops};
//! const Result = Error!void;
//! const mod = struct {
//!   pub const Result = Error!u32;
//! };
//! fn foo() Result {
//!   try bar();
//! }
//! fn baz() mod.Result {
//!   try bar();
//!   return 1;
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

fn inDeferDiagnostic(ctx: *LinterContext, try_node: Node.Index, defer_node: Node.Index) Error {
    const ast = ctx.ast();
    const defer_token = ast.nodeMainToken(defer_node);
    const keyword = ctx.semantic.tokenSlice(defer_token);
    var e = ctx.diagnosticf("`try` cannot be used inside of `{s}` statements.", .{keyword}, .{
        ctx.labelT(defer_token, "`{s}` statement is here.", .{keyword}),
        ctx.labelT(ast.firstToken(try_node), "errors cannot be propagated from here.", .{}),
    });
    e.help = Cow.static("Handle the error with `catch` instead.");
    return e;
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

    const curr_scope = ctx.links().scopes.items[@backingInt(wrapper.idx)];
    var it = ctx.scopes().iterParents(curr_scope);

    while (it.next()) |scope| {
        const flags = scope_flags[scope.int()];
        if (flags.isContainer()) break;
        const is_function_sig = flags.s_function and !flags.s_block;
        // functions create two scopes: one for the signature (binds params,
        // return type references symbols here) and one for the function body.
        // We want to check at the function signature level
        if (is_function_sig or flags.s_test) {
            const body_node = ctx.scopes().scopes.items(.node)[scope.int()];
            switch (classifyTry(ctx, wrapper.idx, body_node)) {
                .deferred => |defer_node| ctx.report(inDeferDiagnostic(ctx, wrapper.idx, defer_node)),
                // a returned error becomes a compile error, so the function
                // need not return an error union.
                .@"comptime" => {},
                // test statements implicitly have !void signatures.
                .runtime => if (is_function_sig) checkFnDecl(ctx, body_node, wrapper.idx),
            }
            return;
        }
    }

    ctx.report(notInFnDiagnostic(ctx, wrapper.idx));
}

const TryContext = union(enum) {
    runtime,
    @"comptime",
    /// The innermost `defer` or `errdefer` containing the `try`.
    deferred: Node.Index,
};

/// Classify a `try` by the AST between it and the function or test it is in.
/// `defer` takes precedence, since `try` is never allowed there.
fn classifyTry(ctx: *LinterContext, try_node: Node.Index, boundary: Node.Index) TryContext {
    const tags = ctx.ast().nodes.items(.tag);
    var in_comptime = false;
    var it = ctx.links().iterParentIds(try_node);
    while (it.next()) |id| {
        if (id == boundary) break;
        switch (tags[@backingInt(id)]) {
            .@"defer", .@"errdefer" => return .{ .deferred = id },
            .@"comptime" => in_comptime = true,
            else => {},
        }
    }
    return if (in_comptime) .@"comptime" else .runtime;
}

/// How many aliases and `mod.Foo` lookups to follow before giving up. This
/// also stops alias cycles like `const A = B; const B = A;`.
const MAX_RESOLVE_DEPTH: u8 = 8;

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

/// Is this return type an error union? Follows aliases declared in this
/// file, like `Result` or `mod.Result`.
///
/// Returns null when we can't tell (imports, `Result(u32)`, `@This()`
/// namespaces, too many aliases). Callers should stay quiet in that case.
fn resolveAliasErrorUnion(ctx: *LinterContext, node: Node.Index, depth: u8) ?bool {
    const ast = ctx.ast();

    if (a.hasErrorUnion(ast, node)) return true;
    // Structural type expressions that definitively cannot be an error union.
    // Without this, aliases like `const Self = @This();` or
    // `const Str = []const u8;` would fall into the conservative bail below
    // and silently lose real violations.
    if (isNeverErrorUnion(ctx, node)) return false;

    switch (ast.nodeTag(node)) {
        .identifier => {
            const name = ctx.semantic.tokenSlice(ast.nodeMainToken(node));
            // `anyerror` is an error set, so `try` is allowed.
            if (std.mem.eql(u8, name, "anyerror")) return true;
            // Other primitives are never in the symbol table (see the TODO in
            // `Semantic/Builder.zig`), so they're a terminal "definitely not
            // fallible".
            if (builtins.isPrimitiveType(name)) return false;
        },
        // `if (c) A else B` can fail if either branch can. No `else` means
        // `void`.
        .if_simple, .@"if" => {
            const if_full = ast.fullIf(node).?;
            const then_eu = resolveAliasErrorUnion(ctx, if_full.ast.then_expr, depth) orelse return null;
            const else_expr = if_full.ast.else_expr.unwrap() orelse return then_eu;
            const else_eu = resolveAliasErrorUnion(ctx, else_expr, depth) orelse return null;
            return then_eu or else_eu;
        },
        else => {},
    }

    const decl_init = a.resolveDeclInit(MAX_RESOLVE_DEPTH, ctx, node, depth) orelse return null;
    return resolveAliasErrorUnion(ctx, decl_init, depth + 1);
}

fn checkFnDecl(ctx: *LinterContext, decl_node: Node.Index, try_node: Node.Index) void {
    const ast = ctx.ast();

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
        \\const std = @import("std");
        \\fn foo(comptime n: u64, x: u64) bool {
        \\  return x < comptime try std.math.powi(u64, 10, n);
        \\}
        ,
        \\fn foo() void {
        \\  const x = comptime blk: {
        \\    break :blk try bar();
        \\  };
        \\  _ = x;
        \\}
        ,
        \\fn foo() void {
        \\  _ = comptime (try bar()) + 1;
        \\}
        ,
        // functions and containers inside a `defer` are not part of it
        \\fn foo() !void {
        \\  defer {
        \\    const S = struct {
        \\      fn bar() !void {
        \\        try baz();
        \\      }
        \\    };
        \\    _ = S;
        \\  }
        \\}
        ,
        \\fn foo() !void {
        \\  defer bar() catch {};
        \\  errdefer bar() catch {};
        \\  try bar();
        \\}
        ,
        \\fn foo() !void {
        \\  try bar();
        \\  errdefer {
        \\    const S = struct {
        \\      fn baz() !void {
        \\        try bar();
        \\      }
        \\    };
        \\    _ = S;
        \\  }
        \\  try bar();
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
        \\const mod = @import("mod.zig");
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
        // `anyerror` is an error set too, directly or through an alias
        \\fn bar() !void {}
        \\pub fn foo() anyerror {
        \\  try bar();
        \\  return error.A;
        \\}
        ,
        \\const E = anyerror;
        \\fn bar() !void {}
        \\pub fn foo() E {
        \\  try bar();
        \\  return error.A;
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
        ,
        // imported, `@This()`, and generic return types are unresolvable, so
        // they stay silent
        \\const errs = @import("errs.zig");
        \\fn work() !u32 { return 1; }
        \\pub fn run() errs.Result {
        \\  const x = try work();
        \\  _ = x;
        \\}
        ,
        \\const Self = @This();
        \\const Result = void;
        \\fn bar() !void {}
        \\fn foo() Self.Result {
        \\  try bar();
        \\}
        ,
        \\fn Result(comptime T: type) type { return error{A}!T; }
        \\fn bar() !void {}
        \\fn foo() Result(u32) {
        \\  try bar();
        \\  return 1;
        \\}
        ,
        \\const std = @import("std");
        \\fn foo() std.array_list.Managed(u8) {
        \\  _ = try std.heap.page_allocator.alloc(u8, 8);
        \\}
        ,
        // a conditional return type is unresolvable if any branch is
        \\const mod = @import("mod.zig");
        \\const E = error{A};
        \\fn bar() E!void { return error.A; }
        \\pub fn foo(comptime c: bool) if (c) void else mod.Result {
        \\  try bar();
        \\}
        ,
        // declarations inside containers in the same file are resolved
        \\const E = error{A};
        \\const mod = struct { pub const Result = E!void; };
        \\fn bar() E!void { return error.A; }
        \\pub fn foo() mod.Result {
        \\  try bar();
        \\}
        ,
        \\const E = error{A};
        \\fn bar() E!void { return error.A; }
        \\const outer = struct {
        \\  pub const inner = struct {
        \\    const Inner = E!void;
        \\    pub const Result = Inner;
        \\  };
        \\};
        \\const alias = outer.inner;
        \\pub fn foo() alias.Result {
        \\  try bar();
        \\}
        ,
        \\const E = error{A};
        \\fn bar() E!void { return error.A; }
        \\const mod = struct { pub const Result = error{A}; };
        \\pub fn foo() mod.Result {
        \\  try bar();
        \\}
        ,
        \\const E = error{A};
        \\fn bar() E!void { return error.A; }
        \\pub fn foo() struct { const Result = E!void; }.Result {
        \\  try bar();
        \\}
        ,
        // only the container's own declarations are members, not locals
        // inside its methods
        \\const E = error{A};
        \\fn bar() E!void { return error.A; }
        \\const mod = struct {
        \\  fn baz() void { const Result = void; _ = Result; }
        \\  pub const Result = E!void;
        \\};
        \\pub fn foo() mod.Result {
        \\  try bar();
        \\}
        ,
        // unknown members, and namespaces that are not containers, stay
        // silent
        \\fn bar() !void {}
        \\const mod = struct {};
        \\pub fn foo() mod.Missing {
        \\  try bar();
        \\}
        ,
        \\fn bar() !void {}
        \\const mod = if (true) struct { pub const Result = void; } else struct {};
        \\pub fn foo() mod.Result {
        \\  try bar();
        \\}
        ,
        \\fn bar() !void {}
        \\fn foo(x: anytype) @TypeOf(x).Result {
        \\  try bar();
        \\}
        ,
        // cyclic namespace aliases terminate
        \\fn bar() !void {}
        \\const A = A.B;
        \\pub fn foo() A.B {
        \\  try bar();
        \\}
        ,
        \\fn bar() !void {}
        \\const A = B.Inner;
        \\const B = struct { const Inner = A; };
        \\pub fn foo() A.C {
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
        \\fn bar() !void {}
        \\fn foo() u1 {
        \\  try bar();
        \\  return 0;
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
        \\fn bar() !void {}
        \\fn foo(comptime c: bool) if (c) u32 {
        \\  try bar();
        \\}
        ,
        \\const std = @import("std");
        \\const Result = void;
        \\pub fn foo(comptime c: bool) if (c) Result else []const u8 {
        \\  _ = try std.heap.page_allocator.alloc(u8, 8);
        \\}
        ,
        // declarations inside containers in the same file are resolved
        \\const mod = struct { pub const Result = void; };
        \\fn bar() !void {}
        \\fn foo() mod.Result {
        \\  try bar();
        \\}
        ,
        \\fn bar() !void {}
        \\const outer = struct {
        \\  pub const inner = struct {
        \\    pub const Point = struct { x: u32 };
        \\  };
        \\};
        \\const alias = outer.inner;
        \\fn foo() alias.Point {
        \\  try bar();
        \\}
        ,
        // a name ending in `Error` is not an error set
        \\const ParseError = struct { msg: []const u8 };
        \\fn bar() !void {}
        \\fn foo() ParseError {
        \\  try bar();
        \\}
        ,
        // `@"anyerror"` names a declaration, not the primitive error set
        \\const @"anyerror" = void;
        \\fn bar() !void { return error.A; }
        \\fn foo() @"anyerror" {
        \\  try bar();
        \\}
        ,
        // `try` is never allowed outside a function, even at comptime
        \\const x = comptime try bar();
        ,
        \\comptime {
        \\  try bar();
        \\}
        ,
        // `comptime` does not extend into nested functions
        \\fn foo() void {
        \\  _ = comptime struct {
        \\    fn bar() void {
        \\      try baz();
        \\    }
        \\  };
        \\}
        ,
        \\fn foo() void {
        \\  _ = comptime struct {
        \\    x: u32 = try bar(),
        \\  };
        \\}
        ,
        // `try` is never allowed inside `defer` or `errdefer`
        \\fn foo() !void {
        \\  defer try bar();
        \\}
        ,
        \\fn foo() !void {
        \\  defer {
        \\    try bar();
        \\  }
        \\}
        ,
        \\fn foo(x: bool) !void {
        \\  defer {
        \\    if (x) {
        \\      try bar();
        \\    }
        \\  }
        \\}
        ,
        \\fn foo() !void {
        \\  errdefer try bar();
        \\}
        ,
        \\fn foo() void {
        \\  defer try bar();
        \\}
        ,
        \\fn foo() void {
        \\  defer comptime try bar();
        \\}
        ,
        \\fn foo() void {
        \\  comptime {
        \\    defer try bar();
        \\  }
        \\}
        ,
        \\test "foo" {
        \\  defer try bar();
        \\}
        ,
        \\fn foo() !void {
        \\  defer {
        \\    defer try bar();
        \\  }
        \\}
        ,
        \\fn foo(xs: []const u32) !void {
        \\  for (xs) |_| {
        \\    bar() catch {
        \\      defer try bar();
        \\    };
        \\  }
        \\}
        ,
        // nested functions are checked on their own
        \\fn foo() !void {
        \\  defer {
        \\    const S = struct {
        \\      fn baz() void {
        \\        try bar();
        \\      }
        \\    };
        \\    _ = S;
        \\  }
        \\}
        ,
        \\comptime {
        \\  defer try bar();
        \\}
        ,
        \\fn foo() !void {
        \\  defer {
        \\    const S = struct {
        \\      x: u32 = try bar(),
        \\    };
        \\    _ = S;
        \\  }
        \\}
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
