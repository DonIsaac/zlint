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
const _span = @import("../../span.zig");
const ast_utils = @import("../ast_utils.zig");

const zig = @import("../../zig.zig").@"0.14.1";
const Ast = zig.Ast;
const Node = Ast.Node;
const Symbol = Semantic.Symbol;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;

const Error = @import("../../Error.zig");

// Rule metadata
const CaseConvention = @This();
pub const meta: Rule.Meta = .{
    .name = "case-convention",
    .category = .style,
};

const CaseType = enum {
    @"kebab-case",
    PascalCase,
    snake_case,
    camelCase,
    NotCamelCase,
};

fn hasDashes(string: []const u8) bool {
    return std.mem.indexOfScalar(u8, string, '-') != null;
}

fn hasUppercaseFirstLetter(string: []const u8) bool {
    for (string) |c| {
        if (std.ascii.isAlphabetic(c)) {
            return std.ascii.isUpper(c);
        }
    }
    return false;
}

fn hasUnderline(string: []const u8) bool {
    return std.mem.indexOfScalar(u8, string, '_') != null;
}

fn getCase(string: []const u8) CaseType {
    const has_underline = hasUnderline(string);
    const has_uppercase_first_letter = hasUppercaseFirstLetter(string);
    const has_dashes = hasDashes(string);

    if (has_underline) {
        if (has_uppercase_first_letter or has_dashes) return .NotCamelCase;
        return .snake_case;
    }
    if (has_uppercase_first_letter) {
        if (has_underline or has_dashes) return .NotCamelCase;
        return .PascalCase;
    }
    if (has_dashes) {
        if (has_underline or has_uppercase_first_letter) return .NotCamelCase;
        return .@"kebab-case";
    }
    return .camelCase;
}

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

fn genericsArePascaleCase(ctx: *LinterContext, fn_name: []const u8, name: Ast.TokenIndex) Error {
    var d = ctx.diagnosticf(
        "Function '{s}' returns a type, but does not use PascalCase",
        .{fn_name},
        .{ctx.spanT(name)},
    );
    d.help = .static("By convention, Zig uses PascalCase for structs, generics, and all other type variables.");
    return d;
}

pub fn runOnSymbol(_: *const CaseConvention, symbol: Symbol.Id, ctx: *LinterContext) void {
    // const nodes = ctx.ast().nodes;
    const symbols = ctx.symbols().symbols.slice();
    const symbol_flags: []const Symbol.Flags = symbols.items(.flags);
    const id = symbol.into(usize);

    const flags = symbol_flags[id];
    if (!flags.s_fn or flags.s_extern) return;

    const decl: Node.Index = symbols.items(.decl)[id];
    // if (tag != .fn_decl and tag != .fn_proto) return; // could be .fn_proto for e.g. fn types
    var buf: [1]Node.Index = undefined;
    const func = ctx.ast().fullFnProto(&buf, decl) orelse {
        util.debugAssert(false, "Symbol flagged as a function does not correspond to an fn-like node", .{});
        return;
    };

    const fn_name: []const u8 = symbols.items(.name)[id];
    const case = getCase(fn_name);
    const returns_type = fnReturnsType(ctx, &func);
    if (returns_type) {
        if (case != .PascalCase) {
            ctx.report(genericsArePascaleCase(ctx, fn_name, func.name_token.?));
        }
    } else {
        if (case != .camelCase) {
            const ast = ctx.ast();
            const fn_keyword_token_idx: Ast.TokenIndex = ast.nodes.items(.main_token)[id];
            const name_token_idx = fn_keyword_token_idx + 1;
            ctx.report(functionNameDiagnostic(ctx, fn_name, case, name_token_idx));
        }
    }
}

fn fnReturnsType(ctx: *LinterContext, fn_proto: *const Ast.full.FnProto) bool {
    const return_type = ast_utils.getRightmostIdentifier(
        ctx,
        ast_utils.getInnerType(ctx.ast(), fn_proto.ast.return_type),
    ) orelse {
        return false;
    };
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
        "fn alllowercasefunctionsarealwaysgreen() void {}",
        "fn thisFunctionIsInCamelCase() void {}",
        "fn Generic(T: type) type { return *T; }",
        "fn FooBar() type { return u32; }",
        "extern fn this_is_declared_in_c() void;",
    };

    const fail = &[_][:0]const u8{
        "fn ThisFunctionIsInPascalCase() void {}",
        "fn @\"this-one-is-in-kebab-case\"() void {}",
        "fn this_one_is_in_snake_case() void {}",
        "fn @\"This-is-both-Pascal-and-Kebab-kinda\"() void {}",
        "fn This_is_both_snake_case_and_pascal_kinda() void {}",
        "fn This_is_both_snake_case_and_pascal_kinda(a: u32, b: u32, c: u32, d: u32) void {}",
        "fn fooBar() type { return u32; }",
        "fn NotGeneric(T: type) T { return T{}; }",
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
