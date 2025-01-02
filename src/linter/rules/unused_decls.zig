//! ## What This Rule Does
//!
//! Disallows container-scoped variables that are declared but never used. Note
//! that top-level declarations are included.
//!
//! The Zig compiler checks for unused parameters, payloads bound by `if`,
//! `catch`, etc, and `const`/`var` declaration within functions. However,
//! variables and functions declared in container scopes are not given the same
//! treatment. This rule handles those cases.
//!
//! > [!WARNING]
//! > ZLint's semantic analyzer does not yet record references to variables on
//! > member access expressions (e.g. `bar` on `foo.bar`). It also does not
//! > handle method calls correctly. Until these features are added, only
//! > top-level `const` variable declarations are checked.
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! // `std` used, but `Allocator` is not.
//! const std = @import("std");
//! const Allocator = std.mem.Allocator;
//!
//! // Variables available to other code, either via `export` or `pub`, are not
//! // reported.
//! pub const x = 1;
//! export fn foo(x: u32) void {}
//!
//! // `extern` functions are not reported
//! extern fn bar(a: i32) void;
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! // Discarded variables are considered "used".
//! const x = 1;
//! _ = x;
//!
//! // non-container scoped variables are allowed by this rule but banned by the
//! // compiler. `x`, `y`, and `z` are ignored by this rule.
//! pub fn foo(x: u32) void {
//!   const y = true;
//!   var z: u32 = 1;
//! }
//! ```

const std = @import("std");
const _source = @import("../../source.zig");
const semantic = @import("../../semantic.zig");
const _rule = @import("../rule.zig");

const Ast = std.zig.Ast;
const Node = Ast.Node;
const Symbol = semantic.Symbol;
const Scope = semantic.Scope;
const Loc = std.zig.Loc;
const Span = _source.Span;
const LinterContext = @import("../lint_context.zig");
const Rule = _rule.Rule;
const NodeWrapper = _rule.NodeWrapper;

// Rule metadata
const UnusedDecls = @This();
pub const meta: Rule.Meta = .{
    .name = "unused-decls",
    .default = .warning,
    // TODO: set the category to an appropriate value
    .category = .correctness,
};

pub fn runOnSymbol(_: *const UnusedDecls, symbol: Symbol.Id, ctx: *LinterContext) void {
    const s = symbol.into(usize);
    const slice = ctx.symbols().symbols.slice();
    const references: []const semantic.Reference.Id = slice.items(.references)[s].items;
    // TODO: ignore write references
    // TODO: check for references by variables that are themselves unused. for
    // example, both `foo` and `bar` should be reported:
    //
    //     const foo = 1;
    //     const bar = foo;
    //
    if (references.len > 0) return;

    const visibility: Symbol.Visibility = slice.items(.visibility)[s];
    if (visibility == .public) return;

    const flags: Symbol.Flags = slice.items(.flags)[s];
    const name = slice.items(.name)[s];

    // TODO:
    //  1) member references (`foo.bar`) are not currently resolved
    //  2) correctly resolve method syntax (`foo.bar()` -> `fn bar(self: *Foo) void`)
    // if (flags.s_fn and !flags.s_export and !flags.s_extern) {
    //     _ = ctx.diagnosticFmt(
    //         "Function '{s}' is declared but never used.",
    //         .{name},
    //         .{ctx.spanT(slice.items(.token)[s].unwrap().?.int())},
    //     );
    //     return;
    // }

    // TODO: since references on container members are not yet recorded, there
    // are too many false positives for non-root constants. Once such references
    // are reliably resolved, remove this check.
    const scope: Scope.Id = slice.items(.scope)[s];
    if (!scope.eql(semantic.Semantic.ROOT_SCOPE_ID)) return;

    if (flags.s_variable and flags.s_const) {
        ctx.report(ctx.diagnosticf(
            "variable '{s}' is declared but never used.",
            .{name},
            .{ctx.spanT(slice.items(.token)[s].unwrap().?.int())},
        ));
        return;
    }
}

// Used by the Linter to register the rule so it can be run.
pub fn rule(self: *UnusedDecls) Rule {
    return Rule.init(self);
}

const RuleTester = @import("../tester.zig");
test UnusedDecls {
    const t = std.testing;

    var unused_decls = UnusedDecls{};
    var runner = RuleTester.init(t.allocator, unused_decls.rule());
    defer runner.deinit();

    const pass = &[_][:0]const u8{
        \\const x = 1;
        \\fn foo() void {
        \\  bar(x);
        \\}
        ,
        "const x = 1; _ = { _ = x; }",
        "pub const x = 1;",
        "pub fn foo() void {}",
        "extern fn foo() void;",
        "export fn foo() void {}",
        \\const module = @import("module.zig");
        \\usingnamespace module;
        ,
    };

    // Code your rule should fail on
    const fail = &[_][:0]const u8{
        // TODO: add test cases
        "const x = 1;",
        \\const std = @import("std"); const Allocator = std.mem.Allocator;
        ,
        "extern const x: usize;",
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
