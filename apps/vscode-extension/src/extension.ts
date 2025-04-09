import * as vscode from 'vscode';
import { ConfigService } from './ConfigService';
import { BinaryService } from './BinaryService';

export function activate(context: vscode.ExtensionContext) {
    const config = new ConfigService();
    const bin = new BinaryService(config);
    context.subscriptions.push(config, bin);
}
