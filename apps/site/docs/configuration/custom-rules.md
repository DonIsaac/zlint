---
id: custom-rules
title: Custom Rules
---

# Custom rules

If using the zig build system to integrate with zlint,
zlint supports user-provided rules written in zig.

## Installing zlint as a zig build system dependency

1. Depend on zlint `zig fetch --save=zlint git+https://github.com/DonIsaac/zlint/#main`
2. Import zlint's build module into your `build.zig` and add a "run lint" build step:
   ```zig
   const zlint = @import("zlint");
   const lint_step = b.step("lint", "run zlint");
   const zlint_dep = b.dependency("zlint", .{
       // optional custom rules
       .custom_rules = &[_]std.Build.LazyPath{
           b.path("./src/your_custom_rule.zig"),
       },
   });
   const run_lint = zlint.addRunLint(b, zlint_dep);
   lint_step.dependOn(&run_lint.step);
   ```

## Using custom rules

Custom rules are specified as a zig build option, `-Dcustom_rules`, so you need to
list the local paths to each rule in your `build.zig` when defining the
`zlint` dependency, as shown in the above text snippet.

## Testing

You can add a "custom lint rules test" build step with:

```zig
const zlint = @import("zlint");
// or just reuse your top level test step
const test_lint_step = b.step("test-lint-rules", "run tests for my custom rules");
const zlint_dep = b.dependency("zlint", .{
    .custom_rules = &[_]std.Build.LazyPath{
        b.path("./src/your_custom_rule.zig"),
    },
});
test_lint_step.dependOn(zlint.addRunCustomLintRulesTest(b, zlint_dep));
```

`addRunCustomLintRulesTest` returns a `*Build.Step` to depend on, rather than a
single `*Build.Step.Compile`. Zig only collects `test` declarations from the
root module of a compilation, and each custom rule is compiled as its own
module, so there is one test binary per rule.

This will run tests for custom rules, just as described in
the builtin rule [creation guide](../contributing/creating-rules.md#testing).

## Custom rule API

Custom rules are compiled as their own module, so they can't reach zlint's
internals by relative path the way builtin rules do. Everything a rule needs is
re-exported from `@import("zlint").linter` instead:

| Import                      | Contents                                               |
| --------------------------- | ------------------------------------------------------ |
| `zlint.linter.rule`         | `Rule`, `Rule.Meta`, `Rule.Category`, `NodeWrapper`    |
| `zlint.linter.lint_context` | `LinterContext`, the `ctx` passed to every rule method |
| `zlint.linter.span`         | `Span`, `LabeledSpan`                                  |
| `zlint.linter.Error`        | Diagnostic type returned by `ctx.diagnostic`           |
| `zlint.linter.ast_utils`    | AST helpers, e.g. `isInTest`, `getRightmostIdentifier` |
| `zlint.linter.tester`       | `RuleTester` for unit-testing a rule                   |
| `zlint.Semantic`            | `Ast`, `Symbol`, scopes, symbols, and references       |

Aside from these imports, a custom rule is written exactly like a builtin one.
For how to inspect nodes and report problems, see
[Using the AST](../contributing/creating-rules.md#using-the-ast) and
[Reporting Violations](../contributing/creating-rules.md#reporting-violations)
in the Creating New Rules guide — substituting the imports above for the
relative ones it uses.

### Example

A complete rule that reports every `unreachable`:

```zig
//! ## What This Rule Does
//! Disallows `unreachable`.

const zlint = @import("zlint");
const Rule = zlint.linter.rule.Rule;
const NodeWrapper = zlint.linter.rule.NodeWrapper;
const LinterContext = zlint.linter.lint_context;

pub const meta: Rule.Meta = .{
    .name = "no-unreachable",
    .category = .restriction,
    .default = .warning,
};

const NoUnreachable = @This();

/// Configurable from `zlint.json`: `["warn", { "allow_tests": false }]`
allow_tests: bool = true,

pub fn runOnNode(self: *const NoUnreachable, wrapper: NodeWrapper, ctx: *LinterContext) void {
    if (wrapper.node.tag != .unreachable_literal) return;
    if (self.allow_tests and zlint.linter.ast_utils.isInTest(ctx, wrapper.idx)) return;

    ctx.report(ctx.diagnostic(
        "`unreachable` is not allowed.",
        .{ctx.spanT(wrapper.node.main_token)},
    ));
}

pub fn rule(self: *NoUnreachable) Rule {
    return Rule.init(self);
}
```

Point `-Dcustom_rules` at that file and it behaves like any builtin rule: on by
default at `warning`, configurable in `zlint.json` under `"no-unreachable"`, and
suppressible per-file with a `// zlint-disable no-unreachable` comment.

## Limitations

Custom rules do not yet support full dependencies.
If you need that, please [raise an issue](https://github.com/DonIsaac/zlint/issues/new/choose).
