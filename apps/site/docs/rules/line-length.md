# `line-length`

> Category: style
> 
> Enabled by default?: No


## What This Rule Does

Checks if any line goes beyond a given number of columns.

## Examples

Examples of **incorrect** code for this rule (with a threshold of 120 columns):
```zig
const std = @import("std");
const longStructDeclarationInOneLine = struct { max_length: u32 = 120, a: usize = 123, b: usize = 12354, c: usize = 1234352 };
fn reallyExtraVerboseFunctionNameToThePointOfBeingACodeSmellAndProbablyAHintThatYouCanGetAwayWithAnotherNameOrSplittingThisIntoSeveralFunctions() u32 {
    return 123;
}
```

Examples of **correct** code for this rule (with a threshold of 120 columns):
```zig
const std = @import("std");
const longStructInMultipleLines = struct {
    max_length: u32 = 120,
    a: usize = 123,
    b: usize = 12354,
    c: usize = 1234352,
};
fn Get123Constant() u32 {
    return 123;
}
```

## Configuration
This rule accepts the following options:
- max_length: int
