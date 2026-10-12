import type { EngineInterface, ProcessRunInit, ProcessRunResult } from 'claude-code'

import type { RemoteRecord } from '../types'
import { mermaidFences, swapMermaidFences } from './markdown'
import { extOf, resolvePath } from './paths'

export type ImageIo = {
  run: (argv: readonly string[], init?: ProcessRunInit) => Promise<ProcessRunResult>
  readBytes: (path: string) => Promise<{ base64: string }>
  home: () => Promise<string | undefined>
  stat: (path: string) => ReturnType<EngineInterface['fs']['stat']>
  columns: () => number
}

export type Picture = { file: string; width: number; height: number }

export const SCRATCH = '/tmp/claude-peek'
const MERMAID_ASCII = '/.cache/claude-peek/bin/mermaid-ascii'
const MAX_PNG_BYTES = 2 * 1024 * 1024
// A pane is about 100 columns of 8 px, so 800 px is already sharper than it can show, and keeps each picture small.
export const WEB_EDGES = [800, 600, 400]
// A face draws 4 columns by 2 rows; WEB_EDGES would blow Slack's 72 px avatar up to 800 px.
export const AVATAR_EDGES = [72]

export const pixels = new Map<string, string>()
const converted = new Map<string, Picture>()
const failedPictures = new Set<string>()

async function pngSize(io: ImageIo, file: string) {
  const { stdout } = await io.run(['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', file])
  const width = Number(/pixelWidth:\s*(\d+)/.exec(stdout)?.[1] ?? 0)
  const height = Number(/pixelHeight:\s*(\d+)/.exec(stdout)?.[1] ?? 0)
  return { width: width || 800, height: height || 600 }
}

async function hashName(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-1', new TextEncoder().encode(text))
  return [...new Uint8Array(digest)].slice(0, 8).map(b => b.toString(16).padStart(2, '0')).join('')
}

async function runOrThrow(io: ImageIo, argv: string[]) {
  const ran = await io.run(argv)
  if (ran.exitCode !== 0) throw new Error(ran.stderr.trim() || `${argv[0]} failed`)
}

// The bytes go to the terminal inline: a multiplexer between Claude Code and
// the terminal may pass kitty images sent as data but not ones sent as a path.
export async function toPng(io: ImageIo, abs: string, mtimeMs: number, edges: readonly number[] = [1600, 1000, 600]) {
  const cacheKey = `${abs}@${mtimeMs}@${edges.join(',')}`
  const cached = converted.get(cacheKey)
  if (cached && pixels.has(cached.file)) return cached
  await io.run(['mkdir', '-p', SCRATCH])
  const name = await hashName(cacheKey)
  let source = abs
  if (extOf(abs) === 'svg') {
    source = `${SCRATCH}/${name}-svg.png`
    await runOrThrow(io, ['rsvg-convert', '-w', '1600', '-o', source, abs])
  }
  const file = `${SCRATCH}/${name}.png`
  for (const edge of edges) {
    await runOrThrow(io, ['sips', '-Z', String(edge), '-s', 'format', 'png', source, '--out', file])
    const { base64 } = await io.readBytes(file)
    if (base64.length * 0.75 <= MAX_PNG_BYTES) {
      pixels.set(file, base64)
      break
    }
  }
  if (!pixels.has(file)) throw new Error('Image is too large to show here. Press "Open externally".')
  const image = { file, ...(await pngSize(io, file)) }
  converted.set(cacheKey, image)
  return image
}

export async function drawMermaid(io: ImageIo, source: string): Promise<string | null> {
  const home = (await io.home()) ?? ''
  const ran = await io
    .run([`${home}${MERMAID_ASCII}`, '-f', '-', '--max-width', String(Math.max(40, io.columns() - 4))], {
      stdin: source,
      timeoutMs: 10000,
    })
    .catch(() => null)
  if (!ran || ran.exitCode !== 0 || !ran.stdout.trim()) return null
  return ran.stdout
}

export async function withDrawnMermaid(io: ImageIo, markdown: string): Promise<string> {
  const fences = mermaidFences(markdown)
  if (!fences.length) return markdown
  const drawn: (string | null)[] = []
  for (const fence of fences) drawn.push(await drawMermaid(io, fence))
  return swapMermaidFences(markdown, drawn)
}

export async function remotePicture(io: ImageIo, file: string | undefined) {
  if (!file || failedPictures.has(file)) return undefined
  return toPng(io, file, 0, WEB_EDGES).catch(() => {
    failedPictures.add(file)
    return undefined
  })
}

export async function pictures(io: ImageIo, files: Record<string, string | undefined>, edges: readonly number[]) {
  const found = await Promise.all(
    Object.entries(files).map(async ([key, file]) => {
      if (file === undefined || failedPictures.has(file)) return [key, undefined] as const
      const picture = await toPng(io, file, 0, edges).catch(() => {
        failedPictures.add(file)
        return undefined
      })
      return [key, picture] as const
    }),
  )
  const drawn = Object.fromEntries(found.filter((one): one is readonly [string, NonNullable<(typeof one)[1]>] => Boolean(one[1])))
  return Object.keys(drawn).length ? drawn : undefined
}

// remotePicture skipped an empty file name, so the media map keeps doing so.
export const mediaFiles = (media: RemoteRecord['media']) => Object.fromEntries(Object.entries(media ?? {}).map(([key, one]) => [key, one.file || undefined]))

export async function docImage(io: ImageIo, src: string, docPath: string) {
  if (/^https?:/.test(src)) return null
  const folder = docPath.slice(0, docPath.lastIndexOf('/'))
  const home = (await io.home()) ?? ''
  const abs = resolvePath(decodeURIComponent(src.replace(/^file:\/\//, '')), folder, home)
  const stat = await io.stat(abs).catch(() => null)
  if (!stat || stat.kind !== 'file') return null
  const image = await toPng(io, abs, stat.mtimeMs).catch(() => null)
  const png = image ? pixels.get(image.file) : undefined
  return image && png ? { abs, png, width: image.width, height: image.height } : { abs, png: undefined, width: 0, height: 0 }
}
