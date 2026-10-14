import type { PropValue } from '../types'

export type FrontmatterProblem = { kind: 'unterminated' | 'tab' | 'too-deep' | 'unsupported' | 'duplicate'; line: number; message: string }
type Parsed = PropValue | Parsed[] | { [key: string]: Parsed }

export type Frontmatter = { props?: Record<string, PropValue>; body: string; problems: FrontmatterProblem[]; bodyStartLine: number }

const MAX_PROBLEMS = 50
const UNSAFE = /[\u0000-\u0008\u000B-\u001F\u007F-\u009F\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]/g
const LINE_BREAKS = /[\t\n\r\u2028\u2029]/g
const cleanLine = (raw: string): string => raw.replace(LINE_BREAKS, ' ').replace(UNSAFE, '')

const KEY_LINE = /^([A-Za-z_][\w.-]*)\s*:(?:\s+(.*))?$/
const ITEM_LINE = /^-(?:\s+(.*))?$/
const NUMBER = /^-?\d+(\.\d+)?$/
// Plain scalars may not start with these: they open YAML features the reader does not cover.
const RESERVED_START = /^[&*!|>%@`?]/

type Sink = FrontmatterProblem[]
type Line = { at: number; indent: number; text: string }

function report(sink: Sink, kind: FrontmatterProblem['kind'], line: number, message: string): void {
  if (sink.length < MAX_PROBLEMS) sink.push({ kind, line, message })
}

class FlowError extends Error {
  constructor(readonly kind: 'too-deep' | 'unsupported', message: string) {
    super(message)
  }
}

function withoutComment(text: string): string {
  let quote: string | null = null
  for (let i = 0; i < text.length; i++) {
    const char = text[i]
    if (quote) {
      if (char === quote) quote = null
    } else if (char === '"' || char === "'") {
      quote = char
    } else if (char === '#' && (i === 0 || /\s/.test(text[i - 1] ?? ''))) {
      return text.slice(0, i).trimEnd()
    }
  }
  return text.trimEnd()
}

function quoted(text: string): { value: string; rest: string } {
  const mark = text[0]
  let value = ''
  for (let i = 1; i < text.length; i++) {
    const char = text[i]
    if (mark === "'" && char === "'") {
      if (text[i + 1] === "'") {
        value += "'"
        i++
        continue
      }
      return { value: cleanLine(value), rest: text.slice(i + 1) }
    }
    if (mark === '"' && char === '\\') {
      const next = text[i + 1] ?? ''
      value += next === 'n' ? '\n' : next === 't' ? '\t' : next
      i++
      continue
    }
    if (mark === '"' && char === '"') return { value: cleanLine(value), rest: text.slice(i + 1) }
    value += char
  }
  throw new FlowError('unsupported', 'a quoted string is never closed')
}

function plain(raw: string): Parsed {
  const text = raw.trim()
  if (text === '' || text === 'null' || text === '~') return null
  if (text === 'true') return true
  if (text === 'false') return false
  if (NUMBER.test(text)) return Number(text)
  if (RESERVED_START.test(text)) throw new FlowError('unsupported', `a value starting with "${text[0]}" is a YAML feature peek does not read`)
  return cleanLine(text)
}

// A one-line value may be a list of scalars or a map whose values are scalars or lists of scalars.
type Nesting = 'any' | 'list' | 'none'

function flowValue(text: string, stop: string, nesting: Nesting): { value: Parsed; rest: string } {
  const start = text.trimStart()
  const opener = start[0]
  if (opener === '[' || opener === '{') {
    if (nesting === 'none' || (nesting === 'list' && opener === '{')) {
      throw new FlowError('too-deep', 'a one-line list or map nests deeper than a map holding lists')
    }
    return opener === '[' ? flowList(start.slice(1)) : flowMap(start.slice(1))
  }
  if (opener === '"' || opener === "'") return quoted(start)
  let end = 0
  while (end < start.length && !stop.includes(start[end] ?? '')) end++
  return { value: plain(start.slice(0, end)), rest: start.slice(end) }
}

function flowList(text: string): { value: Parsed[]; rest: string } {
  const items: Parsed[] = []
  let rest = text.trimStart()
  if (rest.startsWith(']')) return { value: items, rest: rest.slice(1) }
  for (;;) {
    const one = flowValue(rest, ',]', 'none')
    items.push(one.value)
    rest = one.rest.trimStart()
    if (rest.startsWith(',')) rest = rest.slice(1)
    else if (rest.startsWith(']')) return { value: items, rest: rest.slice(1) }
    else throw new FlowError('unsupported', 'a one-line list is never closed with ]')
  }
}

function flowMap(text: string): { value: Record<string, Parsed>; rest: string } {
  const map: Record<string, Parsed> = {}
  let rest = text.trimStart()
  if (rest.startsWith('}')) return { value: map, rest: rest.slice(1) }
  for (;;) {
    const key = /^([A-Za-z_][\w.-]*)\s*:/.exec(rest)
    if (!key?.[1] || key[1] === '__proto__') throw new FlowError('unsupported', 'a one-line map entry is not "key: value"')
    if (Object.hasOwn(map, key[1])) throw new FlowError('unsupported', `a one-line map names "${key[1]}" twice`)
    const one = flowValue(rest.slice(key[0].length), ',}', 'list')
    map[key[1]] = one.value
    rest = one.rest.trimStart()
    if (rest.startsWith(',')) rest = rest.slice(1).trimStart()
    else if (rest.startsWith('}')) return { value: map, rest: rest.slice(1) }
    else throw new FlowError('unsupported', 'a one-line map is never closed with }')
  }
}

function inlineValue(sink: Sink, text: string, at: number, nesting: Nesting): Parsed | undefined {
  try {
    const { value, rest } = flowValue(text, '', nesting)
    if (rest.trim()) throw new FlowError('unsupported', 'text follows the value')
    return value
  } catch (error) {
    if (!(error instanceof FlowError)) throw error
    report(sink, error.kind, at, `line ${at}: ${error.message}`)
    return undefined
  }
}

function childrenOf(lines: Line[], from: number, indent: number): number {
  let end = from
  while (end < lines.length && (lines[end]?.indent ?? 0) > indent) end++
  return end
}

// level 1 is the top map; level 2 is a map under one of its keys. A block map below that is too deep.
function blockMap(sink: Sink, lines: Line[], level: number): Record<string, Parsed> {
  const map: Record<string, Parsed> = {}
  const indent = lines[0]?.indent ?? 0
  let i = 0
  while (i < lines.length) {
    const line = lines[i] as Line
    const end = childrenOf(lines, i + 1, line.indent)
    const children = lines.slice(i + 1, end)
    i = end
    if (line.indent !== indent) {
      report(sink, 'unsupported', line.at, `line ${line.at} is indented differently from the lines above it`)
      continue
    }
    const key = KEY_LINE.exec(line.text)
    if (!key?.[1] || key[1] === '__proto__') {
      report(sink, 'unsupported', line.at, `line ${line.at} is not "key: value"`)
      continue
    }
    if (Object.hasOwn(map, key[1])) {
      report(sink, 'duplicate', line.at, `line ${line.at} names "${key[1]}" twice`)
      continue
    }
    const value = key[2] === undefined ? blockValue(sink, children, level, line.at) : children.length
      ? (report(sink, 'unsupported', children[0]?.at ?? line.at, `line ${children[0]?.at} is indented under a key that already has a value`), undefined)
      : inlineValue(sink, key[2], line.at, 'any')
    if (value !== undefined) map[key[1]] = value
  }
  return map
}

function blockValue(sink: Sink, children: Line[], level: number, at: number): Parsed | undefined {
  const first = children[0]
  if (!first) return null
  if (ITEM_LINE.test(first.text)) return blockList(sink, children)
  if (level >= 2) {
    report(sink, 'too-deep', first.at, `line ${first.at} nests a map three levels deep; the most is two`)
    return undefined
  }
  if (!KEY_LINE.test(first.text)) {
    report(sink, 'unsupported', first.at, `line ${first.at} under line ${at} is neither a list item nor "key: value"`)
    return undefined
  }
  return blockMap(sink, children, level + 1)
}

function blockList(sink: Sink, lines: Line[]): Parsed[] | undefined {
  const items: Parsed[] = []
  const indent = lines[0]?.indent ?? 0
  let isBroken = false
  for (const line of lines) {
    const item = ITEM_LINE.exec(line.text)
    if (line.indent !== indent || !item) {
      report(sink, 'unsupported', line.at, `line ${line.at} is not a "- item" at the list's indent`)
      isBroken = true
      continue
    }
    const text = item[1] ?? ''
    if (KEY_LINE.test(text) && !/^["'[{]/.test(text)) {
      report(sink, 'unsupported', line.at, `line ${line.at} is a map inside a list, which peek does not read`)
      isBroken = true
      continue
    }
    const value = inlineValue(sink, text, line.at, 'none')
    if (value === undefined) isBroken = true
    else items.push(value)
  }
  return isBroken ? undefined : items
}

