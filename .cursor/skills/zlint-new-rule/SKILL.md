---
name: zlint-new-rule
description: Author a new zlint lint rule end-to-end - scaffold the rule file, implement the runOnNode/runOnSymbol/runOnce hooks, write RuleTester pass/fail/fix cases with snapshot output, and regenerate docs and schema. Use when adding a lint rule, implementing a rule listed on the rule ideas board, renaming or recategorizing an existing rule, or when the user mentions creating, adding, or scaffolding a rule in this repo.
---

# Authoring a zlint Lint Rule

Use this skill when adding or modifying a lint rule in `src/linter/rules/`.
Rules plug into a code-generated config + docs pipeline, so step order matters.

**Two principles run through every step:**

1. **Collaborate with the user.** Confirm intent and examples before scaffolding.
   Re-check whenever a new ambiguity appears. Don't guess semantics.
2. **Crib from a neighbor.** `src/linter/rules/` is the source of truth for what
   rule code looks like here. Pick 1-2 structurally similar rules and keep them
   open while you work.

Skipping either is the #1 cause of rework.

## Workflow

```
- [ ] 1. Clarify intent with the user (name, examples, severity)
- [ ] 2. Pick 1-2 reference rules and read them
- [ ] 3. Draft the doc-comment; confirm with user
- [ ] 4. `just new-rule <kebab-name>`
- [ ] 5. Fill in Rule.Meta + doc-comment; implement only the hooks you need
- [ ] 6. Write pass/fail tests; `just test` generates the snapshot
- [ ] 7. (Optional) Autofix + FixCase tests
- [ ] 8. `just codegen` && `just fmt` && `just ready`
```

## Step 1: Clarify intent

Minimum confirmation before scaffolding:

- **Rule name** (kebab-case). Check `src/linter/rules.zig` for collisions. If
  there's an established linter convention (ESLint, Clippy, oxc), adopt it
  unless the user wants divergence.
- **At least 2 incorrect + 2 correct code examples.** Real Zig, not
  hypotheticals. The correct examples that _look like_ the incorrect ones are
  where the subtlety lives — ask for those specifically.
- **Default severity:** `.off`, `.warning`, or `.err`. `.off` unless
  high-confidence.

Ask deeper questions only when the rule has real ambiguity:

- Carve-outs? (test files, `comptime` blocks, `extern` decls)
- Config options? (e.g. `allow_tests: bool`)
- Autofix? Safe or dangerous?

**Restate the rule back to the user and get agreement before scaffolding.**

## Step 2: Read existing rules first

Mandatory, not optional. Pick a reference by shape:

| Rule shape | Reference |
| --- | --- |
| Detect a specific call (identifier or `std.x.y`) | `no_print.zig` |
| Compare two AST subtrees structurally | `duplicate_case.zig` |
| Has config options + type/name whitelisting | `unsafe_undefined.zig` |
| Operates on declared symbols | `unused_decls.zig` |
| Checks source text, not AST | `line_length.zig` |
| Flags a `fn` signature pattern | `allocator_first_param.zig`, `must_return_ref.zig` |
| Provides an autofix | `useless_error_return.zig` |
| Fires once per file | `empty_file.zig` |

From each reference, extract: the `Rule.Meta` block, doc-comment structure,
which hook it uses, which `LinterContext` helpers it calls, and the shape of
its `RuleTester` tests. Also glance at its `snapshots/<name>.snap`.

**State which rules you're modeling after** before writing code, e.g. "I'll
follow `no_print.zig` for call detection and `unsafe_undefined.zig` for the
config field." That gives the user a chance to redirect.

## Step 3: Draft the doc-comment first

Write `//! ## What This Rule Does` as prose, using the confirmed examples.
**Show this to the user and get approval before writing Zig.** The doc-comment
pins down semantics; implementation then follows mechanically. It also becomes
`docs/rules/<name>.md` via codegen, so it's user-facing. Users will correct
prose faster than Zig.

Format in Step 5.

## Step 4: Scaffold

Rule names are **kebab-case** (`returned-stack-reference`). The scaffolder
derives the filename (`returned_stack_reference.zig`), struct name
(`ReturnedStackReference`), and camelCase helper automatically.

```sh
just new-rule returned-stack-reference
```

This does three things — do not redo them by hand:

1. Creates `src/linter/rules/<name>.zig` from a template.
2. Appends a re-export to `src/linter/rules.zig`.
3. Inserts a `RuleConfig` field into `src/linter/config/rules_config.zig`.

It also runs `just codegen` and formats `src/linter` once. If you later change
`meta.name` or `meta.category`, rerun `just codegen` manually.

**Do not hand-edit** `src/linter/config/rules_config_rules.zig`,
`zlint.schema.json`, `docs/rules/*.md`, or `*.snap` files — all generated.

## Step 5: Fill in `Rule.Meta` and the doc-comment

Every rule needs `pub const meta: Rule.Meta`:

| Field | Type | Notes |
| --- | --- | --- |
| `name` | kebab-case string | Must match the `just new-rule` argument |
| `category` | `Rule.Category` | See table below |
| `default` | `Severity` | `.off` (default), `.warning`, or `.err` |
| `fix` | `Fix.Meta` | Defaults to `Fix.Meta.disabled`. Set only for autofix rules |

