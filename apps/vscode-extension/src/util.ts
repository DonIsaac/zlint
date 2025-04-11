import { Readable } from 'node:stream'
import assert from 'node:assert'

export function readableStreamToString(stream: Readable) {
  assert(stream && stream.readable)
  const { promise, resolve } = Promise.withResolvers<string>()

  const chunks: Buffer[] = []
  const finalize = () => Buffer.concat(chunks).toString('utf8')
  stream
    .on('data', (chunk) => chunks.push(chunk))
    .on('end', () => resolve(finalize()))
    .on('close', () => resolve(finalize()))

  return promise
}
