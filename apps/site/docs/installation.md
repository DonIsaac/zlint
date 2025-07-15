---
sidebar_position: 1
---

# Installation

The fastest way to install ZLint is with our [installation script](https://github.com/donisaac/zlint/blob/main/tasks/install.sh).

```sh
curl -fsSL https://raw.githubusercontent.com/DonIsaac/zlint/refs/heads/main/tasks/install.sh | bash
```

:::warning
This installation script does not work on Windows. Please download Windows
binaries directly from the
[releases page](https://github.com/DonIsaac/zlint/releases/latest).
:::

:::info[Want to contribute?]
If you're good at PowerShell and want to contribute, there is an open issue
for [adding a PowerShell installation script](https://github.com/DonIsaac/zlint/issues/221)
:::

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
Full setup instructions are available [here](./contributing/index.md).
:::
