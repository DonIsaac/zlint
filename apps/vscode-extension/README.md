# ZLint VSCode Extension

A Visual Studio Code extension that integrates the [ZLint](https://github.com/DonIsaac/zlint) linter for Zig code.

## ✨ Features

- 🔍 **Real-time Linting**: Automatically detects and highlights issues in your Zig code
- ⚡️ **Fast Performance**: Quick analysis without slowing down your editor
- 💡 **Detailed Diagnostics**: Clear error messages with explanations and suggestions
- 🛠️ **Configurable**: Customize linting behavior through VSCode settings

## 📦 Installation

1. Install the ZLint binary:
   - Linux/macOS
     ```sh
     curl -fsSL https://raw.githubusercontent.com/DonIsaac/zlint/refs/heads/main/tasks/install.sh | bash
     ```
   - Windows
     ```ps1
     Invoke-WebRequest -Uri "https://raw.githubusercontent.com/DonIsaac/zlint/refs/heads/main/tasks/install.ps1" | Invoke-Expression
     ```

2. Install the extension from the VSCode marketplace or build it locally:
   ```sh
   bun install
   ```

## ⚙️ Configuration

The extension can be configured through VSCode settings:

```json
{
  "zig.zlint": {
    "enabled": true,
    "path": "/path/to/zlint" // Optional: specify custom path to zlint binary
  }
}
```

### Settings

- `zig.zlint.enabled`: Enable/disable the extension (default: `true`)
- `zig.zlint.path`: Custom path to the zlint binary (optional)

## 🔨 Building from Source

1. Clone the repository
2. Install dependencies:
   ```sh
   bun install
   ```
3. Build the extension:
   ```sh
   bun run index.ts
   ```

## 📝 License

This extension is licensed under the same terms as the ZLint project.
