# `suppressed-errors`

> Category: suspicious
> 
> Enabled by default?: Yes (warning)


## What This Rule Does
Disallows suppressing or otherwise mishandling caught errors.

Functions that return error unions could error during "normal" execution.
If they didn't, they would not return an error or would panic instead.

This rule enforces that errors are
1. Propagated up to callers either implicitly or by returning a new error,
   ```zig
   const a = try foo();
   const b = foo catch |e| {
       switch (e) {
           FooError.OutOfMemory => error.OutOfMemory,
           // ...
       }
   }
   ```
2. Are inspected and handled to continue normal execution
   ```zig
   /// It's fine if users are missing a config file, and open() + err
   // handling is faster than stat() then open()
   var config?: Config = openConfig() catch null;
   ```
3. Caught and `panic`ed on to provide better crash diagnostics
   ```zig
   const str = try allocator.alloc(u8, size) catch @panic("Out of memory");
   ```

## Examples

Examples of **incorrect** code for this rule:
```zig
const x = foo() catch {};
const y = foo() catch {
  // comments within empty catch blocks are still considered violations.
};
// `unreachable` is for code that will never be reached due to invariants.
const y = foo() catch unreachable
```

Examples of **correct** code for this rule:
```zig
const x = foo() catch @panic("foo failed.");
const y = foo() catch {
  std.debug.print("Foo failed.\n", .{});
};
const z = foo() catch null;
// Writer errors may be safely ignored
writer.print("{}", .{5}) catch {};

// suppression is allowed in tests
test foo {
  foo() catch {};
}
```

## Configuration
This rule has no configuration.