Pick the most specific category:

| Category | When |
| --- | --- |
| `compiler` | Re-implements a check the Zig compiler already does |
| `correctness` | Code is almost certainly wrong |
| `suspicious` | Likely a mistake but has legitimate uses |
| `restriction` | Stylistic or policy restriction users opt into |
| `pedantic` | Strict best-practice enforcement |
| `style` | Formatting / naming |
| `nursery` | Experimental; not yet stable |

**Size cap:** `Rule.MAX_SIZE = 32` bytes of rule state. Config fields
deserialize into the rule struct, so keep them small (`bool`, `u32`, small
enums, `[]const []const u8`).

```zig
pub const meta: Rule.Meta = .{
    .name = "returned-stack-reference",
    .category = .correctness,
    .default = .warning,
};
```

**Doc-comment structure** (codegens to `docs/rules/<name>.md` — the headings
are load-bearing):

```zig
//! ## What This Rule Does
//! One paragraph. *What* is checked and *why* it matters.
//!
//! ### Optional subsection
//! Use H3 for config options, edge cases, or "Allowed scenarios".
//!
//! ## Examples
//!
//! Examples of **incorrect** code for this rule:
//! ```zig
//! // triggers the rule
//! ```
//!
//! Examples of **correct** code for this rule:
//! ```zig
//! // does not trigger the rule
//! ```
```

Docusaurus-style admonitions (`:::info`, `:::warning`) are supported — see
`unsafe_undefined.zig`. Document config options with a JSON block:

````markdown
//! ```json
//! {
//!   "rules": {
//!     "returned-stack-reference": ["warn", { "allow_tests": false }]
//!   }
//! }
//! ```
````

## Step 6: Implement the hooks

**Keep the reference rule open.** Crib the `switch (node.tag)` prelude, the
early-exit shape, and the exact `ctx.diagnostic(...)` / `ctx.report` wiring.
Don't reinvent patterns that exist next door.

Rules are duck-typed. **Delete any hook you don't use** — the scaffolder's
stubs `@panic("TODO:")` at runtime.

| Hook | Signature (as implemented; vtable allows `anyerror!void`) | When |
| --- | --- | --- |
| `runOnce` | `fn(*const Self, *LinterContext) void` | File-level checks |
| `runOnNode` | `fn(*const Self, NodeWrapper, *LinterContext) void` | AST-driven (most common) |
| `runOnSymbol` | `fn(*const Self, Symbol.Id, *LinterContext) void` | Symbol-table rules |

Also required:

```zig
pub fn rule(self: *Self) Rule {
    return Rule.init(self);
}
```

### Useful `LinterContext` helpers

- `ctx.ast()`, `ctx.semantic`, `ctx.source` (`.text()`, `.pathname`)
- `ctx.links().getScope(node_idx)` — node → scope
- `ctx.semantic.resolveBinding(scope, name, .{ .exclude = ... })` — scoped lookup
- `ctx.semantic.tokenSpan(tok)` / `ctx.semantic.nodeSpan(node)` — spans
- `ctx.diagnostic(msg, .{labels})` / `ctx.diagnosticf(fmt, args, .{labels})`
- `ctx.labelN(node, fmt, args)` / `ctx.labelT(tok, fmt, args)` — labeled spans
- `ctx.spanN(node)` / `ctx.spanT(tok)` — unlabeled
- `ctx.report(diagnostic)` — emit

### Typical `runOnNode` shape

```zig
pub fn runOnNode(self: *const ReturnedStackReference, wrapper: NodeWrapper, ctx: *LinterContext) void {
    switch (wrapper.node.tag) {
        .fn_decl, .fn_proto => {},
        else => return,
    }
    // ...analysis...
    var d = ctx.diagnostic(
        "Returning a reference to stack memory",
        .{ctx.labelN(wrapper.idx, "this escapes the current frame", .{})},
    );
    d.help = .static("Allocate on the heap or return by value.");
    ctx.report(d);
}
```

### When stuck

In order:

1. **Grep `src/linter/rules/`** for the construct. Someone has walked that
   tree. Looking at a function signature? Search for `.fn_decl` / `.fn_proto`.
2. **Check `src/linter/ast_utils.zig`** for shared helpers (`isInTest`,
   `getRightmostIdentifier`, etc.).
3. **Check `src/Semantic.zig` and `src/Semantic/`** for symbol/scope APIs.
4. **Then** ask the user — show them the AST construct you're matching and
   what you tried. Don't reach for `@hasField` / `@hasDecl` / reflection; that
   means you're off the beaten path.

## Step 7: Tests

Tests live at the bottom of the rule file using `RuleTester`. Pass cases lint
cleanly; fail cases must produce at least one diagnostic. Diagnostic output is
written to `src/linter/rules/snapshots/<name>.snap` on first run and diffed
afterward.

**Start with the user's examples from Step 1.** Each incorrect example → a
`fail` case; each correct example → a `pass` case. Then add 2-3 more per side
for edge coverage (see `no_print.zig` for how it covers `std.debug.print`, the
aliased `debug.print`, and a locally-defined `print`).

