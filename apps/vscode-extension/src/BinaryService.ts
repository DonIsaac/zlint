import path from 'node:path'
import { strict as assert } from 'node:assert'
import { promises as fs } from 'node:fs'
import { type ChildProcess, spawn } from 'node:child_process'
import type { ConfigService, Event } from './ConfigService'
import {
  EventEmitter,
  workspace,
  type Disposable,
  type OutputChannel,
} from 'vscode'
import { readableStreamToString } from './util'

const kEmptyArray: string[] = []

/**
 * @emits when path to zlint binary loads or changes
 */
export class BinaryService extends EventEmitter<void> implements Disposable {
  private zlintPath: string | undefined
  private version: string | undefined
  #onConfigChange: Disposable

  constructor(
    private configService: ConfigService,
    private log: OutputChannel,
  ) {
    super()

    this.runZlint = this.runZlint.bind(this)
    this.onConfigChange = this.onConfigChange.bind(this)

    this.#onConfigChange = configService.event(this.onConfigChange, this)
    // use empty string to avoid shape transitions
    this.zlintPath = ''
    this.version = ''
  }

  /**
   * @throws if `zlint` binary isn't found or hasn't been loaded/verified yet.
   */
  public runZlint(args: string[] = kEmptyArray): ChildProcess {
    const root = workspace.rootPath
    if (!this.zlintPath) {
      throw new Error('zlint binary path not set')
    }
    if (!root) throw new Error('workspace root path not set')
    this.log.appendLine(
      'running zlint: ' + this.zlintPath + ' ' + args.join(' '),
    )
    return spawn(this.zlintPath, args, {
      shell: true,
      stdio: ['ignore', 'pipe', 'pipe'],
      cwd: workspace.rootPath,
    })
  }

  public get ready(): boolean {
    return Boolean(this.zlintPath)
  }

  private async onConfigChange({ type }: Event): Promise<void> {
    if (type === 'disabled') return
    await this.findZLintBinary()
  }
  public async findZLintBinary(): Promise<void> {
    this.log.appendLine('looking for zlint binary...')
    const newPath = await this.getZLintPath(
      this.configService.config.path,
    ).catch((e) => this.log.appendLine(String(e)))
    if (!newPath || this.zlintPath === newPath) return
    this.log.appendLine('found zlint binary at ' + newPath)

    // only update path after version check, in case binary is not valid
    const version = await this.getZLintVersion(newPath)
    this.log.appendLine('found zlint version: ' + version)
    this.zlintPath = newPath
    this.version = version
    this.fire()
  }

  /**
   * @throws if `zlint` bin cannot be found
   * @throws if `configuredPath` does not point to a file
   */
  private async getZLintPath(
    configuredPath: string | undefined,
  ): Promise<string> {
    if (configuredPath) {
      const fullPath = path.resolve(configuredPath)
      const stat = await fs.stat(fullPath)
      if (!stat.isFile())
        throw new Error(`Path to zlint binary is not a file: ${configuredPath}`)
      return fullPath
    }

    const existing = await this.findExisting()
    // TODO: download zlint for them
    if (!existing)
      throw new Error(
        `Could not find path to zlint binary. Please download it and re-start this extension.`,
      )
    assert(path.isAbsolute(existing))
    return existing
  }

  /**
   * Basically just `which zlint`
   */
  private async findExisting(): Promise<string | undefined> {
    const { resolve } = Promise.withResolvers<string | undefined>()
    const child = spawn('which', ['zlint'], {
      shell: true,
      stdio: ['ignore', 'pipe', 'ignore'],
    })

    try {
      const stdout = await readableStreamToString(child.stdout!)
      resolve(stdout.length ? stdout : undefined)
    } catch {
      return undefined
    }
  }

  private async getZLintVersion(binpath: string): Promise<string> {
    const { promise, resolve } = Promise.withResolvers<string>()
    const child = spawn(binpath, ['--version'], {
      shell: true,
      stdio: ['ignore', 'pipe', 'ignore'],
    })

    let didResolve = false
    const bufs: Buffer[] = []
    child.stdout
      .on('data', (buf) => bufs.push(buf))
      .on('end', () => {
        if (didResolve) return
        const version: string = Buffer.concat(bufs).toString('utf8').trim()
        didResolve = true
        return resolve(version)
      })
    child.on('exit', (code) => {
      if (code !== 0 && !didResolve) {
        didResolve = true
        resolve('')
      }
    })

    return promise
  }

  dispose() {
    this.#onConfigChange.dispose()
  }
}
