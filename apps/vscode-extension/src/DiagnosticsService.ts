import * as vscode from 'vscode'
import {
  Diagnostic,
  type DiagnosticCollection,
  DiagnosticSeverity,
  Range,
} from 'vscode'
import type { Disposable } from 'vscode'
import type { BinaryService } from './BinaryService'
import { readableStreamToString } from './util'
import { strict as assert } from 'node:assert'
import path from 'node:path'
import type { ConfigService } from './ConfigService'

const name = 'zlint'
export class DiagnosticsService implements Disposable {
  #diagnostics: DiagnosticCollection
  #subscriptions: Disposable[] = []

  constructor(
    private config: ConfigService,
    private bin: BinaryService,
    private log: vscode.OutputChannel,
  ) {
    this.#diagnostics = vscode.languages.createDiagnosticCollection(name)
    this.collectDiagnostics = this.collectDiagnostics.bind(this)
    this.#subscriptions.push(
      this.config.event((e) => {
        if (e.type === 'disabled') {
          this.#diagnostics.clear
        }
      }),
    )
  }

  public async collectDiagnostics(): Promise<void> {
    const log = this.log
    log.appendLine('collecting diagnostics...')
    const linter = this.bin.runZlint(['--format', 'json'])
    const newDiagnsotics = new Map<string, Diagnostic[]>()
    linter.on('exit', (code) =>
      log.appendLine('zlint exited with code ' + code),
    )

    // todo: report diagnostics as they come in, instead of all at once
    const raw = await readableStreamToString(linter.stdout!).catch((e) =>
      log.appendLine('error reading zlint output: ' + e),
    )
    log.appendLine('zlint output: ' + raw)
    if (!raw) return
    const lines = raw.split('\n').filter(Boolean)

    log.appendLine(`zlint output lines: ${lines}`)

    for (const line of lines) {
      log.appendLine('here 2')
      try {
        var json: zlint.Diagnostic = JSON.parse(line)
      } catch (e) {
        log.appendLine('error parsing zlint output: ' + line)
        log.appendLine(String(e))
        continue
      }
      if (json.source_name && vscode.workspace.rootPath)
        json.source_name = path.resolve(
          vscode.workspace.rootPath!,
          json.source_name,
        )
      assert(typeof json === 'object' && !!json)
      if (!json.labels?.length) continue

      const key = json.source_name ?? ''
      const fileDiagnostics = newDiagnsotics.get(key) ?? []
      fileDiagnostics.push(zlint.Diagnostic.toDiagnostic(json))
      newDiagnsotics.set(key, fileDiagnostics)
    }

    this.#diagnostics.clear()
    for (const [file, diagnostics] of newDiagnsotics.entries()) {
      log.appendLine(`setting ${diagnostics.length} diagnostics for ${file}`)
      this.#diagnostics.set(vscode.Uri.file(file), diagnostics)
    }
  }

  dispose(): void {
    this.#diagnostics.dispose()
    this.#subscriptions.forEach((sub) => sub.dispose())
  }
}

namespace zlint {
  export interface Loc {
    line: number
    column: number
  }
  export namespace Loc {
    export function toPosition(location: Loc): vscode.Position {
      return new vscode.Position(location.line - 1, location.column - 1)
    }
  }

  export interface Label {
    start: Loc
    end: Loc
    label: string | null
    primary: boolean
  }
  export namespace Label {
    export function toRange(label: Label): vscode.Range {
      const start = Loc.toPosition(label.start)
      const end = Loc.toPosition(label.end)
      return new Range(start, end)
    }
  }

  export interface Diagnostic {
    level: 'warn' | 'error'
    code: string | null
    message: string
    help: string | null
    source_name: string | null
    labels?: Label[]
  }
  export namespace Diagnostic {
    export function toDiagnostic(diagnostic: Diagnostic): vscode.Diagnostic {
      const { level, message, labels = [], code } = diagnostic
      const severity =
        level === 'warn' ? DiagnosticSeverity.Warning : DiagnosticSeverity.Error
      const primary: Label | undefined =
        labels.find((label) => label.primary) ?? labels[0]
      const range = primary ? Label.toRange(primary) : new Range(0, 0, 0, 0)
      const d = new vscode.Diagnostic(range, message, severity)
      d.source = name
      d.code = code ?? undefined
      return d
    }
  }
}
