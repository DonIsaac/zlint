//! ## What This Rule Does
//! Enforces Zig's naming convention.
//!
//! :::warning
//! Only functions and payload captures are checked at this time.
//! :::
//!
//! ## Functions
//! In general, functions that return values should use camelCase names while
//! those that return types should use PascalCase. Specially coming from Rust,
//! some people may be used to use snake_case for their functions, which can
//! lead to inconsistencies in the code.
//!
//! Functions whose names are dictated by an ABI are not checked. This includes
//! `extern` and `export` functions, as well as functions with a calling
//! convention other than `.auto` or `.@"inline"`.
//!
//! ## Payloads
//! Payload captures (`|x|`) should use snake_case. PascalCase captures are
//! allowed since they often capture types (`inline for (types) |T|`), as are
//! all-caps captures of constants. camelCase captures are allowed when they
//! are called as functions.
//!
//! Leading underscores are ignored when checking names.
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! fn this_one_is_in_snake_case() void {}
//! fn generic(T: type) type { return *T; }
//! fn foo(opt: ?u32) void { if (opt) |fooBar| _ = fooBar; }
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! fn thisFunctionIsInCamelCase() void {}
//! fn Generic(T: type) type { return *T; }
//! fn foo(opt: ?u32) void { if (opt) |foo_bar| _ = foo_bar; }
//! extern fn this_is_declared_in_c() void;
//! fn this_is_called_from_c() callconv(.c) void {}
//! ```

const std = @import("std");
const util = @import("util");
const Semantic = @import("../../Semantic.zig");
const _rule = @import("../rule.zig");

const Ast = Semantic.Ast;
const Node = Ast.Node;
const Symbol = Semantic.Symbol;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const ast_utils = @import("../ast_utils.zig");

const Error = @import("../../Error.zig");

const expectEqual = std.testing.expectEqual;

// Rule metadata
const CaseConvention = @This();
pub const meta: Rule.Meta = .{
    .name = "case-convention",
    .category = .style,
};

fn caseConventionDiagnostic(
    ctx: *LinterContext,
    name: []const u8,
    location: Ast.TokenIndex,
    comptime symbol_type: enum { function, payload },
    comptime expected: []const u8,
    actual: CaseType,
) Error {
    const type_str = switch (symbol_type) {
        .function => "Function",
        .payload => "Payload",
    };

    var diagnostic = ctx.diagnosticf(
        type_str ++ " '{s}' is in {s}",
        .{ name, actual.toStr() },
        .{ctx.spanT(location)},
    );
    diagnostic.help = .static("It should be in " ++ expected);
    return diagnostic;
}

fn genericsArePascalCase(ctx: *LinterContext, fn_name: []const u8, name: Ast.TokenIndex) Error {
    var d = ctx.diagnosticf(
        "Function '{s}' returns a type, but does not use PascalCase",
        .{fn_name},
        .{ctx.spanT(name)},
    );
    d.help = .static("By convention, Zig uses PascalCase for structs, generics, and all other type variables.");
    return d;
}

const CaseType = enum {
    lowercase,
    uppercase,
    @"kebab-case",
    PascalCase,
    snake_case,
    SCREAMING_SNAKE_CASE,
    camelCase,
    /// Mixes conventions, e.g. `fooBar_baz` or `Foo-bar`.
    mixed,

    fn toStr(self: CaseType) []const u8 {
        return if (self == .mixed) "mixed case" else @tagName(self);
    }
};

/// Leading underscores are not part of a name's case.
fn stripLeadingUnderscores(name: []const u8) []const u8 {
    return std.mem.trimStart(u8, name, "_");
}

