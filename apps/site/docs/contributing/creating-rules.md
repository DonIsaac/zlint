# Creating New Rules

This guide walks through creating a lint rule. For an end-to-end example, see
[`unsafe-undefined`](https://github.com/DonIsaac/zlint/blob/main/src/linter/rules/unsafe_undefined.zig).

:::info

Make sure you've followed the [setup guide](./index.mdx) first.

:::

## Generating Boilerplate

Start by running `just new-rule <rule-name>` with a kebab-case rule name.

```sh
just new-rule unsafe-undefined
```

This creates `src/linter/rules/unsafe_undefined.zig`, re-exports the rule from
`src/linter/rules.zig`, and updates the generated rule configuration types.

The generated rule file includes module doc comments, metadata, three optional
hooks, and a `RuleTester` test stub:

```zig
const UnsafeUndefined = @This();
pub const meta: Rule.Meta = .{
    .name = "unsafe-undefined",
    .category = .correctness,
};

pub fn runOnce(_: *const UnsafeUndefined, ctx: *LinterContext) void {
    _ = ctx;
    @panic("TODO: implement runOnce, or remove it if not needed");
}

pub fn runOnNode(_: *const UnsafeUndefined, wrapper: NodeWrapper, ctx: *LinterContext) void {
    _ = wrapper;
    _ = ctx;
    @panic("TODO: implement runOnNode, or remove it if not needed");
}

pub fn runOnSymbol(_: *const UnsafeUndefined, symbol: Symbol.Id, ctx: *LinterContext) void {
    _ = symbol;
    _ = ctx;
    @panic("TODO: implement runOnSymbol, or remove it if not needed");
}

pub fn rule(self: *UnsafeUndefined) Rule {
    return Rule.init(self);
}
```

Keep the hooks your rule needs and delete the rest:

- `runOnce` runs once per source file.
- `runOnNode` runs for each AST node and is useful for syntax-based checks.
- `runOnSymbol` runs for each semantic symbol and is useful for reference or
  declaration checks.

## Writing User-Facing Docs

The module doc comments at the top of the rule file are user-facing. `just
codegen` turns them into `apps/site/docs/rules/<rule-name>.mdx`, so keep them
accurate and include examples that the implementation actually reports.

The rule metadata controls the generated banner:

```zig
pub const meta: Rule.Meta = .{
    .name = "unsafe-undefined",
    .category = .correctness,
    .default = .warning,
    .fix = Fix.Meta.safe_fix,
};
```

If the rule has options, add fields to the rule struct. The config generator
uses those fields to update `src/linter/config/rules_config_rules.zig` and
`zlint.schema.json`.

## Using the AST and Semantic Data

`NodeWrapper` contains the current AST node and its id. Use `ctx.ast()` and
`ctx.semantic` helpers to inspect source and semantic information.

```zig
pub fn runOnNode(_: *const UnsafeUndefined, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const node = wrapper.node;
    if (node.tag != .identifier) return;

    const name = ctx.semantic.tokenSlice(node.main_token);
    if (!std.mem.eql(u8, name, "undefined")) return;

    ctx.report(ctx.diagnostic(
        "Do not use undefined.",
        .{ctx.spanT(node.main_token)},
    ));
}
```

Common helpers include:

- `ctx.ast()` for the parsed AST.
- `ctx.semantic.tokenSlice(token)` for source text covered by a token.
- `ctx.spanT(token)` for token spans and `ctx.spanN(node)` for node spans.
- `ctx.links().getScope(node)` and `ctx.semantic.resolveBinding(...)` for
  scope-aware name lookup.

## Testing

Each rule should have focused `RuleTester` cases at the bottom of its file.

```zig
const RuleTester = @import("../tester.zig");
test UnsafeUndefined {
    const t = std.testing;

    var unsafe_undefined = UnsafeUndefined{};
    var runner = RuleTester.init(t.allocator, unsafe_undefined.rule());
    defer runner.deinit();

    const pass = &[_][:0]const u8{
        "const x = 1;",
    };

    const fail = &[_][:0]const u8{
        "var x: u32 = undefined;",
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
```

`RuleTester` checks that pass cases produce no diagnostics and fail cases
produce diagnostics. Snapshot output is written under
`src/linter/rules/snapshots/`.

Run the focused checks while developing:

```sh
just test
just codegen
```

Commit the rule implementation, generated config/schema/doc output, and any
new or updated snapshots.
