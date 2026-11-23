//! ## What This Rule Does
//! Enforces Zig's naming convention.
//!
//! :::warning
//! Only functions are checked at this time.
//! :::
//!
//! ## Functions
//! In general, functions that return values should use camelCase names while
//! those that return types should use PascalCase. Specially coming from Rust,
//! some people may be used to use snake_case for their functions, which can
//! lead to inconsistencies in the code.
//!
//! Note that `extern`  functions are not checked since you cannot change
//! their names.
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! fn this_one_is_in_snake_case() void {}
//! fn generic(T: type) T { return T{}; }
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! fn thisFunctionIsInCamelCase() void {}
//! fn Generic(T: type) T { return T{}; }
//! extern fn this_is_declared_in_c() void;
//! ```

const std = @import("std");
const util = @import("util");
const Semantic = @import("../../Semantic.zig");
const _rule = @import("../rule.zig");
const ast_utils = @import("../ast_utils.zig");

const Ast = Semantic.Ast;
const Node = Ast.Node;
const Symbol = Semantic.Symbol;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;

const Error = @import("../../Error.zig");
const Cow = util.Cow(false);

const expectEqual = std.testing.expectEqual;

// Rule metadata
const CaseConvention = @This();
pub const meta: Rule.Meta = .{
    .name = "case-convention",
    .category = .style,
};

fn functionNameDiagnostic(ctx: *LinterContext, fn_name: []const u8, case: CaseType, name: Ast.TokenIndex) Error {
    if (case == .NotCamelCase) {
        return ctx.diagnosticf(
            "Function {s} name is not in camelCase",
            .{fn_name},
            .{ctx.spanT(name)},
        );
    }
    return ctx.diagnosticf(
        "Function {s} name is in {s}. It should be camelCase",
        .{ fn_name, @tagName(case) },
        .{ctx.spanT(name)},
    );
}

fn caseConventionDiagnostic(
    ctx: *LinterContext,
    name: []const u8,
    location: Ast.TokenIndex,
    comptime symbol_type: enum { function, payload },
    comptime expected: CaseType,
    actual: CaseType,
) Error {
    std.debug.assert(expected != actual);
    const type_str = switch (symbol_type) {
        .function => "Function",
        .payload => "Payload",
    };

    var diagnostic = ctx.diagnosticf(
        type_str ++ " '{s}' is in {s}",
        .{ name, actual.toStr() },
        .{ctx.spanT(location)},
    );
    if (actual != .NotCamelCase) {
        diagnostic.help = Cow.fmt(ctx.gpa, "It should be in {s}", .{expected.toStr()}) catch @panic("OOM");
    }
    return diagnostic;
}

fn genericsArePascaleCase(ctx: *LinterContext, fn_name: []const u8, name: Ast.TokenIndex) Error {
    var d = ctx.diagnosticf(
        "Function '{s}' returns a type, but does not use PascalCase",
        .{fn_name},
        .{ctx.spanT(name)},
    );
    d.help = .static("By convention, Zig uses PascalCase for structs, generics, and all other type variables.");
    return d;
}

fn hasDashes(string: []const u8) bool {
    return std.mem.findScalar(u8, string, '-') != null;
}

fn hasUnderline(string: []const u8) bool {
    return std.mem.findScalar(u8, string, '_') != null;
}

fn hasUppercaseFirstLetter(string: []const u8) bool {
    for (string) |c| {
        if (!std.ascii.isAlphabetic(c)) continue;
        return std.ascii.isUpper(c);
    }
    return false;
}

test hasUppercaseFirstLetter {
    try std.testing.expect(hasUppercaseFirstLetter("A"));
    try std.testing.expect(hasUppercaseFirstLetter("$$$_A"));
    try std.testing.expect(!hasUppercaseFirstLetter("$$$_a"));
    try std.testing.expect(!hasUppercaseFirstLetter("$$$_"));
}

fn hasLower(string: []const u8) bool {
    for (string) |c| {
        if (std.ascii.isLower(c)) return true;
    }
    return false;
}

fn hasUpper(string: []const u8) bool {
    for (string) |c| {
        if (std.ascii.isUpper(c)) return true;
    }
    return false;
}

fn isLowercase(string: []const u8) bool {
    for (string) |c| {
        if (std.ascii.isAlphabetic(c)) {
            if (!std.ascii.isLower(c)) return false;
        }
    }
    return true;
}

const CaseType = enum {
    lowercase,
    uppercase,
    @"kebab-case",
    PascalCase,
    snake_case,
    camelCase,
    NotCamelCase,

    fn toStr(self: CaseType) []const u8 {
        return if (self == .NotCamelCase) "not camel case" else @tagName(self);
    }
};

fn getCase(string: []const u8) CaseType {
    const has_underline = hasUnderline(string);
    const has_uppercase_first_letter = hasUppercaseFirstLetter(string);
    const has_dashes = hasDashes(string);

    if (has_underline) {
        if (has_dashes) return .NotCamelCase;
        if (has_uppercase_first_letter and hasLower(string)) return .NotCamelCase; // SCREAMING_SNAKE_CASE
        return .snake_case;
    }
    if (has_uppercase_first_letter) {
        if (has_underline or has_dashes) return .NotCamelCase;
        if (hasLower(string)) return .PascalCase;
        return .uppercase;
    }
    if (has_dashes) {
        if (has_underline or has_uppercase_first_letter) return .NotCamelCase;
        return .@"kebab-case";
    }
    if (hasUpper(string)) return .camelCase;
    if (isLowercase(string)) return .lowercase;
    return .uppercase;
}

