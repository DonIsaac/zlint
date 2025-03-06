# `empty-file`

> Category: style
>
> Enabled by default?: No

## What This Rule Does

This rule would check for empty .zig files in the project.
A file should be deemed empty if it has no content (zero bytes) or only whitespace characters.
as defined by the standard library in [`std.ascii.whitespace`](https://ziglang.org/documentation/master/std/#std.ascii.whitespace).

## Examples

Examples of **incorrect** code for this rule:

```zig

```

Examples of **correct** code for this rule:

```zig
fn exampleFunction() void {
}
```
