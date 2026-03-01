---
sidebar_position: 1
---

# Installation

The fastest way to install ZLint is with our installation scripts for [Linux/macOS](https://github.com/donisaac/zlint/blob/main/tasks/install.sh) and [Windows](https://github.com/donisaac/zlint/blob/main/tasks/install.ps1).

## Linux/macOS
```sh
curl -fsSL https://raw.githubusercontent.com/DonIsaac/zlint/refs/heads/main/tasks/install.sh | bash
```

## Windows
```ps1
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/DonIsaac/zlint/refs/heads/main/tasks/install.ps1" | Invoke-Expression
```

## Manual Installation

Each release is available on the [releases page](https://github.com/DonIsaac/zlint/releases/latest).
Click on the correct binary for your platform to download it.

## Building from Source
Clone this repo and compile the project with [Zig](https://ziglang.org/)'s build
system.

```zig
zig build --release=safe
```

:::tip
Full setup instructions are available [here](./contributing/index.mdx).
:::
