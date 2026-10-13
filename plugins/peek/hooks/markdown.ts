import { PATH_EXTS } from './paths'
import { linkRefs, refHref } from './refs'
import type { RefContext } from './refs'
import { decodeEntities } from './wire'

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
  const text = html
    .replace(/<(script|style|head|noscript)[\s\S]*?<\/\1>/gi, '')
    .replace(/<h([1-6])[^>]*>([\s\S]*?)<\/h\1>/gi, (_, n: string, body: string) => `\n\n${'#'.repeat(Number(n))} ${body}\n\n`)
    .replace(/<a\s[^>]*href="(https?:[^"]+)"[^>]*>([\s\S]*?)<\/a>/gi, '[$2]($1)')
    .replace(/<li[^>]*>/gi, '\n- ')
    .replace(/<(br|\/p|\/div|\/tr|\/ul|\/ol|\/section|\/article)[^>]*>/gi, '\n')
    .replace(/<pre[^>]*>([\s\S]*?)<\/pre>/gi, '\n```\n$1\n```\n')
    .replace(/<[^>]+>/g, '')
  return decodeEntities(text, ['nbsp', 'lt', 'gt', 'quot', '#39', 'amp'])
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

const TASK_OPEN = '\u{f0131}'
const TASK_DONE = '\u{f0135}'
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
    const box = isDone ? TASK_DONE : TASK_OPEN
    const label = isDone ? `~~${match[3]}~~` : match[3]
    return `${match[1]}[${box}](${base}#task-${index + 1}) ${label}`
  })
  return { text: lines.join('\n'), done, total }
}

// For text peek cannot write back to, such as a pull request body: the same
// glyphs as linkTasks, with no link to press.
export function taskGlyphs(text: string): string {
  let inFence = false
  return text
    .split('\n')
    .map(line => {
      if (/^\s*(```|~~~)/.test(line)) inFence = !inFence
      const match = inFence ? null : TASK.exec(line)
      if (!match) return line
      const isDone = match[2] !== ' '
      return `${match[1]}${isDone ? TASK_DONE : TASK_OPEN} ${isDone ? `~~${match[3]}~~` : match[3]}`
    })
    .join('\n')
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
  | { kind: 'table'; header: string[]; align: CellAlign[]; rows: string[][] }

export type CellAlign = 'left' | 'right' | 'center'

const TABLE_RULE = /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/

// A `\|` inside a cell is a literal pipe, not a column break.
function tableCells(line: string): string[] {
  const inner = line.trim().replace(/^\|/, '').replace(/(?<!\\)\|$/, '')
  return inner.split(/(?<!\\)\|/).map(cell => plainInline(cell.trim().replace(/\\\|/g, '|')))
}

function cellAlign(rule: string): CellAlign {
  const cell = rule.trim()
  if (cell.startsWith(':') && cell.endsWith(':')) return 'center'
  return cell.endsWith(':') ? 'right' : 'left'
}

export type TablePart = Extract<DocPart, { kind: 'table' }>

// A table needs a pipe header line directly above a dashed rule with the same
// cell count; it runs until a blank or pipe-less line. Fenced lines never count.
export function splitTables(text: string): ({ kind: 'markdown'; text: string } | TablePart)[] {
  const out: ({ kind: 'markdown'; text: string } | TablePart)[] = []
  let buffer: string[] = []
  let table: TablePart | null = null
  let fence = ''
  const flush = () => {
    if (buffer.join('').trim()) out.push({ kind: 'markdown', text: buffer.join('\n') })
    buffer = []
  }
  for (const line of text.split('\n')) {
    if (table) {
      if (line.includes('|') && line.trim()) {
        const cells = tableCells(line)
        table.rows.push(table.header.map((_, c) => cells[c] ?? ''))
        continue
      }
      out.push(table)
      table = null
    }
    const marker = /^\s*(```|~~~)/.exec(line)?.[1]
    if (marker && (!fence || marker === fence)) fence = fence ? '' : marker
    const header = buffer[buffer.length - 1]
    if (!fence && !marker && header?.includes('|') && line.includes('-') && TABLE_RULE.test(line)) {
      const rule = tableCells(line)
      const names = tableCells(header)
      if (rule.length === names.length) {
        buffer.pop()
        flush()
        table = { kind: 'table', header: names, align: rule.map(cellAlign), rows: [] }
        continue
      }
    }
    buffer.push(line)
  }
  if (table) out.push(table)
  flush()
  return out
}

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
    out.push(...splitTables(buffer.join('\n')))
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
