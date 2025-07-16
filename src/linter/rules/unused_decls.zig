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
//! :::warning
//!
//! ZLint's semantic analyzer does not yet record references to variables on
//! member access expressions (e.g. `bar` on `foo.bar`). It also does not
//! handle method calls correctly. Until these features are added, only
//! top-level `const` variable declarations are checked.
//!
//! :::
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
const Semantic = @import("../../Semantic.zig");
const _rule = @import("../rule.zig");
const _fix = @import("../fix.zig");
const _span = @import("../../span.zig");
const Error = @import("../../Error.zig");

const Span = _span.Span;
const Symbol = Semantic.Symbol;
const Scope = Semantic.Scope;
const Node = Semantic.Ast.Node;
const LinterContext = @import("../lint_context.zig");
const Fix = _fix.Fix;
const Rule = _rule.Rule;

const UnusedDecls = @This();
pub const meta: Rule.Meta = .{
    .name = "unused-decls",
    .default = .warning,
    .category = .correctness,
    .fix = Fix.Meta.dangerous_fix,
};

fn unusedDeclDiagnostic(ctx: *LinterContext, name: []const u8, span: _span.LabeledSpan) Error {
    return ctx.diagnosticf(
        "variable '{s}' is declared but never used.",
        .{name},
        .{span},
    );
}

pub fn runOnSymbol(_: *const UnusedDecls, symbol: Symbol.Id, ctx: *LinterContext) void {
    const s = symbol.into(usize);
    const symbols = ctx.symbols().symbols.slice();
    const references: []const Semantic.Reference.Id = symbols.items(.references)[s].items;
    // TODO: ignore write references
    // TODO: check for references by variables that are themselves unused. for
    // example, both `foo` and `bar` should be reported:
    //
    //     const foo = 1;
    //     const bar = foo;
    //
    if (references.len > 0) return;

    const visibility: Symbol.Visibility = symbols.items(.visibility)[s];
    if (visibility == .public) return;

    const flags: Symbol.Flags = symbols.items(.flags)[s];
    const name = symbols.items(.name)[s];

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
    const scope: Scope.Id = symbols.items(.scope)[s];
    if (!scope.eql(Semantic.ROOT_SCOPE_ID)) return;

    if (flags.s_variable and flags.s_const) {
        const span = ctx.spanT(symbols.items(.token)[s].unwrap().?.int());
        const fixer = UnusedDeclsFixer.init(ctx, symbol);
        ctx.reportWithFix(
            fixer,
            unusedDeclDiagnostic(ctx, name, span),
            &UnusedDeclsFixer.removeDecl,
        );
        return;
    }
}

const UnusedDeclsFixer = struct {
    span: Span,

    fn init(ctx: *const LinterContext, symbol: Symbol.Id) UnusedDeclsFixer {
        if (ctx.fix.isDisabled()) return .{ .span = Span.EMPTY };
        // NOTE: if we cover more kinds of symbols in the future, this may cover
        // something we don't want (e.g. decl node for fn params is the fn proto).
        // Fine for now since we only report top-level vars.
        const decl: Node.Index = ctx.symbols().symbols.items(.decl)[symbol.int()];
        var span = ctx.spanN(decl).span;
        const text = ctx.source.text();

        // if (span.end < text.len and text[span.end] == ';') span.end += 1;
        var needs_semicolon = true;
        while (span.end < text.len) {
            switch (text[span.end]) {
                ';' => if (needs_semicolon) {
                    needs_semicolon = false;
                    span.end += 1;
                } else break,
                ' ', '\t' => span.end += 1,
                '\n' => {
                    span.end += 1;
                    break;
                },
                '\r' => {
                    span.end += 1;
                    if (span.end < text.len and text[span.end] == '\n') {
                        span.end += 1;
                    }
                    break;
                },
                else => break,
            }
        }

        return .{ .span = span };
    }

    pub fn removeDecl(self: UnusedDeclsFixer, b: Fix.Builder) anyerror!Fix {
        return b.delete(self.span);
    }
};

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
        \\const Bar = @import("Foo.zig");
        \\pub const Thing = union(enum) {
        \\  Foo,
        \\  Bar: Bar, 
        \\};
        ,
        \\test "Thing" {
        \\  const Choices = enum { a, b };
        \\  var c: Choices = .a;
        \\  const x = switch (c) {
        \\    .a => 1,
        \\    .b => &thing,
        \\  };
        \\}
        \\const thing = struct {};
    };

    const fail = &[_][:0]const u8{
        "const x = 1;",
        \\const std = @import("std"); const Allocator = std.mem.Allocator;
        ,
        "extern const x: usize;",
    };

    const fix = &[_]RuleTester.FixCase{
        .{ .src = "const x = 1;", .expected = "" },
        .{ .src = "const std = @import(\"std\");", .expected = "" },
        .{ .src = "const x = struct {\na: u32,\n};", .expected = "" },
        .{
            .src =
            \\//! This module does a thing
            \\const std = @import("std");
            ,
            .expected =
            \\//! This module does a thing
            \\
            ,
        },
        .{
            .src =
            \\pub const used = 1;
            \\const unused = struct {
            \\  a: u32 = 1
            \\};
            ,
            .expected =
            \\pub const used = 1;
            \\
            ,
        },
        .{
            .src =
            \\const x = 1;
            \\const y = 2;
            \\pub const z = x + 1;
            ,
            .expected =
            \\const x = 1;
            \\pub const z = x + 1;
            ,
        },
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .withFix(fix)
        .run();
}
