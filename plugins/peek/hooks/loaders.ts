import type { RemoteRecord, View } from '../types'
import { gitRoot } from './entries'
import { describeAge, describeSize } from './format'
import { drawMermaid, toPng, withDrawnMermaid } from './images'
import { fitMarkdown, htmlToMarkdown, linkTasks, outlineOf } from './markdown'
import { loadRemote } from './navigation'
import type { NavIo } from './navigation'
import { extOf, fileHref, kindOf } from './paths'
import type { Kind } from './paths'
import { parseRef } from './refs'
import { parseDelimited, prettyJson, tomlSections } from './tabular'
import { remoteFileOf } from './sources/web'
import { downloadFile } from './net'

export const fullText = new Map<string, string>()

type FileFacts = { io: NavIo; href: string; path: string; line?: number; base: View; sized: string; mtimeMs: number }
type Loader = (file: FileFacts) => Promise<View>
type TextLoader = (file: FileFacts, text: string, meta: string) => View | Promise<View>

const picture: Loader = async ({ io, path, base, sized, mtimeMs }) => {
  const kind = kindOf(path)
  const image = await toPng(io, path, mtimeMs)
  return { ...base, kind, meta: `${image.width}×${image.height} · ${sized}`, image }
}

function withText(load: TextLoader): Loader {
  return async file => {
    const text = await file.io.readFile(file.path)
    const lineCount = text.split('\n').length
    return load(file, text, `${lineCount} lines · ${file.sized}`)
  }
}

const markdown: TextLoader = async ({ io, href, path, base }, text, meta) => {
  const tasks = linkTasks(text, fileHref(path))
  const drawn = await withDrawnMermaid(io, tasks.text)
  fullText.set(href, drawn)
  const outline = outlineOf(drawn).map(({ level, text: heading }) => ({ level, text: heading }))
  const taskCount = tasks.total ? `${tasks.done}/${tasks.total} tasks` : undefined
  return { ...base, kind: 'markdown', meta, tasks: taskCount, outline, markdown: fitMarkdown(drawn) }
}

const mermaid: TextLoader = async ({ io, base }, text, meta) => {
  const art = await drawMermaid(io, text)
  const body = art
    ? `\`\`\`text\n${art.replace(/\s+$/, '')}\n\`\`\``
    : `*This diagram type cannot be drawn as text. Press "Open externally" to see it rendered.*\n\n\`\`\`mermaid\n${text}\n\`\`\``
  return { ...base, kind: 'mermaid', meta, markdown: fitMarkdown(body) }
}

const csv: TextLoader = ({ path, base }, text, meta) => {
  const rows = parseDelimited(text, extOf(path) === 'tsv' ? '\t' : ',')
  const [header = [], ...body] = rows
  const columns = Math.max(header.length, ...body.slice(0, 200).map(row => row.length))
  const table = { header, rows: body.slice(0, 500), total: body.length }
  return { ...base, kind: 'csv', meta, summary: `${body.length} rows × ${columns} columns`, table }
}

const code: TextLoader = ({ path, line, base }, text, meta) => {
  const kind = kindOf(path)
  let source = text
  let summary: string | undefined
  if (kind === 'json') {
    const pretty = prettyJson(text)
    if ('text' in pretty) {
      source = pretty.text
      summary = pretty.summary
    } else {
      summary = `invalid JSON: ${pretty.error}`
    }
  }
  if (kind === 'toml') {
    const sections = tomlSections(text)
    summary = `${sections} section${sections === 1 ? '' : 's'}`
  }
  const lines = source.split('\n')
  const startLine = line ? Math.max(1, line - 10) : 1
  const window: string[] = []
  let used = 0
  for (const one of lines.slice(startLine - 1, startLine + 1999)) {
    if (used + one.length > 80_000) break
    window.push(one)
    used += one.length + 1
  }
  const language = kind === 'json' ? 'json' : kind === 'toml' ? 'toml' : extOf(path)
  const shown = { source: window.join('\n'), language, startLine, focusLine: line }
  return { ...base, kind: kind === 'json' || kind === 'toml' ? kind : 'text', meta, summary, code: shown }
}

