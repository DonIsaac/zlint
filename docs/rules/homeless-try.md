# `homeless-try`

Category: compiler
Enabled by default?: No

## What This Rule Does

Checks for `try` statements used outside of error-returning functions.

As a `compiler`-level lint, this rule checks for errors also caught by the
Zig compiler.

## Examples

Examples of **incorrect** code for this rule:

```zig
const std = @import("std");

var not_in_a_function = try std.heap.page_allocator.alloc(u8, 8);

fn foo() void {
  var my_str = try std.heap.page_allocator.alloc(u8, 8);
}

fn bar() !void {
  const Baz = struct {
    property: u32 = try std.heap.page_allocator.alloc(u8, 8),
  };
}
```

Examples of **correct** code for this rule:

```zig
fn foo() !void {
  var my_str = try std.heap.page_allocator.alloc(u8, 8);
}
```
