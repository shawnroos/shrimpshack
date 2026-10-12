import { familyOf, linkRefs, refHref } from './refs'
import type { RefContext } from './refs'
import { PATH_EXTS, extOf, fileHref, kindOf, parseHref } from './paths'
export * from './measure'
export * from './tabular'
export * from './format'
export * from './paths'

// The negative lookbehind keeps a path inside a URL or a word from matching.
const BARE_PATH = new RegExp(
  `(?<![\\w/.:~-])((?:~|\\.{1,2})?/?(?:[\\w.@-]+/)*[\\w.@-]+\\.(?:${PATH_EXTS}))(?::(\\d+))?(?![\\w/])`,
  'gi',
)
const CODE_SPAN = /`([^`\n]+)`/g
const MD_LINK = /\[[^\]\n]*\]\([^)\n]*\)/g

type Segment = { text: string; isProse: boolean }

// Fenced blocks, code spans and existing links are kept apart so only prose and
// code-span contents are ever rewritten.
function splitFences(text: string): Segment[] {
  const segments: Segment[] = []
  let inFence = false
  let buffer: string[] = []
  for (const line of text.split('\n')) {
    const isFenceLine = /^\s*(```|~~~)/.test(line)
    if (isFenceLine && !inFence) {
      if (buffer.length) segments.push({ text: buffer.join('\n'), isProse: true })
      buffer = [line]
      inFence = true
    } else if (isFenceLine && inFence) {
      buffer.push(line)
      segments.push({ text: buffer.join('\n'), isProse: false })
      buffer = []
      inFence = false
    } else {
      buffer.push(line)
    }
  }
  if (buffer.length) segments.push({ text: buffer.join('\n'), isProse: !inFence })
  return segments
}

function splitPattern(text: string, pattern: RegExp): Segment[] {
  const segments: Segment[] = []
  let last = 0
  for (const match of text.matchAll(pattern)) {
    segments.push({ text: text.slice(last, match.index), isProse: true })
    segments.push({ text: match[0], isProse: false })
    last = match.index + match[0].length
  }
  segments.push({ text: text.slice(last), isProse: true })
  return segments
}

function splitCodePath(span: string): { raw: string; line?: number } | null {
  const match = /^(.+?)(?::(\d+))?$/.exec(span.trim())
  const raw = match?.[1]
  if (!raw || /\s/.test(raw) || !/[/.]/.test(raw) || /^[a-z]+:\/\//i.test(raw)) return null
  return { raw, line: match[2] ? Number(match[2]) : undefined }
}

export function pathCandidates(text: string): string[] {
  const found = new Set<string>()
  for (const fence of splitFences(text)) {
    if (!fence.isProse) continue
    for (const part of splitPattern(fence.text, MD_LINK)) {
      if (!part.isProse) continue
      for (const code of splitPattern(part.text, CODE_SPAN)) {
        if (code.isProse) {
          for (const match of code.text.matchAll(BARE_PATH)) if (match[1]) found.add(match[1])
        } else {
          const path = splitCodePath(code.text.slice(1, -1))
          if (path) found.add(path.raw)
        }
      }
    }
  }
  return [...found]
}

export function linkify(
  text: string,
  hrefFor: (raw: string, line?: number) => string | null,
  refs?: RefContext,
): string {
  return splitFences(text)
    .map(fence => {
      if (!fence.isProse) return fence.text
      return splitPattern(fence.text, MD_LINK)
        .map(part => {
          if (!part.isProse) return part.text
          return splitPattern(part.text, CODE_SPAN)
            .map(code => {
              if (code.isProse) {
                const withPaths = code.text.replace(BARE_PATH, (whole, raw: string, line?: string) => {
                  const href = hrefFor(raw, line ? Number(line) : undefined)
                  return href ? `[${whole}](${href})` : whole
                })
                if (!refs) return withPaths
                return splitPattern(withPaths, MD_LINK)
                  .map(piece => (piece.isProse ? linkRefs(piece.text, refs) : piece.text))
                  .join('')
              }
              const path = splitCodePath(code.text.slice(1, -1))
              const href = (path && hrefFor(path.raw, path.line)) || (refs && refHref(code.text.slice(1, -1), refs))
              return href ? `[${code.text}](${href})` : code.text
            })
            .join('')
        })
        .join('')
    })
    .join('')
}

export function htmlToMarkdown(html: string): string {
  return html
    .replace(/<(script|style|head|noscript)[\s\S]*?<\/\1>/gi, '')
    .replace(/<h([1-6])[^>]*>([\s\S]*?)<\/h\1>/gi, (_, n: string, body: string) => `\n\n${'#'.repeat(Number(n))} ${body}\n\n`)
    .replace(/<a\s[^>]*href="(https?:[^"]+)"[^>]*>([\s\S]*?)<\/a>/gi, '[$2]($1)')
    .replace(/<li[^>]*>/gi, '\n- ')
    .replace(/<(br|\/p|\/div|\/tr|\/ul|\/ol|\/section|\/article)[^>]*>/gi, '\n')
    .replace(/<pre[^>]*>([\s\S]*?)<\/pre>/gi, '\n```\n$1\n```\n')
    .replace(/<[^>]+>/g, '')
    .replace(/&nbsp;/g, ' ')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&amp;/g, '&')
    .replace(/[ \t]+\n/g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim()
}

