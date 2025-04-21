//! ## What This Rule Does
//! Checks for function names that are not in camel case. Specially coming from Rust,
//! some people may be used to use snake_case for their functions, which can lead to
//! inconsistencies in the code
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! fn this_one_is_in_snake_case() void {}
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! fn thisFunctionIsInCamelCase() void {}
//! ```

const std = @import("std");
const semantic = @import("../../semantic.zig");
const _rule = @import("../rule.zig");
const _span = @import("../../span.zig");

const Ast = std.zig.Ast;
const Node = Ast.Node;
const Span = _span.Span;
const Symbol = semantic.Symbol;
const LabeledSpan = _span.LabeledSpan;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;

const Error = @import("../../Error.zig");

// Rule metadata
const CamelCaseFn = @This();
pub const meta: Rule.Meta = .{
    .name = "camel-case-fn",
    // TODO: set the category to an appropriate value
    .category = .style,
};

const CaseType = enum { @"kebab-case", PascalCase, snake_case, camelCase, NotCamelCase };

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

pub fn functionNameDiagnostic(ctx: *LinterContext, fn_name: []const u8, case: CaseType, span: Span) Error {
    if (case == .NotCamelCase) {
        return ctx.diagnosticf("Function {s} name is not in camelCase", .{fn_name}, .{LabeledSpan{ .span = span }});
    }
    return ctx.diagnosticf("Function {s} name is in {s}. It should be camelCase", .{ fn_name, @tagName(case) }, .{LabeledSpan{ .span = span }});
}

pub fn runOnSymbol(_: *const CamelCaseFn, symbol: Symbol.Id, ctx: *LinterContext) void {
    const nodes = ctx.ast().nodes;
    const symbols = ctx.symbols().symbols.slice();
    const symbol_flags: []const Symbol.Flags = symbols.items(.flags);
    const id = symbol.into(usize);

    // 1. look for function declarations

    const flags = symbol_flags[symbol.into(usize)];
    if (!flags.s_fn) return;

    const tags: []const Node.Tag = nodes.items(.tag);
    const decl: Node.Index = symbols.items(.decl)[id];
    const tag: Node.Tag = tags[decl];
    if (tag != .fn_decl and tag != .fn_proto) return; // could be .fn_proto for e.g. fn types

    const fn_name = symbols.items(.name)[id];
    const case = getCase(fn_name);
    if (case != .camelCase) {
        const ast = ctx.ast();
        const span = ast.nodeToSpan(decl);
        ctx.report(functionNameDiagnostic(ctx, fn_name, case, .{ .start = span.start, .end = span.end }));
    }
}

// Used by the Linter to register the rule so it can be run.
pub fn rule(self: *CamelCaseFn) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test CamelCaseFn {
    const t = std.testing;

    var camel_case_fn = CamelCaseFn{};
    var runner = RuleTester.init(t.allocator, camel_case_fn.rule());
    defer runner.deinit();

    // Code your rule should pass on
    const pass = &[_][:0]const u8{
        // TODO: add test cases
        "fn alllowercasefunctionsarealwaysgreen() void {}",
        "fn thisFunctionIsInCamelCase() void {}",
    };

    // Code your rule should fail on
    const fail = &[_][:0]const u8{
        // TODO: add test cases
        "fn ThisFunctionIsInPascalCase() void {}",
        "fn @\"this-one-is-in-kebab-case\"() void {}",
        "fn this_one_is_in_snake_case() void {}",
        "fn @\"This-is-both-Pascal-and-Kebab-kinda\"() void {}",
        "fn This_is_both_snake_case_and_pascal_kinda() void {}",
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
