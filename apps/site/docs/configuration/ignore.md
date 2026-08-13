---
id: ignore
title: Ignoring Files and Rules
---

ZLint provides several ways to ignore files and specific rules, each with varying
degrees of granularity.

## Ignoring Whole Files
ZLint respects `.gitignore` files by default; no files ignored by git will be
linted.

To ignore additional files, provide a list of glob patterns in the `ignore`
field of your `zlint.json` file.

```json title="zlint.json"
{
  "ignore": ["src/test/**"],
  "rules": { /* ... */ }
}
```

### Ignores and Path Arguments

Ignore patterns apply to files ZLint finds by walking a directory. A file you
name directly on the command line is always linted, even when a pattern covers
it:

```sh
zlint                     # skips ignored files
zlint src                 # same, for everything under `src/`
zlint src/generated.zig   # lints it, ignored or not
```

`zlint src`, `zlint src/`, and `zlint 'src/**'` are all the same request, and
`zlint .` lints exactly what passing no arguments does.

## Disabling Rules
You can globally disable rules by setting their level to `off` in your
configuration file.

```json title="zlint.json"
{
  "rules": {
    "unused-decls": "off"
  }
}
```

## Disabling Rules for a Single File

You can use [ESLint-style disable
directives](https://eslint.org/docs/latest/user-guide/configuring/ignoring-code)
to disable one or more rules for a single file. Put a `// zlint-disable` comment
at the top of your file to disable all rules, or add a list of rules to disable.
You may put arbitrary text after `--` to explain why you're disabling the rules
if you want.

```zig title="src/bad.zig"
// zlint-disable unused-decls, unsafe-undefined -- this is an optional explanation

const std = @import("std");
// highlight-next-line
const unused = @import("./foo.zig"); // would normally be reported by `unused-decls`

fn foo() u32 {
  // highlight-next-line
  var x: u32 = undefined; // would normally be reported by `unsafe-undefined`
  return x;
}
```

:::warning
Next-line disable directives are not yet supported. Track issue
[#184](https://github.com/DonIsaac/zlint/issues/184) for updates.
:::