export function fitMarkdown(text: string, limit = 9500): string {
  if (text.length <= limit) return text
  const cut = text.slice(0, limit)
  const isInFence = (cut.match(/^\s*```/gm) ?? []).length % 2 === 1
  return `${cut}${isInFence ? '\n```' : ''}\n\n*… cut at ${limit} characters. Open externally for the rest.*`
}

export function mermaidPage(title: string, source: string): string {
  const escaped = source.replace(/&/g, '&amp;').replace(/</g, '&lt;')
  return `<!doctype html><meta charset="utf-8"><title>${title}</title>
<style>body{font-family:system-ui;margin:2rem;background:#fff}</style>
<pre class="mermaid">${escaped}</pre>
<script type="module">import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';mermaid.initialize({startOnLoad:true})</script>`
}

export function markdownPage(title: string, source: string): string {
  return `<!doctype html><meta charset="utf-8"><title>${title}</title>
<style>body{font-family:system-ui;max-width:860px;margin:2rem auto;padding:0 1rem;line-height:1.55}pre{background:#f4f4f4;padding:1rem;overflow:auto}img{max-width:100%}</style>
<div id="out"></div>
<script type="module">
import { marked } from 'https://cdn.jsdelivr.net/npm/marked@14/lib/marked.esm.js'
import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs'
const src = ${JSON.stringify(source)}
document.getElementById('out').innerHTML = marked.parse(src)
document.querySelectorAll('code.language-mermaid').forEach(code => {
  const pre = document.createElement('pre'); pre.className = 'mermaid'; pre.textContent = code.textContent
  code.parentElement.replaceWith(pre)
})
mermaid.initialize({ startOnLoad: false }); mermaid.run()
</script>`
}

export function urlCandidates(text: string): string[] {
  return [...text.matchAll(/https?:\/\/[^\s)<>\]"'`]+/g)].map(match => match[0].replace(/[.,;:!?]+$/, ''))
}

const STOP_WORDS = new Set(
  'a an the that this those these me my show open view see peek at of for to in on file doc docs document one it please last new'.split(' '),
)

const KIND_WORDS: Record<string, readonly string[]> = {
  diagram: ['mmd', 'mermaid', 'svg', 'excalidraw', 'drawio', 'png'],
  image: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'heic'],
  picture: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'heic'],
  screenshot: ['png', 'jpg', 'jpeg'],
  plan: ['md'],
  page: ['html', 'htm'],
  html: ['html', 'htm'],
}

function hrefWords(href: string): string {
  const path = parseHref(href)?.path ?? href
  return path.toLowerCase().replace(/[^a-z0-9]+/g, ' ')
}

// Scores each recent href against the loose words of a request. Newer hrefs
// break ties, so "that doc" with nothing else to go on picks the latest.
export function rankRecent(query: string, recent: readonly string[]): { href: string; score: number }[] {
  const words = query.toLowerCase().split(/[^a-z0-9]+/).filter(word => word && !STOP_WORDS.has(word))
  return recent
    .map((href, index) => {
      const haystack = hrefWords(href)
      const name = haystack.split(' ').filter(Boolean).slice(-2).join(' ')
      const ext = extOf(parseHref(href)?.path ?? href)
      let score = 0
      for (const word of words) {
        const kinds = KIND_WORDS[word]
        if (kinds?.includes(ext)) score += 2
        else if (name.includes(word)) score += 3
        else if (haystack.includes(word)) score += 1
      }
      return { href, score: score + index / 1000 }
    })
    .sort((a, b) => b.score - a.score)
}

export function hasMeaningfulWords(query: string): boolean {
  return query.toLowerCase().split(/[^a-z0-9]+/).some(word => word && !STOP_WORDS.has(word))
}

const MERMAID_FENCE = /^([ \t]*)(```|~~~)mermaid[^\n]*\n([\s\S]*?)\n\1\2[ \t]*$/gm

export function mermaidFences(text: string): string[] {
  return [...text.matchAll(MERMAID_FENCE)].map(match => match[3] ?? '')
}

// `drawn` lines up with mermaidFences(text); a null entry keeps that fence as source.
export function diagramType(source: string): string {
  const first = source.trim().split(/\s+/)[0] ?? ''
  if (/^(graph|flowchart)$/i.test(first)) return 'flowchart'
  if (/^sequenceDiagram$/i.test(first)) return 'sequence'
  return first.replace(/Diagram$/, '') || 'diagram'
}

// A drawn diagram becomes a `peek-diagram <type>` fence so the page can frame it
// as a diagram; one that cannot be drawn keeps its mermaid fence.
export function swapMermaidFences(text: string, drawn: readonly (string | null)[]): string {
  let index = 0
  return text.replace(MERMAID_FENCE, (whole, _indent: string, _fence: string, source: string) => {
    const art = drawn[index++]
    if (!art) return whole
    return `\`\`\`peek-diagram ${diagramType(source)}\n${art.replace(/\s+$/, '')}\n\`\`\``
  })
}

