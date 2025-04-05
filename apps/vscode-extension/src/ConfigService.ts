import { Disposable, EventEmitter, workspace, type ConfigurationChangeEvent } from 'vscode'

export interface Config {
    /**
     * Is the extension enabled?
     * @default true
     */
    enabled: boolean
}

type EnabledEvent = { type: 'enabled' }
type DisabledEvent = { type: 'disabled' }
type Event = EnabledEvent | DisabledEvent

export class ConfigService extends EventEmitter<Event> implements Disposable {
    public static configSection = 'zig.zlint'
    private subscriptions: Disposable[] = []
    #config: Config

    constructor() {
        super()
        this.#config = { enabled: true }
        this.subscriptions.push(workspace.onDidChangeConfiguration(this.onConfigChange, this));
    }

    public onConfigChange(event: ConfigurationChangeEvent): void {
        if (!(this instanceof ConfigService)) throw new TypeError("bad 'this' type; expected ConfigService");
        if (!event.affectsConfiguration(ConfigService.configSection)) return;
        const config = workspace.getConfiguration(ConfigService.configSection);

        const enabled = config.get<boolean>('enabled', true);
        if (this.#config.enabled !== enabled) {
            this.#config.enabled = enabled;
            this.fire({ type: enabled ? 'enabled' : 'disabled' } as EnabledEvent | DisabledEvent);
        }
    }

    public get config(): Readonly<Config> {
        return this.#config
    }

    public dispose() {
        super.dispose();
        this.subscriptions.forEach((s) => s.dispose())
    }
}