export function readFrontmatter(text: string): Frontmatter {
  const all = text.split('\n')
  if (all[0]?.replace(/\r$/, '') !== '---') return { body: text, problems: [], bodyStartLine: 1 }
  const close = all.findIndex((line, index) => index > 0 && line.replace(/\r$/, '') === '---')
  if (close < 0) {
    return { body: text, problems: [{ kind: 'unterminated', line: 1, message: 'the frontmatter block opened on line 1 has no closing ---' }], bodyStartLine: 1 }
  }
  const sink: Sink = []
  const lines: Line[] = []
  all.slice(1, close).forEach((raw, index) => {
    const at = index + 2
    const leading = /^[ \t]*/.exec(raw)?.[0] ?? ''
    if (leading.includes('\t')) {
      report(sink, 'tab', at, `line ${at} is indented with a tab; use spaces`)
      return
    }
    const body = withoutComment(raw.replace(/\r$/, '').slice(leading.length))
    if (body) lines.push({ at, indent: leading.length, text: body })
  })
  const firstIndent = lines[0]?.indent ?? 0
  if (firstIndent > 0) report(sink, 'unsupported', lines[0]?.at ?? 2, `line ${lines[0]?.at} is indented but nothing above it opens a block`)
  const props = firstIndent > 0 ? {} : blockMap(sink, lines, 1)
  // The depth limits above keep every value inside PropValue's shape.
  return { props: props as Record<string, PropValue>, body: all.slice(close + 1).join('\n'), problems: sink, bodyStartLine: close + 2 }
}
