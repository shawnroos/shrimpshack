export type Kind = 'markdown' | 'image' | 'svg' | 'html' | 'mermaid' | 'json' | 'toml' | 'csv' | 'text'

const IMAGE_EXTS = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'heic', 'tif', 'tiff', 'bmp']
const MARKDOWN_EXTS = ['md', 'markdown', 'mdx']
const PATH_EXTS =
  'md|markdown|mdx|txt|png|jpe?g|gif|webp|heic|tiff?|bmp|svg|html?|mmd|mermaid|json|ya?ml|toml|ts|tsx|js|jsx|mjs|py|rs|go|sh|css|sql|csv|tsv|log'

// The negative lookbehind keeps a path inside a URL or a word from matching.
const BARE_PATH = new RegExp(
  `(?<![\\w/.:~-])((?:~|\\.{1,2})?/?(?:[\\w.@-]+/)*[\\w.@-]+\\.(?:${PATH_EXTS}))(?::(\\d+))?(?![\\w/])`,
  'gi',
)
const CODE_SPAN = /`([^`\n]+)`/g
const MD_LINK = /\[[^\]\n]*\]\([^)\n]*\)/g

export function extOf(path: string): string {
  const name = path.split('/').pop() ?? ''
  const dot = name.lastIndexOf('.')
  return dot > 0 ? name.slice(dot + 1).toLowerCase() : ''
}

export function kindOf(path: string): Kind {
  const ext = extOf(path)
  if (MARKDOWN_EXTS.includes(ext)) return 'markdown'
  if (IMAGE_EXTS.includes(ext)) return 'image'
  if (ext === 'svg') return 'svg'
  if (ext === 'html' || ext === 'htm') return 'html'
  if (ext === 'mmd' || ext === 'mermaid') return 'mermaid'
  if (ext === 'json' || ext === 'jsonc' || ext === 'json5') return 'json'
  if (ext === 'toml') return 'toml'
  if (ext === 'csv' || ext === 'tsv') return 'csv'
  return 'text'
}

export function resolvePath(raw: string, cwd: string, home: string): string {
  if (raw.startsWith('~/')) return `${home}${raw.slice(1)}`
  const joined = raw.startsWith('/') ? raw : `${cwd}/${raw}`
  const out: string[] = []
  for (const part of joined.split('/')) {
    if (part === '' || part === '.') continue
    if (part === '..') out.pop()
    else out.push(part)
  }
  return `/${out.join('/')}`
}

export function fileHref(abs: string, line?: number): string {
  return `file://${encodeURI(abs).replace(/[#?]/g, encodeURIComponent)}${line ? `#L${line}` : ''}`
}

export function parseHref(href: string): { path: string; line?: number } | null {
  if (!href.startsWith('file:')) return null
  const url = new URL(href)
  const match = /^#L(\d+)$/.exec(url.hash)
  return { path: decodeURIComponent(url.pathname), line: match ? Number(match[1]) : undefined }
}

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

