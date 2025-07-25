# `returned-stack-reference`

> Category: nursery
>
> Enabled by default?: No

## What This Rule Does

Checks for functions that return references to stack-allocated memory.

> [!NOTE]
> This rule is still in early development. PRs to improve it are welcome.

It is illegal to use stack-allocated memory outside of the function that
allocated it. Once that function returns and the stack is popped, the memory
is no longer valid and may cause segfaults or undefined behavior.

```zig
const std = @import("std");
fn foo() *u32 {
  var x: u32 = 1; // x is on the stack
  return &x;
}
fn bar() void {
  const x = foo();
  std.debug.print("{d}\n", .{x}); // crashes
}
```

## Examples

Examples of **incorrect** code for this rule:

```zig
const std = @import("std");
fn foo() *u32 {
  var x: u32 = 1;
  return &x;
}
fn bar() []u32 {
  var x: [1]u32 = .{1};
  return x[0..];
}
```

Examples of **correct** code for this rule:

```zig
fn foo() *u32 {
  var x = std.heap.page_allocator.create(u32);
  x.* = 1;
  return x;
}
```

## Configuration

This rule has no configuration.
