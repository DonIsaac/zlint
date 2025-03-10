//! ## What This Rule Does
//! Explain what this rule checks for. Also explain why this is a problem.
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! ```

const std = @import("std");
const util = @import("util");
const _source = @import("../../source.zig");
const semantic = @import("../../semantic.zig");
const _rule = @import("../rule.zig");
const _span = @import("../../span.zig");

const Ast = std.zig.Ast;
const Node = Ast.Node;
const Symbol = semantic.Symbol;
const Loc = std.zig.Loc;
const Span = _span.Span;
const LabeledSpan = _span.LabeledSpan;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const NodeWrapper = _rule.NodeWrapper;

const Error = @import("../../Error.zig");
const Cow = util.Cow(false);

// Rule metadata
const KebabCaseFn = @This();
pub const meta: Rule.Meta = .{
    .name = "kebab-case-fn",
    // TODO: set the category to an appropriate value
    .category = .style,
};

fn isKebabCase(string: []const u8) bool {}

fn isSnakeCase(string: []const u8) bool {}

fn isPascalCase(string: []const u8) bool {}

pub fn runOnSymbol(_: *const KebabCaseFn, symbol: Symbol.Id, ctx: *LinterContext) void {
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
    if (tag != .fn_decl) return; // could be .fn_proto for e.g. fn types

    const fn_name = symbols.items(.name)[id];
}

// Used by the Linter to register the rule so it can be run.
pub fn rule(self: *KebabCaseFn) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test KebabCaseFn {
    const t = std.testing;

    var kebab_case_fn = KebabCaseFn{};
    var runner = RuleTester.init(t.allocator, kebab_case_fn.rule());
    defer runner.deinit();

    // Code your rule should pass on
    const pass = &[_][:0]const u8{
        // TODO: add test cases
        "const x = 1;",
    };

    // Code your rule should fail on
    const fail = &[_][:0]const u8{
        // TODO: add test cases
        "const x = 1;",
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
