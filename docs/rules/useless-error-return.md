# `useless-error-return`

> Category: suspicious
>
> Enabled by default?: No

## What This Rule Does

Detects functions that have an error union return type but never actually return an error.
This can happen in two ways:

1. The function never returns an error value
2. The function catches all errors internally and never propagates them to the caller

Having an error union return type when errors are never returned makes the code less clear
and forces callers to handle errors that will never occur.

## Examples

Examples of **incorrect** code for this rule:

```zig
// Function declares error return but only returns void
fn foo() !void {
    return;
}

// Function catches all errors internally
pub fn init(allocator: std.mem.Allocator) !Foo {
    const new = allocator.create(Foo) catch @panic("OOM");
    new.* = .{};
    return new;
}

// Function only returns success value
fn bar() !void {
    const e = baz();
    return e;
}
```

Examples of **correct** code for this rule:

```zig
// Function properly propagates errors
fn foo() !void {
    return error.Oops;
}

// Function returns result of fallible operation
fn bar() !void {
    return baz();
}

// Function propagates caught errors
fn qux() !void {
    bar() catch |e| return e;
}

// Function with conditional error return
fn check(x: bool) !void {
    return if (x) error.Invalid else {};
}

// Empty error set is explicitly allowed
fn noErrors() error{}!void {}
```