test getCase {
    // lower
    try expectEqual(.lowercase, getCase("foo"));
    try expectEqual(.lowercase, getCase("foo bar"));
    try expectEqual(.lowercase, getCase("foobar"));

    // camel
    try expectEqual(.camelCase, getCase("fooBar"));

    // pascal
    try expectEqual(.PascalCase, getCase("Foo"));

    // kebab
    try expectEqual(.@"kebab-case", getCase("foo-bar"));
    try expectEqual(.@"kebab-case", getCase("-foo"));
    try expectEqual(.@"kebab-case", getCase("-"));

    // snake
    try expectEqual(.snake_case, getCase("foo_bar"));
    try expectEqual(.snake_case, getCase("foo_bar"));
    try expectEqual(.snake_case, getCase("FOO_BAR"));
    try expectEqual(.snake_case, getCase("_"));

    // mixed
    try expectEqual(.NotCamelCase, getCase("foo-bar_baz"));
    try expectEqual(.NotCamelCase, getCase("FooBar_baz"));

    // edge cases
    try expectEqual(.lowercase, getCase(""));
    try expectEqual(.lowercase, getCase(" "));
}

pub fn runOnSymbol(_: *const CaseConvention, symbol: Symbol.Id, ctx: *LinterContext) void {
    // const nodes = ctx.ast().nodes;
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

    if (usesCCallconv(ctx, &func)) return;

    const fn_name: []const u8 = symbols.items(.name)[id];
    const case = getCase(fn_name);
    const returns_type = fnReturnsType(ctx, &func);
    if (returns_type) {
        const is_single_letter_generic = case == .uppercase and fn_name.len == 1;
        if (case != .PascalCase and !is_single_letter_generic) {
            ctx.report(genericsArePascaleCase(ctx, fn_name, func.name_token.?));
        }
    } else if (case != .camelCase and case != .lowercase) {
        const ast = ctx.ast();
        const fn_keyword_token_idx: Ast.TokenIndex = ast.nodeMainToken(decl);
        const name_token_idx = fn_keyword_token_idx + 1;
        ctx.report(functionNameDiagnostic(ctx, fn_name, case, name_token_idx));
    }
}

fn checkPayload(ctx: *LinterContext, symbol: Symbol.Id, symbols: std.MultiArrayList(Symbol).Slice) void {
    const id = symbol.into(usize);
    const name = symbols.items(.name)[id];
    const token = symbols.items(.token)[id].unwrap() orelse return;

    if (name.len == 0) {
        @branchHint(.cold);
        return;
    }

    // PascalCase and uppercase payloads capture types (`inline for (types) |T|`)
    const case = getCase(name);
    switch (case) {
        .snake_case, .lowercase, .PascalCase, .uppercase => return,
        else => ctx.report(caseConventionDiagnostic(ctx, name, token.int(), .payload, .snake_case, case)),
    }
}

/// `callconv(.c)` functions have names dictated by the C ABI.
fn usesCCallconv(ctx: *LinterContext, fn_proto: *const Ast.full.FnProto) bool {
    const expr = fn_proto.ast.callconv_expr.unwrap() orelse return false;
    const ast = ctx.ast();
    const token = switch (ast.nodeTag(expr)) {
        .enum_literal => ast.nodeMainToken(expr),
        .field_access => ast.nodeData(expr).node_and_token[1],
        else => return false,
    };
    const name = ctx.semantic.tokenSlice(token);
    return name.len == 1 and (name[0] == 'c' or name[0] == 'C');
}

fn fnReturnsType(ctx: *LinterContext, fn_proto: *const Ast.full.FnProto) bool {
    const return_type_node = fn_proto.ast.return_type.unwrap() orelse return false;
    const inner_return_node = ast_utils.getInnerType(ctx.ast(), return_type_node);
    const return_type = ast_utils.getRightmostIdentifier(ctx, inner_return_node) orelse
        return false;

    if (return_type.len == 0) {
        @branchHint(.cold);
        return false;
    }

    return std.mem.eql(u8, return_type, "type");
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
        // C ABI
        "export fn foo_bar() void {}",
        "export fn FooBar() void {}",
        "fn foo_bar() callconv(.c) void {}",
        "fn foo_bar() callconv(.C) void {}",
        "fn foo_bar() callconv(std.builtin.CallingConvention.c) void {}",
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
        // payloads
        "const x = bar() catch |fooBar| return fooBar;",
        "const x = bar() catch |@\"foo-bar\"| return @\"foo-bar\";",
        "fn foo_bar() callconv(.naked) void {}",
        "fn foo_bar() callconv(.@\"inline\") void {}",
        "fn f(opt: ?u32) void { if (opt) |fooBar| _ = fooBar; }",
        "fn f(opt: ?u32) void { while (opt) |fooBar| _ = fooBar; }",
        "fn f(xs: []u32) void { for (xs) |fooBar| _ = fooBar; }",
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}

test "todo: fix these getCase cases" {
    try expectEqual(.snake_case, getCase("fooBar_baz")); // expected .NotCamelCase
}
