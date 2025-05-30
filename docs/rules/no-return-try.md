# `no-return-try`

> Category: pedantic
>
> Enabled by default?: No

## What This Rule Does

Disallows `return`ing a `try` expression.

Returning an error union directly has the same exact semantics as `try`ing
it and then returning the result.

## Examples

Examples of **incorrect** code for this rule:

```zig
const std = @import("std");

fn foo() !void {
  return error.OutOfMemory;
}

fn bar() !void {
  return try foo();
}
```

Examples of **correct** code for this rule:

```zig
const std = @import("std");

fn foo() !void {
  return error.OutOfMemory;
}

fn bar() !void {
  errdefer {
    std.debug.print("this still gets printed.\n", .{});
  }

  return foo();
}
```

## Configuration

This rule has no configuration.
