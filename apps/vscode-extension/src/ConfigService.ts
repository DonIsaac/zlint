import {
  ConfigurationTarget,
  Disposable,
  EventEmitter,
  workspace,
  type ConfigurationChangeEvent,
  type OutputChannel,
  type WorkspaceConfiguration,
} from 'vscode'

type EnabledEvent = { type: 'enabled' }
type DisabledEvent = { type: 'disabled' }
type ConfigChangeEvent = { type: 'change' }
export type Event = EnabledEvent | DisabledEvent | ConfigChangeEvent

export class ConfigService extends EventEmitter<Event> implements Disposable {
  public static configSection = 'zig.zlint'
  #subscriptions: Disposable[] = []
  #config: Config

  constructor(private log: OutputChannel) {
    super()
    this.#config = ConfigService.load()
    this.onConfigChange = this.onConfigChange.bind(this)
    this.emit = this.emit.bind(this)
    this.#subscriptions.push(
      workspace.onDidChangeConfiguration(this.onConfigChange, this),
    )
  }

  public set<K extends keyof Config>(
    key: K,
    value: Config[K],
    target?: ConfigurationTarget | boolean | null
  ): void {
    const config = workspace.getConfiguration(Config.scope)
    config.update(key, value, target)
  }

  private onConfigChange(event: ConfigurationChangeEvent): void {
    if (!(this instanceof ConfigService))
      throw new TypeError("bad 'this' type; expected ConfigService")
    const relevant = event.affectsConfiguration(ConfigService.configSection)

    this.log.appendLine('config changed. Do we care? ' + relevant)
    if (!relevant) return

    const { enabled, path } = ConfigService.load()

    if (this.#config.enabled !== enabled) {
      this.#config.enabled = enabled
      this.emit({ type: enabled ? 'enabled' : 'disabled' } as
        | EnabledEvent
        | DisabledEvent)
      return
    }
    if (!this.#config.enabled) return

    let didChange = false
    if (this.#config.path !== path) {
      this.#config.path = path
      didChange = true
    }

    if (didChange) {
      this.emit({ type: 'change' } as ConfigChangeEvent)
    }
  }

  public get config(): Readonly<Config> {
    return this.#config
  }

  private static load(): Config {
    return Config.loadFromWorkspace(
      workspace.getConfiguration(this.configSection),
    )
  }

  private emit(event: Event): void {
    this.log.appendLine('emitting event: ' + JSON.stringify(event))
    this.fire(event)
  }

  public dispose() {
    super.dispose()
    this.#subscriptions.forEach((s) => s.dispose())
  }
}

export interface Config {
  /**
   * Is the extension enabled?
   *
   * path: `.enabled`
   *
   * @default true
   */
  enabled: boolean
  /**
   * Absolute path to the `zlint` binary.
   *
   * path: `.path`
   */
  path: string | undefined
}
namespace Config {
  export const scope = 'zig.zlint'

  /**
   * Subscribe to configuration changes
   */
  export function subscribe(
    callback: (event: ConfigurationChangeEvent) => void,
    thisArg?: any,
  ): Disposable {
    return workspace.onDidChangeConfiguration(function (event) {
      if (event.affectsConfiguration(scope)) {
        callback.call(thisArg, event)
      }
    })
  }

  // oxlint-disable consistent-function-scoping
  export function loadFromWorkspace(config: WorkspaceConfiguration): Config {
    return {
      enabled: config.get<boolean>('enabled', true),
      path: config.get<string>('path'),
    }
  }
}
