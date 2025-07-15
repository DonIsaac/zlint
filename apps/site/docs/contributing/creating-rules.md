# Creating New Rules

This guide will walk you through creating a new lint rule. For the sake of
example, we'll be creating [`no-undefined`](https://github.com/DonIsaac/zlint/blob/main/src/linter/rules/no_undefined.zig).

:::info

Make sure you've followed the [setup guide](./index.mdx) first.

:::


## Generating Boilerplate

Start off by running `just new-rule <rule-name>` to generate boilerplate code.

```sh
just new-rule no-undefined
```

This will do the following:

1. Create a new rule, `NoUndefined`, in `src/linter/rules/no_undefined.zig` with
   method and test stubs.
2. Register `NoUndefined` to the list of all lint rules by re-exporting it in
   `src/linter/rules.zig`.

Open `no_undefined.zig`. It will look something like this.

```zig
// ... imports omitted

const NoUndefined = @This();
pub const Name = "no-undefined";

pub fn runOnNode(_: *const NoUndefined, wrapper: NodeWrapper, ctx: *LinterContext) void {
    @panic("TODO: Implement");
}

pub fn runOnSymbol(_: *const NoUndefined, symbol: Symbol.Id, ctx: *LinterContext) void {
    @panic("TODO: Implement");
}

pub fn rule(self: *NoUndefined) Rule {
    return Rule.init(self);
}

// ... tests omitted. We'll cover this later.
```

The `runOn*` methods provide different ways to check for and report violations.
The only difference between them is how they are called. Neither is better or
worse than the other: just more or less useful for your specific rule.

-   `runOnNode` is called for every node in the AST.
-   `runOnSymbol` is called for every symbol in the symbol table.

Pick the most convenient method for your rule and delete the other(s). Since
`NoUndefined` looks for identifiers named `undefined`, we'll use `runOnNode`.

## Using the AST

> [!NOTE]
> We highly recommend you familiarize yourself with Zig's AST and parser. We'll
> go over pieces here, but these resources should provide more details.
>
> -   [`std.zig.Ast` API docs](https://ziglang.org/documentation/master/std/#std.zig.Ast)
> -   [This blog post by Mitchell Hashimoto on Zig's parser](https://mitchellh.com/zig/parser#anatomy-of-an-ast-node)

`NodeWrapper` contains the current
[node](https://ziglang.org/documentation/master/std/#std.zig.Ast.Node) as well
as it's id. We can check the node's
[tag](https://ziglang.org/documentation/master/std/#std.zig.Ast.Node.Tag) to
determine what kind of node it is. In our case, we're looking for `.identifier`.

```zig
pub fn runOnNode(_: *const NoUndefined, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const node = wrapper.node;
    if (node.tag != .identifier) return;
    @panic("TODO: Implement");
}
```

Identifiers don't store their value directly. Instead, we need to look it up
from the source code using the identifier's span, which covers the start and end
byte offsets of the identifier and can be used to create a slice.

-   When you have a node (`Ast.Node.Index`), use `ast.getNodeSource(id)`
-   When you have a lexer token (`Ast.TokenIndex`), use `ast.tokenSlice(id)`

Since an identifier node is only a single token "wide", it doesn't matter which
we use in this case.

We can get the AST from the `LintContext` parameter. Besides the AST, it also
stores semantic information obtained from semantic analysis, methods for
reporting rule violations, and other kinds of helpers. It's really quite
important, so make sure you understand what it provides and how to use it.

```zig
pub fn runOnNode(_: *const NoUndefined, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const node = wrapper.node;
    const ast = ctx.ast();

    if (node.tag != .identifier) return;
    const identifier = ast.getNodeSource(node.id);
    if (!std.mem.eql(u8, identifier, "undefined")) return;

    @panic("TODO: Implement"); // TODO: report violations
}
```

## Reporting Violations

Lint rule violations, also called diagnostics, are reported using
`LintContext.diagnostic()`. It takes an error message and one or more ranges of
source code (i.e a `Span`) that cover problematic parts of code.

```zig
pub fn runOnNode(_: *const NoUndefined, wrapper: NodeWrapper, ctx: *LinterContext) void {
    const node = wrapper.node;
    const ast = ctx.ast();

    if (node.tag != .identifier) return;
    const identifier = ast.getNodeSource(node.id);
    if (!std.mem.eql(u8, identifier, "undefined")) return;

    @panic("TODO: Implement"); // TODO: report violations
    ctx.diagnostic(
        "Do not use undefined.",       // error message
        .{ctx.spanT(node.main_token)}, // covers the identifier lexer token.
    );
}
```

Important notes:

-   `diagnostic` has several other variants depending on how you want to create
    error messages. For example, to use a format string, use `diagnosticFmt`.
-   `spanT` creates a span from a lexer token, while `spanN` creates one from a
    node index. You can also create one directly and pass a `LabeledSpan` instance
    to `diagnostic`.

## Testing

When you ran `just new-rule`, a test stub was created at the bottom of your
file.

```zig
const RuleTester = @import("../tester.zig");
test ${StructName} {
    const t = std.testing;

    var no_undefined = NoUndefined{};
    var runner = RuleTester.init(t.allocator, no_undefined.rule());
    defer runner.deinit();

    const pass = &[_][:0]const u8{
        // TODO: add test cases
        "const x = 1",
    };

    const fail = &[_][:0]const u8{
        // TODO: add test cases
        "const x = 1",
    };

    try runner
        .withPass(pass)
        .withFail(fail)
        .run();
}
```

Fill in `pass` and `fail` with snippets of valid Zig source code. `RuleTester`
checks that `pass` cases produce no lint rule violations, and that `fail` cases
produce at least one violation. Additionally, snapshots of diagnostics produced
by `fail` cases will be saved to a snapshot file.

Fill these out, then run the tests.

```sh
just test
```

Make sure you stage and commit the generated snapshot file.