export type Outline = { level: number; text: string; offset: number }[]

export function outlineOf(markdown: string): Outline {
  const found: Outline = []
  let inFence = false
  let offset = 0
  for (const line of markdown.split('\n')) {
    if (/^\s*(```|~~~)/.test(line)) inFence = !inFence
    const match = inFence ? null : /^(#{1,4})\s+(.+?)\s*#*\s*$/.exec(line)
    if (match?.[1] && match[2]) found.push({ level: match[1].length, text: match[2], offset })
    offset += line.length + 1
  }
  return found
}

const KIND_LABELS: Record<string, { glyph: string; label: string }> = {
  markdown: { glyph: '¶', label: 'Markdown' },
  text: { glyph: '‹›', label: 'Code' },
  mermaid: { glyph: '◇', label: 'Diagram' },
  image: { glyph: '▣', label: 'Image' },
  svg: { glyph: '▣', label: 'SVG' },
  html: { glyph: '◎', label: 'HTML' },
  folder: { glyph: '▸', label: 'Folder' },
  web: { glyph: '◎', label: 'Web page' },
}

export function kindLabel(kind: string | undefined): { glyph: string; label: string } {
  return KIND_LABELS[kind ?? ''] ?? { glyph: '·', label: 'File' }
}

export type MentionEntry = { href: string; at: number; count: number; isArtifact?: boolean }

// An artifact stays an artifact: a later read of the same file never demotes it.
export function noteMentions(
  list: readonly MentionEntry[],
  hrefs: readonly string[],
  at: number,
  cap = 200,
  isArtifact = false,
): MentionEntry[] {
  const byHref = new Map(list.map(one => [one.href, one]))
  for (const href of hrefs) {
    const before = byHref.get(href)
    byHref.delete(href)
    byHref.set(href, { href, at, count: (before?.count ?? 0) + 1, isArtifact: isArtifact || before?.isArtifact === true })
  }
  return [...byHref.values()].slice(-cap)
}

const TASK = /^(\s*[-*+]\s+)\[( |x|X)\]\s+(.*)$/
const IMAGE_LINE = /^\s*!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)\s*$/

// Task lines become a checkbox glyph linked to `<base>#task-<line>` so a press
// can find and flip that exact source line.
export function linkTasks(text: string, base: string): { text: string; done: number; total: number } {
  let done = 0
  let total = 0
  let inFence = false
  const lines = text.split('\n').map((line, index) => {
    if (/^\s*(```|~~~)/.test(line)) inFence = !inFence
    const match = inFence ? null : TASK.exec(line)
    if (!match) return line
    total += 1
    const isDone = match[2] !== ' '
    if (isDone) done += 1
    const box = isDone ? '\u{f0135}' : '\u{f0131}'
    const label = isDone ? `~~${match[3]}~~` : match[3]
    return `${match[1]}[${box}](${base}#task-${index + 1}) ${label}`
  })
  return { text: lines.join('\n'), done, total }
}

export function toggleTaskLine(text: string, lineNumber: number): string | null {
  const lines = text.split('\n')
  const line = lines[lineNumber - 1]
  const match = line === undefined ? null : TASK.exec(line)
  if (!match || line === undefined) return null
  lines[lineNumber - 1] = line.replace(/\[( |x|X)\]/, match[2] === ' ' ? '[x]' : '[ ]')
  return lines.join('\n')
}

export type TaskItem = { href: string; line: number; isDone: boolean; text: string; depth: number }

const LINKED_TASK = /^(\s*)[-*+]\s+\[([^\]]*)\]\(([^)#]*)#task-(\d+)\)\s?(.*)$/

export type DocPart =
  | { kind: 'markdown'; text: string }
  | { kind: 'code'; lang: string; info: string; text: string }
  | { kind: 'image'; alt: string; src: string }
  | { kind: 'heading'; level: number; text: string }
  | { kind: 'quote'; text: string }
  | { kind: 'tasks'; items: TaskItem[] }

export function plainInline(text: string): string {
  return text
    .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/(\*\*|__|\*|_|~~|`)(.+?)\1/g, '$2')
}

export function segmentsOf(page: string): DocPart[] {
  const out: DocPart[] = []
  let buffer: string[] = []
  let quote: string[] = []
  let tasks: TaskItem[] = []
  let inFence = false
  const flush = () => {
    if (buffer.join('').trim()) out.push({ kind: 'markdown', text: buffer.join('\n') })
    buffer = []
  }
  const flushQuote = () => {
    if (quote.length) out.push({ kind: 'quote', text: quote.join('\n') })
    quote = []
  }
  const flushTasks = () => {
    if (tasks.length) out.push({ kind: 'tasks', items: tasks })
    tasks = []
  }
  let code: { lang: string; info: string; lines: string[] } | null = null
  for (const line of page.split('\n')) {
    const fence = /^\s*(```|~~~)\s*([\w+#.-]*)\s*(.*)$/.exec(line)
    if (code) {
      if (fence && !fence[2]) {
        out.push({ kind: 'code', lang: code.lang, info: code.info, text: code.lines.join('\n') })
        code = null
      } else {
        code.lines.push(line)
      }
      continue
    }
    if (fence) {
      flush()
      flushQuote()
      flushTasks()
      code = { lang: fence[2] ?? '', info: fence[3] ?? '', lines: [] }
      continue
    }
    const task = LINKED_TASK.exec(line)
    if (task) {
      flush()
      flushQuote()
      const text = task[5] ?? ''
      const isDone = /^~~[\s\S]*~~$/.test(text)
      tasks.push({
        href: task[3] ?? '',
        line: Number(task[4]),
        isDone,
        text: isDone ? text.slice(2, -2) : text,
        depth: Math.floor((task[1] ?? '').replace(/\t/g, '  ').length / 2),
      })
      continue
    }
    if (tasks.length && line.trim() === '') {
      flushTasks()
      continue
    }
    flushTasks()
    const quoted = inFence ? null : /^\s*>\s?(.*)$/.exec(line)
    if (quoted) {
      flush()
      quote.push(quoted[1] ?? '')
      continue
    }
    flushQuote()
    const image = inFence ? null : IMAGE_LINE.exec(line)
    const heading = inFence ? null : /^(#{1,6})\s+(.+?)\s*#*\s*$/.exec(line)
    if (image) {
      flush()
      out.push({ kind: 'image', alt: image[1] ?? '', src: image[2] ?? '' })
    } else if (heading) {
      flush()
      out.push({ kind: 'heading', level: heading[1]?.length ?? 1, text: plainInline(heading[2] ?? '') })
    } else {
      buffer.push(line)
    }
  }
  flush()
  flushQuote()
  flushTasks()
  if (code) out.push({ kind: 'code', lang: code.lang, info: code.info, text: code.lines.join('\n') })
  return out
}

export type Scope = 'session' | 'worktree' | 'repo'
export type GalleryType = 'all' | 'markdown' | 'code' | 'data' | 'image' | 'diagram' | 'html'
export type GallerySort = 'recent' | 'name' | 'size' | 'mentions'

export type FileEntry = {
  href: string
  path: string
  name: string
  folder: string
  kind: string
  mtimeMs: number
  size: number
  mentions: number
  mentionedAt: number
  worktree?: string
  role?: 'artifact' | 'touched'
  status?: string
  favicon?: string
}

export type RoleFilter = 'all' | 'artifacts' | 'touched'

export function filterRole(entries: readonly FileEntry[], filter: RoleFilter): FileEntry[] {
  if (filter === 'all') return [...entries]
  const wanted = filter === 'artifacts' ? 'artifact' : 'touched'
  return entries.filter(one => one.role === wanted)
}

const VIEWABLE = new RegExp(`\\.(?:${PATH_EXTS})$`, 'i')

export function isViewable(path: string): boolean {
  return VIEWABLE.test(path)
}

export function typeOf(kind: string): GalleryType {
  if (kind === 'markdown') return 'markdown'
  if (kind === 'image' || kind === 'svg') return 'image'
  if (kind === 'mermaid') return 'diagram'
  if (kind === 'html' || kind === 'web' || familyOf(kind) !== 'web') return 'html'
  if (kind === 'json' || kind === 'toml' || kind === 'csv') return 'data'
  return 'code'
}

// `stat -f '%m %z %N'` lines (mtime seconds, size bytes, path relative to root).
export function parseStatLines(out: string, root: string, worktree?: string): FileEntry[] {
  const entries: FileEntry[] = []
  for (const line of out.split('\n')) {
    const match = /^(\d+) (\d+) (.+)$/.exec(line.trim())
    if (!match?.[3] || !isViewable(match[3])) continue
    const rel = match[3].replace(/^\.\//, '')
    const name = rel.split('/').pop() ?? rel
    const path = `${root}/${rel}`
    entries.push({
      href: fileHref(path),
      path,
      name,
      folder: rel.slice(0, Math.max(0, rel.length - name.length - 1)),
      kind: kindOf(path),
      mtimeMs: Number(match[1]) * 1000,
      size: Number(match[2]),
      mentions: 0,
      mentionedAt: 0,
      worktree,
    })
  }
  return entries
}

export function selectEntries(
  entries: readonly FileEntry[],
  type: GalleryType,
  query: string,
  sort: GallerySort,
): FileEntry[] {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean)
  const kept = entries.filter(one => {
    if (type !== 'all' && typeOf(one.kind) !== type) return false
    const haystack = `${one.folder}/${one.name} ${one.worktree ?? ''}`.toLowerCase()
    return words.every(word => haystack.includes(word))
  })
  const when = (one: FileEntry) => Math.max(one.mentionedAt, one.mtimeMs)
  const order: Record<GallerySort, (a: FileEntry, b: FileEntry) => number> = {
    recent: (a, b) => when(b) - when(a),
    name: (a, b) => a.name.localeCompare(b.name) || a.folder.localeCompare(b.folder),
    size: (a, b) => b.size - a.size,
    mentions: (a, b) => b.mentions - a.mentions || when(b) - when(a),
  }
  return [...kept].sort(order[sort])
}

export function nextOf<T>(list: readonly T[], current: T): T {
  const at = list.indexOf(current)
  return list[(at + 1) % list.length] ?? current
}

export function gridColumns(width: number, minCard = 26, gap = 1): number {
  return Math.max(1, Math.floor((width + gap) / (minCard + gap)))
}

const FILE_FIELDS = ['file_path', 'path', 'notebook_path']

// Sorts one assistant row into what it showed or made (reply text, Write) and
// what it only worked on (every other tool's file inputs).
export function classifyBlocks(content: readonly { type: string; [field: string]: unknown }[]) {
  const texts: string[] = []
  const created: string[] = []
  const touched: string[] = []
  for (const block of content) {
    if (block.type === 'text' && typeof block.text === 'string') texts.push(block.text)
    if (block.type === 'tool_use' && block.input && typeof block.input === 'object') {
      const input = block.input as Record<string, unknown>
      const bucket = block.name === 'Write' ? created : touched
      for (const field of FILE_FIELDS) {
        const value = input[field]
        if (typeof value === 'string') bucket.push(value)
      }
    }
  }
  return { texts, created, touched }
}

export function toggleStar(stars: readonly string[], href: string, wanted?: boolean): string[] {
  const isOn = stars.includes(href)
  const next = wanted ?? !isOn
  if (next === isOn) return [...stars]
  return next ? [...stars, href] : stars.filter(one => one !== href)
}
