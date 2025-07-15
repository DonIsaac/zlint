# `homeless-try`

> Category: compiler
> 
> Enabled by default?: Yes (error)


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

Zig allows `try` in comptime scopes in or nested within functions. This rule
does not flag these cases.
```zig
const std = @import("std");
fn foo(x: u32) void {
  comptime {
    // valid
    try bar(x);
  }
}
fn bar(x: u32) !void {
  return if (x == 0) error.Unreachable else void;
}
```

Zig also allows `try` on functions whose error union sets are empty. ZLint
does _not_ respect this case. Please refactor such functions to not return
an error union.
```zig
const std = @import("std");
fn foo() !u32 {
  // compiles, but treated as a violation. `bar` should return `u32`.
  const x = try bar();
  return x + 1;
}
fn bar() u32 {
  return 1;
}
```

## Configuration
This rule has no configuration.