/// `name` should already have its leading underscores stripped.
fn getCase(name: []const u8) CaseType {
    var has_underscore = false;
    var has_dash = false;
    var has_upper = false;
    var has_lower = false;
    var first_alpha_upper: ?bool = null;
    for (name) |c| switch (c) {
        '_' => has_underscore = true,
        '-' => has_dash = true,
        'A'...'Z' => {
            has_upper = true;
            if (first_alpha_upper == null) first_alpha_upper = true;
        },
        'a'...'z' => {
            has_lower = true;
            if (first_alpha_upper == null) first_alpha_upper = false;
        },
        else => {},
    };

    if (has_dash) {
        return if (has_underscore or has_upper) .mixed else .@"kebab-case";
    }
    if (has_underscore) {
        if (!has_upper) return .snake_case;
        return if (has_lower) .mixed else .SCREAMING_SNAKE_CASE;
    }
    if (first_alpha_upper orelse false) {
        return if (has_lower) .PascalCase else .uppercase;
    }
    return if (has_upper) .camelCase else .lowercase;
}

pub fn runOnSymbol(_: *const CaseConvention, symbol: Symbol.Id, ctx: *LinterContext) void {
    const symbols = ctx.symbols().symbols.slice();
    const symbol_flags: []const Symbol.Flags = symbols.items(.flags);

    const flags = symbol_flags[symbol.int()];
    if (flags.s_extern or flags.s_export) return;
    if (flags.s_fn) return checkFunction(ctx, symbol, symbols);
    if (flags.s_payload) return checkPayload(ctx, symbol, symbols);
}

fn checkFunction(ctx: *LinterContext, symbol: Symbol.Id, symbols: std.MultiArrayList(Symbol).Slice) void {
    const id = symbol.into(usize);
    const decl: Node.Index = symbols.items(.decl)[id];

    var buf: [1]Node.Index = undefined;
    const func = ctx.ast().fullFnProto(&buf, decl) orelse {
        util.debugAssert(false, "Symbol flagged as a function does not correspond to an fn-like node", .{});
        return;
    };

    if (usesAbiCallconv(ctx, &func)) return;

    const fn_name: []const u8 = symbols.items(.name)[id];
    const name_token = func.name_token orelse return;
    const bare_name = stripLeadingUnderscores(fn_name);
    const case = getCase(bare_name);
    const is_value_name = case == .camelCase or case == .lowercase;
    switch (fnReturnKind(ctx, &func)) {
        .type => if (!isTypeName(bare_name, case)) {
            ctx.report(genericsArePascalCase(ctx, fn_name, name_token));
        },
        // e.g. `?type`, `[]const type`. Both conventions are common.
        .wrapped_type => if (!is_value_name and !isTypeName(bare_name, case)) {
            ctx.report(caseConventionDiagnostic(ctx, fn_name, name_token, .function, "camelCase or PascalCase", case));
        },
        .value => if (!is_value_name) {
            ctx.report(caseConventionDiagnostic(ctx, fn_name, name_token, .function, "camelCase", case));
        },
    }
}

/// PascalCase, or a single-letter generic like `T`.
fn isTypeName(bare_name: []const u8, case: CaseType) bool {
    return case == .PascalCase or (case == .uppercase and bare_name.len == 1);
}

fn checkPayload(ctx: *LinterContext, symbol: Symbol.Id, symbols: std.MultiArrayList(Symbol).Slice) void {
    const id = symbol.into(usize);
    const name = symbols.items(.name)[id];
    const token = symbols.items(.token)[id].unwrap() orelse return;

    if (name.len == 0) {
        @branchHint(.cold);
        return;
    }

    const case = getCase(stripLeadingUnderscores(name));
    switch (case) {
        .snake_case, .lowercase => return,
        // PascalCase payloads capture types (`inline for (types) |T|`)
        .PascalCase => return,
        // all-caps payloads capture constants
        .uppercase, .SCREAMING_SNAKE_CASE => return,
        // callables are camelCase
        .camelCase => if (isCalled(ctx, symbols.items(.references)[id].items)) return,
        .@"kebab-case", .mixed => {},
    }
    ctx.report(caseConventionDiagnostic(ctx, name, token.int(), .payload, "snake_case", case));
}

