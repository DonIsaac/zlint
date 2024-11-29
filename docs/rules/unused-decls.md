# `unused-decls`

> Category: correctness
>
> Enabled by default?: Yes (warning)

## What This Rule Does

Disallows container-scoped variables that are declared but never used. Note
that top-level declarations are included.

The Zig compiler checks for unused parameters, payloads bound by `if`,
`catch`, etc, and `const`/`var` declaration within functions. However,
variables and functions declared in container scopes are not given the same
treatment. This rule handles those cases.

> [!WARNING]
> ZLint's semantic analyzer does not yet record references to variables on
> member access expressions (e.g. `bar` on `foo.bar`). It also does not
> handle method calls correctly. Until these features are added, only
> top-level `const` variable declarations are checked.

## Examples

Examples of **incorrect** code for this rule:

```zig
// `std` used, but `Allocator` is not.
const std = @import("std");
const Allocator = std.mem.Allocator;

// Variables available to other code, either via `export` or `pub`, are not
// reported.
pub const x = 1;
export fn foo(x: u32) void {}

// `extern` functions are not reported
extern fn bar(a: i32) void;
```

Examples of **correct** code for this rule:

```zig
// Discarded variables are not checked.
const x = 1;
_ = x;

// non-container scoped variables are allowed by this rule but banned by the
// compiler. `x`, `y`, and `z` are ignored by this rule.
pub fn foo(x: u32) void {
  const y = true;
  var z: u32 = 1;
}
```
