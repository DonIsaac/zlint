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

## Lint Rules
All lints and what they do can be found [here](docs/rules/).

## Contributing

If you have any rule ideas, please add them to the [rule ideas
board](https://github.com/DonIsaac/zlint/issues/3).

Interested in contributing code? Check out the [contributing
guide](CONTRIBUTING.md).
