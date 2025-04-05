# `unsafe-undefined`

> Category: restriction
>
> Enabled by default?: Yes (warning)

## What This Rule Does

Disallows initializing or assigning variables to `undefined`.

Reading uninitialized memory is one of the most common sources of undefined
behavior. While debug builds come with runtime safety checks for `undefined`
access, they are otherwise undetectable and will not cause panics in release
builds.

### Allowed Scenarios

There are some cases where using `undefined` makes sense, such as array
initialization. Some cases are implicitly allowed, but others should be
communicated to other programmers via a safety comment. Adding `SAFETY:
<reason>` before the line using `undefined` will not trigger a rule
violation.

```zig
// SAFETY: foo is written to by `initializeFoo`, so `undefined` is never
// read.
var foo: u32 = undefined
initializeFoo(&foo);

// SAFETY: this covers the entire initialization
const bar: Bar = .{
  .a = undefined,
  .b = undefined,
};
```

> [!NOTE]
> Oviously unsafe usages of `undefined`, such `x == undefined`, are not
> allowed even in these exceptions.

#### Arrays

Array-typed variable declarations may be initialized to undefined.
Array-typed container fields with `undefined` as a default value will still
trigger a violation.

```zig
// arrays may be set to undefined without a safety comment
var arr: [10]u8 = undefined;
@memset(&arr, 0);

// This is not allowed
const Foo = struct {
  foo: [4]u32 = undefined
};
```

#### Destructors

Invalidating freed pointers/data by setting it to `undefined` is helpful for
finding use-after-free bugs. Using `undefined` in destructors will not trigger
a violation, unless it is obviously unsafe (e.g. in a comparison).

```zig
const std = @import("std");
const Foo = struct {
  data: []u8,
  pub fn init(allocator: std.mem.Allocator) !Foo {
     const data = try allocator.alloc(u8, 8);
     return .{ .data = data };
  }
  pub fn deinit(self: *Foo, allocator: std.mem.Allocator) void {
    allocator.free(self.data);
    self.* = undefined; // safe
  }
};
```

A method is considered a destructor if it is named

- `deinit`
- `destroy`
- `reset`

#### `test` blocks

All usages of `undefined` in `test` blocks are allowed. Code that isn't safe
will be caught by the test runner.

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

  // variables may be re-assigned to `undefined` in destructors
  fn deinit(self: *Foo, alloc: std.mem.Allocator) void {
    alloc.destroy(self.x);
    self.x = undefined;
  }
};

test Foo {
  // Allowed. If this is truly unsafe, it will be caught by the test.
  var foo: Foo = undefined;
  // ...
}
```

## Configuration

This rule accepts the following options:

- allow_arrays: boolean
