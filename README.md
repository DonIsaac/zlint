# ⚡️ ZLint

[![codecov](https://codecov.io/gh/DonIsaac/zlint/graph/badge.svg?token=5bDT3yGZt8)](https://codecov.io/gh/DonIsaac/zlint)
[![CI](https://github.com/DonIsaac/zlint/actions/workflows/ci.yaml/badge.svg)](https://github.com/DonIsaac/zlint/actions/workflows/ci.yaml)
[![Discord](https://img.shields.io/static/v1?logo=discord&label=discord&message=Join&color=blue)](https://discord.gg/UcB7HjJxcG)

An opinionated linter for the Zig programming language.

## ✨ Features

- 🔍 **Custom Analysis**. ZLint has its own semantic analyzer, heavily inspired
  by [the Oxc project](https://github.com/oxc-project/oxc), that is completely
  separate from the Zig compiler. This means that ZLint still checks and
  understands code that may otherwise be ignored by Zig due to dead code
  elimination.
- ⚡️ **Fast**. Designed from the ground-up to be highly performant, ZLint
  typically takes a few hundred milliseconds to lint large projects.
- 💡 **Understandable**. Error messages are pretty, detailed, and easy to understand. 
  Most rules come with explanations on how to fix them and what _exactly_ is wrong.
  ![diagnostic example](./docs/assets/diagnostic-example.jpg)

## 📦 Installation
Pre-built binaries for Windows, MacOS, and Linux on x64 and aarch64 are
available [for each release](https://github.com/DonIsaac/zlint/releases/latest).

```sh
curl -fsSL https://raw.githubusercontent.com/DonIsaac/zlint/refs/heads/main/tasks/install.sh | bash
```

> [!WARNING]
> This installation script does not work on Windows. Please download Windows
> binaries directly from the releases page.

### 🔨 Building from Source

Clone this repo and compile the project with Zig.

```sh
zig build --release=safe
```

## ⚡️ Lint Rules

All lints and what they do can be found [here](docs/rules/).

## ⚙️ Configuration

Create a `zlint.json` file in the same directory as `build.zig`. This disables
all default rules, only enabling the ones you choose.

```json
{
  "rules": {
    "unsafe-undefined": "error",
    "homeless-try": "warn"
  }
}
```

ZLint also supports [ESLint-like disable directives](https://eslint.org/docs/latest/use/configure/rules#comment-descriptions) to turn off some or all rules for a specific file.

```zig
// zlint-disable unsafe-undefined -- We need to come back and fix this later
const x: i32 = undefined;
```

## 🙋‍♂️ Contributing

If you have any rule ideas, please add them to the [rule ideas
board](https://github.com/DonIsaac/zlint/issues/3).

Interested in contributing code? Check out the [contributing
guide](CONTRIBUTING.md).
