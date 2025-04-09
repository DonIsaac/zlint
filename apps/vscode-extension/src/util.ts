import { Readable } from "node:stream";

export function readableStreamToString(stream: Readable) {
    const { promise, resolve, reject } = Promise.withResolvers<string>();

    const chunks: Buffer[] = [];
    stream
        .on('data', chunk => chunks.push(chunk))
        .on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
        .on('error', reject)

    return promise
}