fn isCalled(ctx: *LinterContext, references: []const Semantic.Reference.Id) bool {
    const ref_flags = ctx.symbols().references.items(.flags);
    for (references) |ref| {
        if (ref_flags[ref.int()].isSelfCall()) return true;
    }
    return false;
}

/// Functions with a calling convention other than `.auto` or `.@"inline"`
/// have names dictated by an ABI (e.g. `callconv(.c)`, `callconv(.naked)`,
/// `callconv(lib.calling_conv)`).
fn usesAbiCallconv(ctx: *LinterContext, fn_proto: *const Ast.full.FnProto) bool {
    const expr = fn_proto.ast.callconv_expr.unwrap() orelse return false;
    const ast = ctx.ast();
    const token = switch (ast.nodeTag(expr)) {
        .enum_literal => ast.nodeMainToken(expr),
        // std.builtin.CallingConvention.auto
        .field_access => ast.nodeData(expr).node_and_token[1],
        else => return true,
    };
    const name = ctx.semantic.tokenSlice(token);
    const zig_callconvs = [_][]const u8{ "auto", "@\"inline\"" };
    for (zig_callconvs) |cc| {
        if (std.mem.eql(u8, name, cc)) return false;
    }
    return true;
}

const ReturnKind = enum {
    /// `type` or `E!type`
    type,
    /// `type` wrapped in a pointer, slice, array, or optional, e.g. `?type`
    wrapped_type,
    value,
};

fn fnReturnKind(ctx: *LinterContext, fn_proto: *const Ast.full.FnProto) ReturnKind {
    const ast = ctx.ast();
    var node = fn_proto.ast.return_type.unwrap() orelse return .value;
    while (ast.nodeTag(node) == .error_union) {
        node = ast.nodeData(node).node_and_node[1];
    }
    if (isTypeIdentifier(ctx, node)) return .type;

    while (true) {
        node = ast_utils.getInnerType(ast, node);
        const array = ast.fullArrayType(node) orelse break;
        node = array.ast.elem_type;
    }
    return if (isTypeIdentifier(ctx, node)) .wrapped_type else .value;
}

fn isTypeIdentifier(ctx: *LinterContext, node: Node.Index) bool {
    const ast = ctx.ast();
    return ast.nodeTag(node) == .identifier and
        std.mem.eql(u8, ctx.semantic.tokenSlice(ast.nodeMainToken(node)), "type");
}

