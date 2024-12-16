# `suppressed-errors`

> Category: suspicious
>
> Enabled by default?: Yes (warning)

## What This Rule Does

Disallows `catch`ing and swallowing errors.

More specifically, this rule bans empty `catch` statements. As of now,
`catch`es that do nothing with the caught error, but do _something_ are not
considered violations.

## Examples

Examples of **incorrect** code for this rule:

```zig
const x = foo() catch {};
const x = foo() catch {
  // comments within empty catch blocks have no effect.
};
```

Examples of **correct** code for this rule:

```zig
const x = foo() catch @panic("foo failed.");
const x = foo() catch {
  std.debug.print("Foo failed.\n", .{});
};
```
