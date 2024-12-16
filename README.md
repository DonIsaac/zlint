# ZLint

[![codecov](https://codecov.io/gh/DonIsaac/zlint/graph/badge.svg?token=5bDT3yGZt8)](https://codecov.io/gh/DonIsaac/zlint)
[![CI](https://github.com/DonIsaac/zlint/actions/workflows/ci.yaml/badge.svg)](https://github.com/DonIsaac/zlint/actions/workflows/ci.yaml)

An opinionated linter for the Zig programming language.

> [!WARNING]
> This project is still very much under construction.

## Features

- ZLint has its own semantic analyzer, heavily inspired by [the Oxc
  project](https://github.com/oxc-project/oxc), that is completely separate from
  the Zig compiler. This means that ZLint still checks and understands code that
  may otherwise be ignored by Zig due to dead code elimination.
- Pretty, detailed, and easy-to-understand error messages.
  ![image](https://github.com/user-attachments/assets/dbe0a38a-4906-42fe-a07e-9f7676e3973b)

## Installation

Pre-built binaries are available for each release. The latest release can be
found [here](https://github.com/DonIsaac/zlint/releases/latest). Note that
pre-built windows binaries are not yet available.

### Building from Source

Clone this repo and compile the project with Zig.

```sh
zig build --release=safe
```

## Lint Rules

All lints and what they do can be found [here](docs/rules/).

## Configuration

Create a `zlint.json` file in the same directory as `build.zig`. This disables
all default rules, only enabling the ones you choose.

```json
{
  "rules": {
    "no-undefined": "error",
    "homeless-try": "warn"
  }
}
```

## Contributing

If you have any rule ideas, please add them to the [rule ideas
board](https://github.com/DonIsaac/zlint/issues/3).

Interested in contributing code? Check out the [contributing
guide](CONTRIBUTING.md).
