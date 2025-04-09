import * as vscode from "vscode";
import { Diagnostic, type DiagnosticCollection, DiagnosticSeverity, Range } from "vscode";
import type { Disposable } from "vscode";
import type { BinaryService } from "./BinaryService";
import { readableStreamToString } from "./util";
import { strict as assert } from "node:assert";

export class DiagnosticsService implements Disposable {
    #diagnostics: DiagnosticCollection

    constructor(private bin: BinaryService) {
        this.#diagnostics = vscode.languages.createDiagnosticCollection('zlint')
    }

    public async collectDiagnostics(): Promise<void> {
        const zlint = this.bin.runZlint(['--format', 'json']);
        const newDiagnsotics = new Map<string, Diagnostic[]>();

        // todo: report diagnostics as they come in, instead of all at once
        const raw = await readableStreamToString(zlint.stdout!)
        for (const line of raw.split('\n')) {
            const json: ZLintDiagnostic = JSON.parse(line);
            assert(typeof json === 'object' && !!json)
            if (!json.labels?.length) continue
            const primary = json.labels.find(l => l.primary) ?? json.labels[0]

            let severity: DiagnosticSeverity;
            switch (json.level) {
                case 'warn':
                    severity = DiagnosticSeverity.Warning;
                    break;
                case 'error':
                    severity = DiagnosticSeverity.Error;
                    break;
            }

            const key = json.source_name ?? ''
            const fileDiagnostics = newDiagnsotics.get(key) ?? [];
            // todo: start/end -> line/col
            fileDiagnostics.push(new Diagnostic(undefined as any, json.message, severity))
            newDiagnsotics.set(key, fileDiagnostics)
        }

        this.#diagnostics.clear()
        for (const [file, diagnostics] of newDiagnsotics.entries()) {
            this.#diagnostics.set(vscode.Uri.file(file), diagnostics)
        }
    }

    dispose(): void {
        this.#diagnostics.dispose()
    }
}

interface ZLintDiagnostic {
    level: 'warn' | 'error'
    message: string
    help: string | null
    source_name: string | null
    labels?: Label[]
}
interface Label {
    spawn: { start: number, end: number }
    label: string | null
    primary: boolean
}
