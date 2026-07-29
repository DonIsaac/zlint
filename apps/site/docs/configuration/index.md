---
sidebar_position: 3
---

# Configuration

Create a `zlint.json` file in your project. ZLint looks for `zlint.json` in the
current working directory and then walks up parent directories until it finds
one. When a config file is found, all default rules are disabled and only the
rules you choose are enabled.

:::tip
`zlint.json` does not yet support comments or trailing commas yet.
:::

```json title="zlint.json"
{
  "rules": {
    "unsafe-undefined": "error",
    "homeless-try": "warn",
    "unused-decls": "off"
  }
}
```

### Configuring Rules

Some rules accept configuration options. To pass them, provide an `[level, config]` tuple.

```json title="zlint.json"
{
  "rules": {
    "unsafe-undefined": ["error", { "allowed_types": ["PathBuf"] }]
  }
}
```

### Skipping Files

To skip linting specific files or groups of files, use the `ignore` field.
Directory entries are skipped when their paths start with an ignore entry; file
entries are matched as glob patterns.

```json title="zlint.json"
{
  "ignore": ["src/bad.zig", "src/subfolder"],
  "rules": {
    "unsafe-undefined": "error"
  }
}
```

:::tip
See [Ignoring Files](./ignore.md) for more details, including on how to
disable specific rules for a single file.
:::

## Intellisense

If you don't use ZLint's [VSCode Extension](https://marketplace.visualstudio.com/items?itemName=disaac.zlint-vscode),
you can get intellisense by linking directly to our [JSON Schema](https://raw.githubusercontent.com/DonIsaac/zlint/refs/heads/main/zlint.schema.json).

```json title="zlint.json"
{
  // highlight-next-line
  "$schema": "https://raw.githubusercontent.com/DonIsaac/zlint/refs/heads/main/zlint.schema.json",
  "rules": {
    "unsafe-undefined": "error",
    "homeless-try": "warn"
  }
}
```

Instead of using the schema directly from main, you can lock it to the specific version you use.

:::warning
When copying the below snippet, make sure you swap in the version of ZLint you are using!
:::

```json title="zlint.json"
{
  // highlight-next-line
  "$schema": "https://raw.githubusercontent.com/DonIsaac/zlint/refs/tags/v0.9.0/zlint.schema.json",
  "rules": {
    "unsafe-undefined": "error",
    "homeless-try": "warn"
  }
}
```
