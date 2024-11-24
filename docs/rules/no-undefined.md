# `no-undefined`

Category: restriction
Enabled by default?: No

## What This Rule Does

Disallows initializing or assigning variables to `undefined`.

Reading uninitialized memory is one of the most common sources of undefined
behavior. While debug builds come with runtime safety checks for `undefined`
access, they are otherwise undetectable and will not cause panics in release
builds.

### Allowed Scenarios

There are some cases where using `undefined` makes sense, such as array
initialization. Such cases should be communicated to other programmers via a
safety comment. Adding `SAFETY: <reason>` before the line using `undefined`
will not trigger a rule violation.

```zig
// SAFETY: arr is immediately initialized after declaration.
var arr: [10]u8 = undefined;
@memset(&arr, 0);
```

## Examples

Examples of **incorrect** code for this rule:

```zig
const x = undefined;

// Consumers of `Foo` should be forced to initialize `x`.
const Foo = struct {
  x: *u32 = undefined,
};

var y: *u32 = allocator.create(u32);
y.* = undefined;
```

Examples of **correct** code for this rule:

```zig
const Foo = struct {
  x: *u32,

  fn init(allocator: *std.mem.Allocator, value: u32) void {
    self.x = allocator.create(u32);
    self.x.* = value;
  }

  fn deinit(self: *Foo, alloc: std.mem.Allocator) void {
    alloc.destroy(self.x);
    // SAFETY: Foo is being deinitialized, so `x` is no longer used.
    // setting to undefined allows for use-after-free detection in
    //debug builds.
    self.x = undefined;
  }
};
```