const LOADERS: Record<Kind, Loader> = {
  image: picture,
  svg: picture,
  html: async ({ io, path, base, sized }) => {
    const html = await io.readFile(path)
    return { ...base, kind: 'html', meta: sized, markdown: fitMarkdown(htmlToMarkdown(html)) }
  },
  markdown: withText(markdown),
  mermaid: withText(mermaid),
  csv: withText(csv),
  json: withText(code),
  toml: withText(code),
  text: withText(code),
}

export async function loadFile(io: NavIo, href: string, path: string, line?: number): Promise<View> {
  const title = path.split('/').pop() || path
  const folderOf = path.slice(0, Math.max(1, path.length - title.length - 1))
  const git = await gitRoot(io, folderOf)
  const base: View = { href, title, location: line ? `${path}:${line}` : path, root: git?.root, isWorktree: git?.isWorktree }
  const stat = await io.stat(path)
  const age = describeAge(stat.mtimeMs, await io.now())
  if (stat.kind === 'dir') {
    const entries = (await io.list(path)).filter(one => !one.name.startsWith('.'))
    const dir = entries
      .sort((a, b) => Number(b.kind === 'dir') - Number(a.kind === 'dir') || a.name.localeCompare(b.name))
      .slice(0, 500)
      .map(one => ({ name: one.name, isDir: one.kind === 'dir', size: one.size, mtimeMs: one.mtimeMs }))
    const folders = dir.filter(one => one.isDir).length
    const summary = `${folders} folders · ${dir.length - folders} files`
    return { ...base, kind: 'folder', meta: `${entries.length} items · edited ${age}`, summary, dir }
  }
  const sized = `${describeSize(stat.size)} · edited ${age}`
  return LOADERS[kindOf(path)]({ io, href, path, line, base, sized, mtimeMs: stat.mtimeMs })
}

function urlName(url: URL): string {
  const last = url.pathname.split('/').filter(Boolean).pop()
  try {
    return last ? decodeURIComponent(last) : url.hostname
  } catch {
    return last ?? url.hostname
  }
}

function videoView(url: URL, now: number): View {
  const host = url.hostname.replace(/^www\./, '')
  const record: RemoteRecord = {
    address: url.href,
    kind: 'web',
    title: urlName(url),
    trail: [host],
    meta: [{ label: 'Host', value: host }],
    body: `![video](${url.href})`,
    media: { [url.href]: { play: url.href } },
    browserUrl: url.href,
  }
  return { href: url.href, title: record.title, location: url.href, kind: 'web', remote: { record, tier: 'cli', fetchedAt: now } }
}

// The page keeps the URL as its address, so o opens and c copies the URL, not the scratch copy.
async function loadRemoteFile(io: NavIo, url: URL, file: { fetchUrl: string; ext: string }): Promise<View | null> {
  const got = await downloadFile(io.remoteIo(), file.fetchUrl, file.ext).catch(() => undefined)
  if (!got || /^text\/html/i.test(got.type ?? '')) return null
  const loaded = await loadFile(io, url.href, got.file).catch(() => null)
  if (!loaded || loaded.error) return null
  return { ...loaded, title: urlName(url), location: url.href, root: undefined, isWorktree: undefined }
}

export async function loadUrl(io: NavIo, href: string): Promise<View> {
  const url = new URL(href)
  const file = remoteFileOf(href)
  if (file?.kind === 'video') return videoView(url, await io.now())
  const fromFile = file ? await loadRemoteFile(io, url, file) : null
  if (fromFile) return fromFile
  const kind = kindOf(url.pathname)
  const base: View = { href, title: url.hostname + url.pathname, location: href, kind: 'web', meta: url.hostname }
  if (kind === 'image' || kind === 'svg') {
    return { ...base, error: 'Remote images open in the browser. Press "Open externally".' }
  }
  const ref = parseRef(href)
  if (file && ref) return loadRemote(io, ref)
  const response = await io.fetch(href)
  if (!response.ok) return { ...base, error: `HTTP ${response.status}` }
  const type = response.headers['content-type'] ?? ''
  if (type.startsWith('image/')) {
    return { ...base, error: 'Remote images open in the browser. Press "Open externally".' }
  }
  const markdown = type.includes('html') ? htmlToMarkdown(response.text) : response.text
  fullText.set(href, markdown)
  const outline = outlineOf(markdown).map(({ level, text }) => ({ level, text }))
  return { ...base, outline, markdown: fitMarkdown(markdown) }
}