// Used by the Linter to register the rule so it can be run.
pub fn rule(self: *CaseConvention) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test CaseConvention {
    const t = std.testing;

    var case_convention = CaseConvention{};
    var runner = RuleTester.init(t.allocator, case_convention.rule());
    defer runner.deinit();

    const pass = &[_][:0]const u8{
        // functions
        "fn alllowercasefunctionsarealwaysgreen() void {}",
        "fn thisFunctionIsInCamelCase() void {}",
        "fn Generic(T: type) type { return *T; }",
        "fn FooBar() type { return u32; }",
        "extern fn this_is_declared_in_c() void;",
        // payloads
        "const x = bar() catch |e| return e;",
        "fn foo(x: u32) u32 { return x; }",
        "fn f() void {}",
        "fn foo2() void {}",
        "fn fooBar2() void {}",
        "const x = bar() catch |foo_bar| return foo_bar;",
        "const x = bar() catch |foo_bar_2| return foo_bar_2;",
        "const x = bar() catch |_| return;",
        "fn f(opt: ?u32) void { if (opt) |x| _ = x; }",
        "fn f(opt: ?u32) void { if (opt) |foo_bar| _ = foo_bar; }",
        "fn f(opt: ?u32) void { while (opt) |foo_bar| _ = foo_bar; }",
        "fn f(xs: []u32) void { for (xs) |x| _ = x; }",
        "fn f(xs: []u32) void { for (xs, 0..) |x, i| _ = .{ x, i }; }",
        "fn f(xs: []u32) void { for (xs) |*foo_bar| _ = foo_bar; }",
        "fn f(u: union(enum) { a: u32 }) void { switch (u) { .a => |v| _ = v } }",
        "fn f(u: union(enum) { a: u32 }) void { switch (u) { .a => |foo_bar| _ = foo_bar } }",
        "fn A() type { return u32; }",
        "fn T() type { return u32; }",
        "fn Foo() !type { return u32; }",
        "fn Foo() error{A}!type { return u32; }",
        "fn fieldTypes() []const type { return &.{u32}; }",
        "fn maybeType() ?type { return null; }",
        "fn typePtr() *const type { return &u32; }",
        "fn MaybeType() ?type { return null; }",
        "fn FieldTypes() []const type { return &.{u32}; }",
        "fn fieldTypes() [2]type { return .{ u32, u8 }; }",
        "fn FieldTypes() [2]type { return .{ u32, u8 }; }",
        "fn FieldTypes() [2:void]type { return .{ u32, u8 }; }",
        "fn FieldTypes() *const [2]?type { return &.{ u32, null }; }",
        "fn T() ?type { return null; }",
        // leading underscores
        "fn _private() void {}",
        "fn _privateHelper() void {}",
        "fn __foo() void {}",
        "fn _Foo() type { return u32; }",
        "fn _T() type { return u32; }",
        // ABI-dictated names
        "export fn foo_bar() void {}",
        "export fn FooBar() void {}",
        "fn foo_bar() callconv(.c) void {}",
        "fn foo_bar() callconv(.C) void {}",
        "fn foo_bar() callconv(std.builtin.CallingConvention.c) void {}",
        "fn foo_bar() callconv(.naked) void {}",
        "fn foo_bar() callconv(.{ .arm_aapcs = .{} }) void {}",
        "const cc: std.builtin.CallingConvention = .c; fn foo_bar() callconv(cc) void {}",
        "const lib = struct { const cc = .c; }; fn foo_bar() callconv(lib.cc) void {}",
        // callable payloads
        "fn f(cb: ?*const fn () void) void { if (cb) |doThing| doThing(); }",
        "fn f(cb: ?*const fn () void) void { if (cb) |doThing| { doThing(); } }",
        "fn f(cbs: []const *const fn () void) void { for (cbs) |cbFn| cbFn(); }",
        // constant payloads
        "const x = bar() catch |FOO_BAR| return FOO_BAR;",
        "fn f(comptime xs: anytype) void { inline for (xs) |MAX_LEN| _ = MAX_LEN; }",
        // type payloads
        "const x = bar() catch |FooBar| return FooBar;",
        "const x = bar() catch |FOO| return FOO;",
        "fn f(comptime types: anytype) void { inline for (types) |T| _ = T; }",
        "fn f(comptime types: anytype) void { inline for (types, 0..) |JsApi, i| _ = .{ JsApi, i }; }",
        "fn f(i: std.builtin.Type) void { switch (i) { .int => |IntType| _ = IntType, else => {} } }",
    };

    const fail = &[_][:0]const u8{
        // functions
        "fn ThisFunctionIsInPascalCase() void {}",
        "fn @\"this-one-is-in-kebab-case\"() void {}",
        "fn this_one_is_in_snake_case() void {}",
        "fn @\"This-is-both-Pascal-and-Kebab-kinda\"() void {}",
        "fn This_is_both_snake_case_and_pascal_kinda() void {}",
        "fn This_is_both_snake_case_and_pascal_kinda(a: u32, b: u32, c: u32, d: u32) void {}",
        "fn fooBar() type { return u32; }",
        "fn NotGeneric(T: type) T { return T{}; }",
        "fn FOO() type { return u32; }",
        "fn foo_bar() ?type { return null; }",
        "fn Foo_bar() ?type { return null; }",
        "fn FOO() [2]type { return .{ u32, u8 }; }",
        "fn T() [2]u32 { return .{ 1, 2 }; }",
        "fn foo_bar() !type { return u32; }",
        "fn FOO_BAR() void {}",
        "fn fooBar_baz() void {}",
        "fn _foo_bar() void {}",
        "fn _FooBar() void {}",
        // payloads
        "const x = bar() catch |fooBar| return fooBar;",
        "const x = bar() catch |@\"foo-bar\"| return @\"foo-bar\";",
        "const x = bar() catch |Foo_bar| return Foo_bar;",
        "fn f(opt: ?u32) void { if (opt) |fooBar| _ = fooBar; }",
        "fn f(opt: ?u32) void { while (opt) |fooBar| _ = fooBar; }",
        "fn f(xs: []u32) void { for (xs) |fooBar| _ = fooBar; }",
        "fn f(cb: ?*const fn () void) void { if (cb) |doThing| _ = doThing; }",
        // method calls on a payload do not make it callable
        "fn f(opt: ?std.ArrayList(u8)) void { if (opt) |myList| myList.deinit(); }",
        "fn f(opt: ?Foo) void { if (opt) |myFoo| myFoo.bar.baz(); }",
        "fn f(opt: ??Foo) void { if (opt) |myFoo| myFoo.?.baz(); }",
        "fn f(xs: []const usize, arr: []Foo) void { for (xs) |idxVal| arr[idxVal].baz(); }",
        // Zig calling conventions
        "fn foo_bar() callconv(.auto) void {}",
        "fn foo_bar() callconv(.@\"inline\") void {}",
        "fn foo_bar() callconv(std.builtin.CallingConvention.auto) void {}",
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}

test getCase {
    // lower
    try expectEqual(.lowercase, getCase("foo"));
    try expectEqual(.lowercase, getCase("foo bar"));
    try expectEqual(.lowercase, getCase("foobar"));
    try expectEqual(.lowercase, getCase("foo2"));

    // upper
    try expectEqual(.uppercase, getCase("FOO"));
    try expectEqual(.uppercase, getCase("T"));
    try expectEqual(.uppercase, getCase("U8"));

    // camel
    try expectEqual(.camelCase, getCase("fooBar"));
    try expectEqual(.camelCase, getCase("fooBar2"));

    // pascal
    try expectEqual(.PascalCase, getCase("Foo"));
    try expectEqual(.PascalCase, getCase("FooBar"));

    // kebab
    try expectEqual(.@"kebab-case", getCase("foo-bar"));
    try expectEqual(.@"kebab-case", getCase("-foo"));
    try expectEqual(.@"kebab-case", getCase("-"));

    // snake
    try expectEqual(.snake_case, getCase("foo_bar"));
    try expectEqual(.snake_case, getCase("foo_bar_2"));
    try expectEqual(.snake_case, getCase("foo_"));
    try expectEqual(.SCREAMING_SNAKE_CASE, getCase("FOO_BAR"));

    // mixed
    try expectEqual(.mixed, getCase("foo-bar_baz"));
    try expectEqual(.mixed, getCase("FooBar_baz"));
    try expectEqual(.mixed, getCase("fooBar_baz"));
    try expectEqual(.mixed, getCase("Foo_bar"));
    try expectEqual(.mixed, getCase("draw25E2_25E5"));
    try expectEqual(.mixed, getCase("Foo-bar"));
    try expectEqual(.mixed, getCase("FOO-BAR"));

    // leading underscores are ignored
    try expectEqual(.camelCase, getCase(stripLeadingUnderscores("_fooBar")));
    try expectEqual(.lowercase, getCase(stripLeadingUnderscores("__foo")));
    try expectEqual(.snake_case, getCase(stripLeadingUnderscores("_foo_bar")));
    try expectEqual(.PascalCase, getCase(stripLeadingUnderscores("_Foo")));
    try expectEqual(.lowercase, getCase(stripLeadingUnderscores("_")));

    // edge cases
    try expectEqual(.lowercase, getCase(""));
    try expectEqual(.lowercase, getCase(" "));
}