```zig
const RuleTester = @import("../tester.zig");
test ReturnedStackReference {
    const t = std.testing;
    var r = ReturnedStackReference{};
    var runner = RuleTester.init(t.allocator, r.rule());
    defer runner.deinit();

    const pass = &[_][:0]const u8{
        \\fn foo() u32 { return 1; }
        ,
    };
    const fail = &[_][:0]const u8{
        \\fn foo() *u32 {
        \\  var x: u32 = 1;
        \\  return &x;
        \\}
        ,
    };

    try runner.withPass(pass).withFail(fail).run();
}
```

Run with `just test`. First run writes the `.snap`. **Inspect it and show it
to the user** — compare against a neighbor like `snapshots/no-print.snap` for
tone. Ask whether the diagnostic message, help text, and highlighted spans
match intent. This is the last cheap catch for semantic drift. Commit the
`.snap` once approved. **Never hand-edit `.snap`** — delete and regenerate.

Tips:

- Multiline literals (`\\...`) for snippets.
- Snippets must parse at top level; wrap loose statements in `fn foo() void { ... }`.
- Keep snippets minimal — the snapshot is part of the test signal.
- Add a `pass` case for every carve-out (e.g. "allowed in tests").

## Step 8: Autofixes (optional)

Skip unless the user confirmed a fix in Step 1. Read
`useless_error_return.zig` first.

1. Set `fix` in `Rule.Meta`:
   ```zig
   .fix = Fix.Meta.safe_fix, // or .dangerous_fix
   ```
2. Attach a `Fix` when reporting:
   ```zig
   var d = ctx.diagnostic("...", .{...});
   d.fix = .{ .span = span, .replacement = Cow.static("replacement text") };
   ctx.report(d);
   ```
3. Add `FixCase` entries:
   ```zig
   const fixes = &[_]RuleTester.FixCase{
       .{ .src = "const x = 1;", .expected = "const y = 2;" },
   };
   try runner.withPass(pass).withFail(fail).withFix(fixes).run();
   ```

The tester applies fixes, asserts no unfixed diagnostics remain, and compares
output to `.expected` verbatim.

## Step 9: Regenerate and verify

```sh
just codegen    # docs/rules/*.md, zlint.schema.json, rules_config_rules.zig
just fmt        # zig fmt + typos
just ready      # full pre-PR sweep (check + codegen + build + test + e2e)
```

`just ready` ends with `git status` — the working tree must be clean. Any
uncommitted generated output means codegen was skipped or stale.

## Mandatory check-ins

Not polite suggestions:

- After Step 1, before scaffolding: restate the rule + examples.
- After Step 3, before any Zig: get doc-comment approval.
- After the first `.snap`: show diagnostic text and spans.
- Mid-implementation ambiguity ("should this flag X?"): stop and ask.
- Before `just ready`: summarize what you built vs. the original intent.

A rule built from a confirmed contract finishes in one review cycle. One built
from assumptions routinely needs 2-3.

## Common mistakes

- **Skipping Steps 1-3.** Incorrect assumptions surface as production false
  positives.
- **Writing from scratch without opening a neighbor.** Deviating from repo
  conventions is a review finding.
- **Underscores in `meta.name`.** Rule names are kebab-case; only filenames use
  underscores.
- **Forgetting `just codegen`.** CI's `Docs + JSON Schema` job fails on
  `git diff --exit-code`.
- **Editing `docs/rules/<name>.md` by hand.** It gets overwritten.
- **Leaving `@panic("TODO:")` stubs.** Delete hooks you don't use.
- **Hand-editing `.snap` files.** Delete and regenerate.
- **`std.debug.print` inside the rule.** `no-print` will flag it. Use
  `std.log`.
- **Exceeding `Rule.MAX_SIZE` (32 bytes).** Compile error. Shrink fields or
  move to referenced constants.
- **Requiring type information.** zlint has no type checker. Limit analysis to
  AST + symbols/scopes; document the limitation (see `unsafe-undefined`).

## Quick reference

| Task | Command |
| --- | --- |
| Scaffold | `just new-rule <kebab-name>` |
| Unit tests | `just test` (all tests; no single-rule filter) |
| Regenerate docs + schema | `just codegen` |
| Format | `just fmt` |
| Pre-PR sweep | `just ready` |
| Simple AST rule | `src/linter/rules/no_print.zig` |
| AST comparison | `src/linter/rules/duplicate_case.zig` |
| Rule with config | `src/linter/rules/unsafe_undefined.zig` |
| Symbol-based | `src/linter/rules/unused_decls.zig` |
| Source-text check | `src/linter/rules/line_length.zig` |
| Fn signature check | `src/linter/rules/allocator_first_param.zig` |
| Autofix | `src/linter/rules/useless_error_return.zig` |
| File-level | `src/linter/rules/empty_file.zig` |
| Shared AST helpers | `src/linter/ast_utils.zig` |
| Symbol / scope APIs | `src/Semantic.zig`, `src/Semantic/` |
