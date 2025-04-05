import * as vscode from "vscode"
import { ConfigService } from "./ConfigService"

export function activate(context: vscode.ExtensionContext) {
    const config = new ConfigService();
    context.subscriptions.push(config);
}
