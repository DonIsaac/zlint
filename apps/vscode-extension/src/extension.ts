import * as vscode from 'vscode'
import { ConfigService } from './ConfigService'
import { BinaryService } from './BinaryService'
import { DiagnosticsService } from './DiagnosticsService'

export function activate(context: vscode.ExtensionContext) {
  const logs = vscode.window.createOutputChannel('zlint')
  logs.clear()
  logs.appendLine('zlint extension activated')
  const config = new ConfigService(logs)
  logs.appendLine('Found config: ' + JSON.stringify(config.config))
  const bin = new BinaryService(config, logs)
  const diagnostics = new DiagnosticsService(config, bin, logs)

  bin
    .findZLintBinary()
    .catch((e) => logs.appendLine('error finding zlint binary: ' + e))

  const lintCmd = vscode.commands.registerCommand('zig.zlint.lint', () => {
    if (!bin.ready) {
      logs.appendLine('zlint binary not ready, not running zlint.lint')
      return
    }
    logs.appendLine('collecting diagnostics')
    diagnostics
      .collectDiagnostics()
      .then(() => logs.appendLine('done'))
      .catch((e) => logs.appendLine('error collecting diagnostics: ' + e))
  })

  const toggleCommand = vscode.commands.registerCommand(
    'zlint.toggle',
    () => config.set(
      'enabled',
      !config.config.enabled,
      vscode.ConfigurationTarget.WorkspaceFolder
    ),
  )
  

  context.subscriptions.push(config, bin, lintCmd, toggleCommand)
}
