# `no-catch-return`

> Category: pedantic
>
> Enabled by default?: Yes (warning)

## What This Rule Does

Disallows `catch` blocks that immediately return the caught error.

Catch blocks that do nothing but return their error can and should be
replaced with a `try` statement. This rule allows for `catch`es that
have side effects such as printing the error or switching over it.

## Examples

Examples of **incorrect** code for this rule:

```zig
fn foo() !void {
  riskyOp() catch |e| return e;
  riskyOp() catch |e| { return e; };
}
```

Examples of **correct** code for this rule:

```zig
const std = @import("std");

fn foo() !void{
  try riskyOp();
}

// re-throwing with side effects is fine
fn bar() !void {
  riskyOp() catch |e| {
    std.debug.print("Error: {any}\n", .{e});
    return e;
  };
}

// throwing a new error is fine
fn baz() !void {
  riskyOp() catch |e| return error.OutOfMemory;
}
```

## Configuration

This rule has no configuration.