export function linkify(text: string, hrefFor: (raw: string, line?: number) => string | null): string {
  return splitFences(text)
    .map(fence => {
      if (!fence.isProse) return fence.text
      return splitPattern(fence.text, MD_LINK)
        .map(part => {
          if (!part.isProse) return part.text
          return splitPattern(part.text, CODE_SPAN)
            .map(code => {
              if (code.isProse) {
                return code.text.replace(BARE_PATH, (whole, raw: string, line?: string) => {
                  const href = hrefFor(raw, line ? Number(line) : undefined)
                  return href ? `[${whole}](${href})` : whole
                })
              }
              const path = splitCodePath(code.text.slice(1, -1))
              const href = path && hrefFor(path.raw, path.line)
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

export function codeWindow(text: string, lang: string, line?: number): string {
  const lines = text.split('\n')
  const start = line ? Math.max(0, line - 11) : 0
  const shown = lines.slice(start, start + 200)
  const width = String(start + shown.length).length
  const body = shown
    .map((one, index) => {
      const number = start + index + 1
      const mark = number === line ? '▶' : ' '
      return `${mark}${String(number).padStart(width)}  ${one}`
    })
    .join('\n')
  return `\`\`\`${lang}\n${body}\n\`\`\``
}

export function imageBox(width: number, height: number, maxColumns: number, maxRows: number) {
  const cellAspect = 2.1
  let columns = Math.max(1, Math.min(255, maxColumns))
  let rows = Math.round((columns * height) / width / cellAspect)
  if (rows > maxRows) {
    rows = maxRows
    columns = Math.max(1, Math.round((rows * width * cellAspect) / height))
  }
  return { columns: Math.min(255, columns), rows: Math.max(1, Math.min(255, rows)) }
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

export function pushRecent(list: readonly string[], hrefs: readonly string[], cap = 60): string[] {
  const next = list.filter(one => !hrefs.includes(one))
  return [...next, ...hrefs].slice(-cap)
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

export function fromSection(markdown: string, index: number): string {
  const heading = outlineOf(markdown)[index]
  return heading ? markdown.slice(heading.offset) : markdown
}

export function describeSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`
}

export function describeAge(thenMs: number, nowMs: number): string {
  const minutes = Math.max(0, Math.round((nowMs - thenMs) / 60000))
  if (minutes < 1) return 'just now'
  if (minutes < 60) return `${minutes}m ago`
  const hours = Math.round(minutes / 60)
  if (hours < 48) return `${hours}h ago`
  return `${Math.round(hours / 24)}d ago`
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

// Raster cells are little-endian u32 triplets: code point, foreground, background.
export function rasterGradient(columns: number, rows: number): string {
  const words = new Uint32Array(columns * rows * 3)
  for (let y = 0; y < rows; y++) {
    for (let x = 0; x < columns; x++) {
      const at = (y * columns + x) * 3
      const red = Math.round((x / Math.max(1, columns - 1)) * 255)
      const blue = Math.round((y / Math.max(1, rows - 1)) * 255)
      const isEdge = y === 0 || y === rows - 1
      words[at] = isEdge ? 0x2580 : 0x2591
      words[at + 1] = (red << 16) | (120 << 8) | blue
      words[at + 2] = ((255 - red) << 16) | (40 << 8) | (255 - blue)
    }
  }
  const bytes = new Uint8Array(words.buffer)
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary)
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

export function pageOf<T>(items: readonly T[], page: number, size: number): { items: T[]; page: number; pages: number } {
  const pages = Math.max(1, Math.ceil(items.length / Math.max(1, size)))
  const clamped = Math.min(Math.max(0, page), pages - 1)
  return { items: items.slice(clamped * size, clamped * size + size), page: clamped, pages }
}

export function shortPath(path: string, cwd: string, home: string): string {
  if (cwd && path.startsWith(`${cwd}/`)) return path.slice(cwd.length + 1)
  if (home && path.startsWith(`${home}/`)) return `~${path.slice(home.length)}`
  return path
}

export const IMAGE_ROWS = 10

function rowsFor(line: string, width: number): number {
  if (/^\s*!\[[^\]]*\]\([^)\s]+(?:\s+"[^"]*")?\)\s*$/.test(line)) return IMAGE_ROWS
  return Math.max(1, Math.ceil(line.length / Math.max(10, width)))
}

// Blocks are paragraphs and whole fenced blocks, so a page break never lands
// inside a fence unless the fence alone is taller than a page.
function markdownBlocks(text: string): string[][] {
  const blocks: string[][] = []
  let current: string[] = []
  let inFence = false
  for (const line of text.split('\n')) {
    const isFence = /^\s*(```|~~~)/.test(line)
    if (!inFence && !isFence && line.trim() === '') {
      if (current.length) blocks.push(current)
      current = []
      continue
    }
    if (!inFence && /^#{1,6}\s/.test(line) && current.length) {
      blocks.push(current)
      current = []
    }
    current.push(line)
    if (isFence) inFence = !inFence
  }
  if (current.length) blocks.push(current)
  return blocks
}

export function paginateMarkdown(text: string, width: number, rows: number): string[] {
  const pages: string[][] = [[]]
  let used = 0
  const startPage = () => {
    pages.push([])
    used = 0
  }
  for (const block of markdownBlocks(text)) {
    const cost = block.reduce((sum, line) => sum + rowsFor(line, width), 0) + 1
    const isHeading = /^#{1,6}\s/.test(block[0] ?? '')
    if (used > 0 && (used + cost > rows || (isHeading && used + Math.min(cost, 4) > rows))) startPage()
    if (cost <= rows) {
      pages[pages.length - 1]?.push(block.join('\n'), '')
      used += cost
      continue
    }
    const fence = /^\s*(```|~~~)(.*)$/.exec(block[0] ?? '')
    let chunk: string[] = []
    let chunkRows = 0
    const flush = (isLast: boolean) => {
      if (!chunk.length) return
      let lines = chunk
      if (fence && lines[0] !== block[0]) lines = [`${fence[1]}${fence[2]}`, ...lines]
      if (fence && !isLast) lines = [...lines, fence[1] ?? '```']
      pages[pages.length - 1]?.push(lines.join('\n'), '')
      chunk = []
      chunkRows = 0
      startPage()
    }
    block.forEach((line, index) => {
      const cost = rowsFor(line, width)
      if (chunkRows + cost > rows - 2) flush(false)
      chunk.push(line)
      chunkRows += cost
      if (index === block.length - 1) {
        let lines = chunk
        if (fence && lines[0] !== block[0]) lines = [`${fence[1]}${fence[2]}`, ...lines]
        pages[pages.length - 1]?.push(lines.join('\n'), '')
        used = chunkRows + 1
        chunk = []
      }
    })
  }
  return pages.map(page => page.join('\n').trimEnd()).filter((page, index, all) => page || all.length === 1)
}

const TASK = /^(\s*[-*+]\s+)\[( |x|X)\]\s+(.*)$/
const IMAGE_LINE = /^\s*!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)\s*$/

export function isImageLine(line: string): boolean {
  return IMAGE_LINE.test(line)
}

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

export function estimateRows(text: string, width: number): number {
  return markdownBlocks(text).reduce((sum, block) => {
    const isTitle = /^#\s/.test(block[0] ?? '')
    const isFence = /^\s*(```|~~~)/.test(block[0] ?? '')
    const lines = block.reduce((rows, line) => rows + rowsFor(line, width), 0)
    return sum + lines + 1 + (isTitle ? 1 : 0) - (isFence ? 1 : 0)
  }, 0)
}

// One Markdown element holds at most 10,000 characters, so a long doc is drawn
// as several, cut between blocks.
export function chunkMarkdown(text: string, maxChars = 9000): string[] {
  const chunks: string[] = []
  let current = ''
  for (const block of markdownBlocks(text)) {
    const piece = block.join('\n')
    if (current && current.length + piece.length + 2 > maxChars) {
      chunks.push(current)
      current = ''
    }
    current = current ? `${current}\n\n${piece}` : piece
  }
  if (current) chunks.push(current)
  return chunks
}

export function headingAtRow(text: string, width: number, row: number): string {
  let used = 0
  let heading = ''
  for (const block of markdownBlocks(text)) {
    if (used > row) break
    const match = /^#{1,6}\s+(.+)$/.exec(block[0] ?? '')
    if (match?.[1]) heading = match[1]
    used += block.reduce((rows, line) => rows + rowsFor(line, width), 0) + 1
  }
  return heading
}

export type TaskRow = { item: number; isFirst: boolean; text: string }

// Rows a task list draws at `width` columns: each task wraps under its own text
// (a hanging indent past depth*2 + the 2-column checkbox).
export function taskRows(items: readonly { text: string; depth: number }[], width: number): TaskRow[] {
  const rows: TaskRow[] = []
  items.forEach((item, index) => {
    const room = Math.max(8, width - item.depth * 2 - 2)
    const lines: string[] = ['']
    for (const word of item.text.split(/\s+/).filter(Boolean)) {
      const current = lines[lines.length - 1] ?? ''
      if (!current) lines[lines.length - 1] = word.slice(0, room)
      else if (current.length + 1 + word.length <= room) lines[lines.length - 1] = `${current} ${word}`
      else lines.push(word.slice(0, room))
    }
    lines.forEach((text, line) => rows.push({ item: index, isFirst: line === 0, text }))
  })
  return rows
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
  if (kind === 'html' || kind === 'web') return 'html'
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

// RFC 4180: quoted fields may hold the delimiter, newlines and doubled quotes.
export function parseDelimited(text: string, delimiter = ','): string[][] {
  const rows: string[][] = []
  let row: string[] = []
  let field = ''
  let isQuoted = false
  for (let i = 0; i < text.length; i++) {
    const char = text[i]
    if (isQuoted) {
      if (char === '"' && text[i + 1] === '"') {
        field += '"'
        i += 1
      } else if (char === '"') {
        isQuoted = false
      } else {
        field += char
      }
      continue
    }
    if (char === '"' && field === '') isQuoted = true
    else if (char === delimiter) {
      row.push(field)
      field = ''
    } else if (char === '\n' || char === '\r') {
      if (char === '\r' && text[i + 1] === '\n') i += 1
      row.push(field)
      rows.push(row)
      row = []
      field = ''
    } else field += char
  }
  if (field !== '' || row.length) {
    row.push(field)
    rows.push(row)
  }
  return rows.filter(one => one.some(cell => cell !== ''))
}

export function columnWidths(rows: readonly (readonly string[])[], width: number, gap = 2): number[] {
  const count = Math.max(0, ...rows.map(row => row.length))
  const natural = Array.from({ length: count }, (_, c) =>
    Math.max(1, ...rows.slice(0, 200).map(row => (row[c] ?? '').length)),
  )
  const room = Math.max(count, width - gap * Math.max(0, count - 1))
  if (natural.reduce((a, b) => a + b, 0) <= room) return natural
  const widths = natural.map(() => 0)
  let left = room
  const order = natural.map((w, c) => ({ w, c })).sort((a, b) => a.w - b.w)
  order.forEach((one, i) => {
    const share = Math.floor(left / (order.length - i))
    const take = Math.max(1, Math.min(one.w, share))
    widths[one.c] = take
    left -= take
  })
  return widths
}

export function fitCell(text: string, width: number): string {
  const flat = text.replace(/\s+/g, ' ')
  if (flat.length <= width) return flat.padEnd(width)
  return `${flat.slice(0, Math.max(0, width - 1))}…`
}

export function jsonSummary(value: unknown): string {
  if (Array.isArray(value)) return `array · ${value.length} items`
  if (value && typeof value === 'object') return `object · ${Object.keys(value).length} keys`
  return typeof value
}

export function prettyJson(text: string): { text: string; summary: string } | { error: string } {
  try {
    const value: unknown = JSON.parse(text)
    return { text: JSON.stringify(value, null, 2), summary: jsonSummary(value) }
  } catch (error) {
    return { error: error instanceof Error ? error.message : String(error) }
  }
}

export function tomlSections(text: string): number {
  return text.split('\n').filter(line => /^\s*\[{1,2}[^\]]+\]{1,2}\s*(#.*)?$/.test(line)).length
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

// Starred first; the order inside each group is the order given.
export function starredFirst<T extends { href: string }>(entries: readonly T[], stars: readonly string[]): T[] {
  const starred = new Set(stars)
  return [...entries.filter(one => starred.has(one.href)), ...entries.filter(one => !starred.has(one.href))]
}

export function toggleStar(stars: readonly string[], href: string, wanted?: boolean): string[] {
  const isOn = stars.includes(href)
  const next = wanted ?? !isOn
  if (next === isOn) return [...stars]
  return next ? [...stars, href] : stars.filter(one => one !== href)
}
