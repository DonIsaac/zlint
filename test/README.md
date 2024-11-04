# E2E Tests

Tl;Dr:

```sh
just submodules
just e2e
```

This folder contains E2E & integration tests. They mostly focus on semantic
analysis. They can be run with `just e2e`.

## Structure

These tests are actually compiled as a binary, not as a test suite (e.g. `zig
build test`). `zlint` is linked as a module to this binary. Anything that is
marked `pub` in `src/root.ts` is importiable via `@import("zlint")` within a
test file.

Several test suites run checks on a set of popular zig codebases. These repos
are configured in `repos.json`. You must run `just submodules` to clone them
before running e2e tests.

