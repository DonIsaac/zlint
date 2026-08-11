---
sidebar_position: 4
---

# Custom rules

If using the zig build system to integrate with zlint,
zlint supports user-provided rules written in zig.

## Installing zlint as a zig build system dependency

1. Depend on zlint `zig fetch --save=zlint git+https://github.com/DonIsaac/zlint/#main`
2. Import zlint's build module into your `build.zig` and add a "run lint" build step:
   ```zig
   const zlint = @import("zlint");
   const lint_step = b.step("lint", "run zlint");
   const zlint_dep = b.dependency("zlint", .{
       // optional custom rules
       .custom_rules = &[_]std.Build.LazyPath{
           b.path("./src/your_custom_rule.zig"),
       },
   });
   const run_lint = zlint.addRunLint(b, zlint_dep);
   lint_step.dependOn(&run_lint.step);
   ```

## Using Custom Rules

Custom rules are specified as a zig build option, `-Dcustom_rules`, so you need to
list the local paths to each rule in your `build.zig` when defining the
`zlint` dependency, as shown in the above text snippet.

## Testing

You can add a "custom lint rules test" build step with:

```zig
const zlint = @import("zlint");
const test_lint_step = b.step("test-linter", "run tests for my custom rules");
const zlint_dep = b.dependency("zlint", .{
    .custom_rules = &[_]std.Build.LazyPath{
        b.path("./src/your_custom_rule.zig"),
    },
});
const custom_lint_tests = zlint.addCustomLintRulesTest(b, zlint_dep);
const run_lint_tests = b.addRunArtifact(custom_lint_tests);
test_lint_step.dependOn(&run_lint_tests.step);
```

addCustomLintRulesTest returns `*Build.Step.Compile` just like `b.addTest`.

## Custom Rule API

