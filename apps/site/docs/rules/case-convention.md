# `case-convention`

> Category: style
> 
> Enabled by default?: No


## What This Rule Does
Checks for function names that are not in camel case. Specially coming from Rust,
some people may be used to use snake_case for their functions, which can lead to
inconsistencies in the code

## Examples

Examples of **incorrect** code for this rule:
```zig
fn this_one_is_in_snake_case() void {}
```

Examples of **correct** code for this rule:
```zig
fn thisFunctionIsInCamelCase() void {}
```

## Configuration
This rule has no configuration.
