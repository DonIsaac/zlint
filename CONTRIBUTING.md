# Contributing

Thanks for your interest in contributing to ZLint! This document outlines how to
set up your development environment and contribution guidelines.

## Setup

You'll obviously need to have [Zig](https://ziglang.org/) installed. Right now
we are using version `0.13.0`.

### Tl;Dr

We use the following tools:

- [just](https://github.com/casey/just) for running tasks
- [entr](http://eradman.com/entrproject/) for an ad-hoc watch mode
- [typos](https://github.com/crate-ci/typos) for spell checking
- [bun](https://bun.sh/) for generating boilderplate for new rules and other tasks

### Details

`just` and `typos` are both cargo crates. If you're familiar with Rust, you can
install them with `cargo install` (or even better, with [`cargo
binstall`](https://github.com/cargo-bins/cargo-binstall).

> NOTE: both crates are also available on Homebrew under the same name.

```sh
cargo binstall just typos-cli
```

Otherwise, you can
follow their respective installation instructions.

- [just installation
  guide](https://github.com/casey/just?tab=readme-ov-file#installation)
- [typos installation
  guide](https://github.com/crate-ci/typos?tab=readme-ov-file#install)

You'll also want `entr`. We use it for checking code on save. You only need it
to run `just watch`, but you'll definitely want to have this. Install it using
your package manager of choice.

```sh
apt install entr
# or
brew install entr
```

## Building, Testing, etc.

Run `just` (with no arguments) to see a full list of available tasks.

When debugging E2E tests or the `zlint` binary, using a single-threaded build is
often helpful.

```sh
just run -Dsingle-threaded
just e2e -Dsingle-threaded
```

## Contributing New Rules

1. Run `just new-rule <rule-name>` to generate boilderplate for a new rule.
2. Open `src/linter.siz` and register it inside the `Linter`.
3. Fill in the rule's method stubs.
4. Add test cases.
4. Open a PR.

## Conventions
Please follow these conventions when contributing to ZLint.

### Constructors and Destructors

1. Constructors that allocate memory are named `init`.
2. Constructors that do not allocate memory are named `new`.
3. Destructors are named `deinit`.

### File Naming and Structure

There are two kinds of files: "object" files and "namespace" files. Object files
use the entire file as a single `struct`, storing their members in the top
level. Namespace files do not do this, and instead declare or re-export various
data types.

#### Object File Conventions

Object files use `PascalCase` for the file name. Their layout follows this order:

1. field properties
2. Self-defined constants
3. Methods (static and instance)
   a. constructors and destructors (`init`, `deinit`) come first
   b. other methods come after
4. Nested data structures (e.g. structs, enums, unions)
5. Imports
6. Tests

#### Namespace File Conventions

Namespace files use `snake_case` for the file name. Avoid declaring functions in
the top scope of these files. This is not a hard rule, as it makes sense in some
cases, but try to group them by domain (where the domain is a `struct`).

Their layout follows this order:

1. Imports
2. Public data types
3. Public functions
4. Private data types & private methods (grouped logically)
5. Tests
