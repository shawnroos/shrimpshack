import { isPrivateHost } from './web'

import type { Action, Block, BlockType, CardItem, Detail, ListItem, MediaItem, Page, Section, TableRow } from '../types'

export type { Action, Block, BlockType, CardItem, CardsBlock, CopyAction, Detail, FieldsBlock, ListBlock, ListItem, MarkdownBlock, MediaBlock, MediaItem, OpenAction, Page, Section, TableBlock, TableRow } from '../types'

export type Problem = { path: string; message: string }
export type PageCheck = { ok: true; page: Page } | { ok: false; problems: Problem[] }

export type Outline = {
  title: string
  details: number
  sections: { heading?: string; type: BlockType; items: number }[]
  actions: { label: string; kind: 'open' | 'copy' }[]
}

export type RecipeFamily = 'github' | 'linear' | 'slack'
export type RecipeMatch = { host: string; path?: string }
export type ScriptSource = { run: string[]; timeoutSeconds?: number; env?: string[] }
export type McpSource = { mcp: { server: string; tool: string; args?: Record<string, unknown> }; timeoutSeconds?: number }
export type RecipeSource = ScriptSource | McpSource
export type Recipe = {
  id: string
  name: string
  match: RecipeMatch[]
  overrides: RecipeFamily[]
  source: RecipeSource
  refreshMinutes: number
}
export type RecipeCheck = { ok: true; recipe: Recipe; warnings: string[] } | { ok: false; problems: Problem[]; warnings: string[] }

export const PAGE_CAPS = {
  sections: 30,
  items: 200,
  details: 20,
  columns: 12,
  actions: 9,
  title: 200,
  label: 200,
  text: 1000,
  markdown: 100_000,
  url: 2048,
  copy: 500,
  problems: 50,
}

export const RECIPE_CAPS = {
  name: 80,
  match: 20,
  path: 200,
  argv: 20,
  arg: 1000,
  env: 20,
  args: 4000,
  timeoutSeconds: 60,
  defaultTimeoutSeconds: 20,
  minRefreshMinutes: 5,
  maxRefreshMinutes: 1440,
}

export const BLOCK_TYPES: readonly BlockType[] = ['markdown', 'media', 'table', 'cards', 'list', 'fields']
export const RECIPE_FAMILIES: readonly RecipeFamily[] = ['github', 'linear', 'slack']
export const RECIPE_ID = /^[a-z0-9-]{1,40}$/

const BLOCK_KEYS: Record<BlockType, readonly string[]> = {
  markdown: ['type', 'text'],
  media: ['type', 'items'],
  table: ['type', 'columns', 'rows'],
  cards: ['type', 'items'],
  list: ['type', 'items'],
  fields: ['type', 'rows'],
}

// Zero-width joiners (U+200C, U+200D) stay: emoji sequences and some scripts need them.
const UNSAFE = /[\u0000-\u0008\u000B-\u001F\u007F-\u009F\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]/g
const LINE_BREAKS = /[\t\n\r\u2028\u2029]/g
const RUNS_CODE = /\.(?:app|command|terminal|workflow)$/i
const MUTATING = new Set(['create', 'update', 'delete', 'send', 'post', 'set', 'close', 'merge'])
const LABEL = '[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?'
const HOST_PATTERN = new RegExp(`^(?:\\*\\.)?${LABEL}(?:\\.${LABEL})+$`)
const PATH_GLOB = /^\/[A-Za-z0-9\-._~!$&'()+,;=:@%/*]*$/
const ENV_NAME = /^[A-Za-z_][A-Za-z0-9_]*$/
const MCP_SERVER = /^[A-Za-z0-9][A-Za-z0-9 _.-]{0,63}$/
const MCP_TOOL = /^[A-Za-z0-9_.-]{1,64}$/

type Sink = Problem[]

const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === 'object' && value !== null && !Array.isArray(value)

function kindOf(value: unknown): string {
  if (value === null) return 'null'
  if (Array.isArray(value)) return 'a list'
  return typeof value === 'string' ? 'text' : typeof value
}

const join = (path: string, key: string) => (path ? `${path}.${key}` : key)
const at = (path: string, index: number) => `${path}[${index}]`

function report(sink: Sink, path: string, message: string): void {
  if (sink.length < PAGE_CAPS.problems) sink.push({ path: path || '$', message })
}

function record(sink: Sink, raw: unknown, path: string, what: string, keys: readonly string[]): Record<string, unknown> | undefined {
  if (!isRecord(raw)) {
    report(sink, path, `${what} must be an object, got ${kindOf(raw)}`)
    return undefined
  }
  const extra = Object.keys(raw).filter(key => !keys.includes(key))
  for (const key of extra) report(sink, join(path, key), `"${key}" is not part of ${what}; it takes ${keys.join(', ')}`)
  return extra.length > 0 ? undefined : raw
}

function listOf<T>(sink: Sink, raw: unknown, path: string, cap: number, noun: string, each: (one: unknown, path: string) => T | undefined): T[] | undefined {
  if (!Array.isArray(raw)) {
    report(sink, path, `${noun} must be a list, got ${kindOf(raw)}`)
    return undefined
  }
  if (raw.length > cap) {
    report(sink, path, `holds ${raw.length} ${noun}; the most is ${cap}`)
    return undefined
  }
  return raw.map((one, index) => each(one, at(path, index))) as T[]
}

export const cleanText = (raw: string): string => raw.replace(UNSAFE, '')
export const cleanLine = (raw: string): string => cleanText(raw.replace(LINE_BREAKS, ' '))

function text(sink: Sink, raw: unknown, path: string, cap: number, opts: { required?: boolean; multiline?: boolean } = {}): string | undefined {
  if (raw === undefined && !opts.required) return undefined
  if (typeof raw !== 'string') {
    report(sink, path, raw === undefined ? 'is required' : `must be text, got ${kindOf(raw)}`)
    return undefined
  }
  const clean = opts.multiline ? cleanText(raw) : cleanLine(raw)
  if (opts.required && !clean.trim()) {
    report(sink, path, 'must not be empty')
    return undefined
  }
  if (clean.length > cap) {
    report(sink, path, `is ${clean.length} characters; the most is ${cap}`)
    return undefined
  }
  return clean
}

function webProblem(href: string): string | null {
  let url: URL
  try {
    url = new URL(href)
  } catch {
    return 'is neither an http(s) link nor an absolute file path'
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return `uses ${url.protocol}; only http(s) links and absolute file paths are allowed`
  if (isPrivateHost(url.hostname)) return `points at a private host (${url.hostname})`
  return null
}

function fileProblem(path: string): string | null {
  if (path.startsWith('//')) return 'is not an absolute file path'
  for (const segment of path.split('/')) {
    if (segment.startsWith('.')) return `goes through "${segment}"; files inside dot-folders, and dotfiles, cannot be linked`
    if (RUNS_CODE.test(segment)) return `points into "${segment}", which macOS would run`
  }
  return null
}

export function linkProblem(href: string): string | null {
  if (href.length > PAGE_CAPS.url) return `is ${href.length} characters; the most is ${PAGE_CAPS.url}`
  return href.startsWith('/') ? fileProblem(href) : webProblem(href)
}

export function mediaProblem(url: string): string | null {
  if (url.length > PAGE_CAPS.url) return `is ${url.length} characters; the most is ${PAGE_CAPS.url}`
  return url.startsWith('/') ? 'must be an http(s) address, not a file path' : webProblem(url)
}

function href(sink: Sink, raw: unknown, path: string, rule: (value: string) => string | null, required = false): string | undefined {
  const value = text(sink, raw, path, PAGE_CAPS.url, { required })
  if (value === undefined) return undefined
  const problem = rule(value)
  if (problem) {
    report(sink, path, `"${value}" ${problem}`)
    return undefined
  }
  return value
}

const unbracket = (target: string) => (target.startsWith('<') && target.endsWith('>') ? target.slice(1, -1) : target)

// Scans every form the renderer could turn into a link, code spans included: a false alarm costs a recipe edit, a miss costs the trust boundary.
export function markdownLinks(markdown: string): string[] {
  const found = new Set<string>()
  const add = (target: string | undefined) => {
    const value = unbracket((target ?? '').trim())
    if (value) found.add(value)
  }
  for (const match of markdown.matchAll(/\]\(\s*(<[^>\n]*>|[^\s)]+)/g)) add(match[1])
  for (const match of markdown.matchAll(/^\s{0,3}\[[^\]\n]+\]:\s*(<[^>\n]*>|\S+)/gm)) add(match[1])
  for (const match of markdown.matchAll(/<([a-z][a-z0-9+.-]{1,31}:[^\s<>]*)>/gi)) add(match[1])
  for (const match of markdown.matchAll(/\b(?:href|src)\s*=\s*["']?([^"'\s>]+)/gi)) add(match[1])
  for (const match of markdown.matchAll(/\bhttps?:\/\/[^\s<>()[\]"'`]+/gi)) add(match[0])
  return [...found]
}

function markdown(sink: Sink, raw: unknown, path: string): string | undefined {
  const value = text(sink, raw, path, PAGE_CAPS.markdown, { required: true, multiline: true })
  if (value === undefined) return undefined
  const bad = markdownLinks(value).flatMap(link => {
    const problem = linkProblem(link)
    return problem ? [`"${link}" ${problem}`] : []
  })
  if (bad.length > 0) {
    report(sink, path, `has a link outside the link rule: ${bad[0]}${bad.length > 1 ? ` (and ${bad.length - 1} more)` : ''}`)
    return undefined
  }
  return value
}

function optional<K extends string, V>(key: K, value: V | undefined): { [P in K]?: V } {
  return (value === undefined ? {} : { [key]: value }) as { [P in K]?: V }
}

function detail(sink: Sink, raw: unknown, path: string): Detail | undefined {
  const one = record(sink, raw, path, 'a detail row', ['label', 'value'])
  if (!one) return undefined
  const label = text(sink, one.label, join(path, 'label'), PAGE_CAPS.label, { required: true })
  const value = text(sink, one.value, join(path, 'value'), PAGE_CAPS.text, { required: true })
  return label === undefined || value === undefined ? undefined : { label, value }
}

function mediaItem(sink: Sink, raw: unknown, path: string): MediaItem | undefined {
  const one = record(sink, raw, path, 'a media item', ['url', 'alt', 'kind'])
  if (!one) return undefined
  const url = href(sink, one.url, join(path, 'url'), mediaProblem, true)
  const alt = text(sink, one.alt, join(path, 'alt'), PAGE_CAPS.text)
  const kind = one.kind
  if (kind !== 'image' && kind !== 'video') report(sink, join(path, 'kind'), `must be image or video, got ${JSON.stringify(kind) ?? 'nothing'}`)
  if (url === undefined || (kind !== 'image' && kind !== 'video')) return undefined
  return { url, ...optional('alt', alt), kind }
}

function tableRow(sink: Sink, raw: unknown, path: string, columns: number | undefined): TableRow | undefined {
  const one = record(sink, raw, path, 'a table row', ['cells', 'href'])
  if (!one) return undefined
  const cells = listOf(sink, one.cells, join(path, 'cells'), PAGE_CAPS.columns, 'cells', (cell, cellPath) =>
    text(sink, cell, cellPath, PAGE_CAPS.text, { required: false }) ?? (typeof cell === 'string' ? '' : undefined),
  )
  if (cells && columns !== undefined && cells.length !== columns) {
    report(sink, join(path, 'cells'), `has ${cells.length} cells for ${columns} columns`)
  }
  const link = href(sink, one.href, join(path, 'href'), linkProblem)
  if (!cells) return undefined
  return { cells, ...optional('href', link) }
}

function card(sink: Sink, raw: unknown, path: string): CardItem | undefined {
  const one = record(sink, raw, path, 'a card', ['title', 'meta', 'href', 'image'])
  if (!one) return undefined
  const title = text(sink, one.title, join(path, 'title'), PAGE_CAPS.title, { required: true })
  const meta = text(sink, one.meta, join(path, 'meta'), PAGE_CAPS.text)
  const link = href(sink, one.href, join(path, 'href'), linkProblem)
  const image = href(sink, one.image, join(path, 'image'), mediaProblem)
  if (title === undefined) return undefined
  return { title, ...optional('meta', meta), ...optional('href', link), ...optional('image', image) }
}

function listItem(sink: Sink, raw: unknown, path: string): ListItem | undefined {
  const one = record(sink, raw, path, 'a list item', ['title', 'meta', 'href'])
  if (!one) return undefined
  const title = text(sink, one.title, join(path, 'title'), PAGE_CAPS.title, { required: true })
  const meta = text(sink, one.meta, join(path, 'meta'), PAGE_CAPS.text)
  const link = href(sink, one.href, join(path, 'href'), linkProblem)
  if (title === undefined) return undefined
  return { title, ...optional('meta', meta), ...optional('href', link) }
}

function block(sink: Sink, raw: unknown, path: string): Block | undefined {
  if (!isRecord(raw)) {
    report(sink, path, `a block must be an object, got ${kindOf(raw)}`)
    return undefined
  }
  const type = raw.type
  if (typeof type !== 'string' || !(BLOCK_TYPES as readonly string[]).includes(type)) {
    const named = typeof type === 'string' ? `"${type}" is not a block type` : 'a block needs a type'
    report(sink, join(path, 'type'), `${named}; use one of ${BLOCK_TYPES.join(', ')}`)
    return undefined
  }
  const kind = type as BlockType
  const one = record(sink, raw, path, `a ${kind} block`, BLOCK_KEYS[kind])
  if (!one) return undefined
  const { items: cap } = PAGE_CAPS
  switch (kind) {
    case 'markdown': {
      const value = markdown(sink, one.text, join(path, 'text'))
      return value === undefined ? undefined : { type: kind, text: value }
    }
    case 'media': {
      const items = listOf(sink, one.items, join(path, 'items'), cap, 'items', (item, itemPath) => mediaItem(sink, item, itemPath))
      return items && { type: kind, items }
    }
    case 'table': {
      const columns = listOf(sink, one.columns, join(path, 'columns'), PAGE_CAPS.columns, 'columns', (column, columnPath) =>
        text(sink, column, columnPath, PAGE_CAPS.label, { required: true }),
      )
      const rows = listOf(sink, one.rows, join(path, 'rows'), cap, 'rows', (row, rowPath) => tableRow(sink, row, rowPath, columns?.length))
      return columns && rows && { type: kind, columns, rows }
    }
    case 'cards': {
      const items = listOf(sink, one.items, join(path, 'items'), cap, 'items', (item, itemPath) => card(sink, item, itemPath))
      return items && { type: kind, items }
    }
    case 'list': {
      const items = listOf(sink, one.items, join(path, 'items'), cap, 'items', (item, itemPath) => listItem(sink, item, itemPath))
      return items && { type: kind, items }
    }
    case 'fields': {
      const rows = listOf(sink, one.rows, join(path, 'rows'), cap, 'rows', (row, rowPath) => detail(sink, row, rowPath))
      return rows && { type: kind, rows }
    }
  }
}

function section(sink: Sink, raw: unknown, path: string): Section | undefined {
  const one = record(sink, raw, path, 'a section', ['heading', 'block'])
  if (!one) return undefined
  const heading = text(sink, one.heading, join(path, 'heading'), PAGE_CAPS.label)
  const body = block(sink, one.block, join(path, 'block'))
  return body && { ...optional('heading', heading), block: body }
}

function action(sink: Sink, raw: unknown, path: string): Action | undefined {
  const one = record(sink, raw, path, 'an action', ['label', 'open', 'copy'])
  if (!one) return undefined
  const label = text(sink, one.label, join(path, 'label'), PAGE_CAPS.label, { required: true })
  if (('open' in one) === ('copy' in one)) {
    report(sink, path, 'an action either opens a link (open) or copies text (copy), exactly one')
    return undefined
  }
  if ('open' in one) {
    const target = href(sink, one.open, join(path, 'open'), linkProblem, true)
    return label === undefined || target === undefined ? undefined : { label, open: target }
  }
  const copyPath = join(path, 'copy')
  if (typeof one.copy === 'string' && /[\r\n\u2028\u2029]/.test(one.copy)) {
    report(sink, copyPath, 'copy text must be one line')
    return undefined
  }
  const copy = text(sink, one.copy, copyPath, PAGE_CAPS.copy, { required: true })
  return label === undefined || copy === undefined ? undefined : { label, copy }
}

export function validatePage(raw: unknown): PageCheck {
  const sink: Sink = []
  const page = record(sink, raw, '', 'the page', ['title', 'details', 'sections', 'actions'])
  if (!page) return { ok: false, problems: sink }
  const title = text(sink, page.title, 'title', PAGE_CAPS.title, { required: true })
  const details = page.details === undefined ? undefined : listOf(sink, page.details, 'details', PAGE_CAPS.details, 'details', (one, path) => detail(sink, one, path))
  const sections = listOf(sink, page.sections, 'sections', PAGE_CAPS.sections, 'sections', (one, path) => section(sink, one, path))
  const actions = page.actions === undefined ? undefined : listOf(sink, page.actions, 'actions', PAGE_CAPS.actions, 'actions', (one, path) => action(sink, one, path))
  if (sink.length > 0 || title === undefined || !sections) return { ok: false, problems: sink }
  return { ok: true, page: { title, ...optional('details', details), sections, ...optional('actions', actions) } }
}

function itemsOf(body: Block): number {
  switch (body.type) {
    case 'markdown': {
      return body.text.trim() ? 1 : 0
    }
    case 'table':
    case 'fields': {
      return body.rows.length
    }
    default: {
      return body.items.length
    }
  }
}

export function outlineOf(page: Page): Outline {
  return {
    title: page.title,
    details: page.details?.length ?? 0,
    sections: page.sections.map(one => ({ ...optional('heading', one.heading), type: one.block.type, items: itemsOf(one.block) })),
    actions: (page.actions ?? []).map(one => ({ label: one.label, kind: 'open' in one ? 'open' : 'copy' })),
  }
}

function mutatingWord(tool: string): string | undefined {
  const words = tool
    .replaceAll(/([a-z0-9])([A-Z])/g, '$1 $2')
    .toLowerCase()
    .split(/[^a-z0-9]+/)
  return words.find(word => MUTATING.has(word))
}

function integer(sink: Sink, raw: unknown, path: string, ok: (value: number) => boolean, rule: string): number | undefined {
  if (raw === undefined) return undefined
  if (typeof raw !== 'number' || !Number.isInteger(raw) || !ok(raw)) {
    report(sink, path, `must be ${rule}, got ${JSON.stringify(raw)}`)
    return undefined
  }
  return raw
}

function matchEntry(sink: Sink, raw: unknown, path: string): RecipeMatch | undefined {
  const one = record(sink, raw, path, 'a match entry', ['host', 'path'])
  if (!one) return undefined
  const host = typeof one.host === 'string' ? one.host.toLowerCase() : undefined
  if (host === undefined || !HOST_PATTERN.test(host)) {
    report(sink, join(path, 'host'), `${JSON.stringify(one.host) ?? 'nothing'} is not a host; use a name such as figma.com or *.figma.com`)
  }
  const glob = one.path
  if (glob !== undefined && (typeof glob !== 'string' || glob.length > RECIPE_CAPS.path || !PATH_GLOB.test(glob))) {
    report(sink, join(path, 'path'), `${JSON.stringify(glob)} is not a path glob; start with / and use only * as a wildcard`)
  }
  if (host === undefined || !HOST_PATTERN.test(host) || (glob !== undefined && typeof glob !== 'string')) return undefined
  return { host, ...optional('path', glob as string | undefined) }
}

function scriptArg(sink: Sink, raw: unknown, path: string, first: boolean): string | undefined {
  if (typeof raw !== 'string' || !raw || raw.length > RECIPE_CAPS.arg || /[\u0000-\u001F\u007F]/.test(raw)) {
    report(sink, path, 'must be non-empty text without control characters')
    return undefined
  }
  if (first && (!raw.startsWith('./') || raw.split('/').includes('..'))) {
    report(sink, path, `"${raw}" must name a script inside the recipe folder, as ./name; run interpreters through the script's #! line`)
    return undefined
  }
  return raw
}

function source(sink: Sink, raw: unknown, warnings: string[]): RecipeSource | undefined {
  const one = record(sink, raw, 'source', 'the source', ['run', 'mcp', 'timeoutSeconds', 'env'])
  if (!one) return undefined
  if (('run' in one) === ('mcp' in one)) {
    report(sink, 'source', 'a source names exactly one of run (a script) or mcp (a tool)')
    return undefined
  }
  const timeoutSeconds = integer(sink, one.timeoutSeconds, 'source.timeoutSeconds', value => value >= 1 && value <= RECIPE_CAPS.timeoutSeconds, `whole seconds from 1 to ${RECIPE_CAPS.timeoutSeconds}`)
  const timeout = optional('timeoutSeconds', timeoutSeconds)
  if ('run' in one) {
    const run = listOf(sink, one.run, 'source.run', RECIPE_CAPS.argv, 'arguments', (arg, path) => scriptArg(sink, arg, path, path === 'source.run[0]'))
    if (run && run.length === 0) report(sink, 'source.run', 'needs the script to run')
    const env =
      one.env === undefined
        ? undefined
        : listOf(sink, one.env, 'source.env', RECIPE_CAPS.env, 'names', (name, path) => {
            if (typeof name === 'string' && ENV_NAME.test(name)) return name
            report(sink, path, `${JSON.stringify(name)} is not an environment variable name`)
            return undefined
          })
    return run && { run, ...timeout, ...optional('env', env) }
  }
  if ('env' in one) {
    report(sink, 'source.env', 'env applies only to a script source; an MCP tool gets no environment')
    return undefined
  }
  const mcp = record(sink, one.mcp, 'source.mcp', 'the mcp source', ['server', 'tool', 'args'])
  if (!mcp) return undefined
  const server = mcp.server
  const tool = mcp.tool
  if (typeof server !== 'string' || !MCP_SERVER.test(server)) report(sink, 'source.mcp.server', `${JSON.stringify(server) ?? 'nothing'} is not an MCP server name`)
  if (typeof tool !== 'string' || !MCP_TOOL.test(tool)) report(sink, 'source.mcp.tool', `${JSON.stringify(tool) ?? 'nothing'} is not an MCP tool name`)
  const args = mcp.args
  if (args !== undefined && (!isRecord(args) || JSON.stringify(args).length > RECIPE_CAPS.args)) {
    report(sink, 'source.mcp.args', `must be an object of at most ${RECIPE_CAPS.args} characters as JSON`)
    return undefined
  }
  if (typeof server !== 'string' || !MCP_SERVER.test(server) || typeof tool !== 'string' || !MCP_TOOL.test(tool)) return undefined
  const word = mutatingWord(tool)
  if (word) warnings.push(`The MCP tool "${tool}" looks like it changes something ("${word}"); a recipe should only read`)
  return { mcp: { server, tool, ...optional('args', args) }, ...timeout }
}

export function validateRecipe(id: string, raw: unknown): RecipeCheck {
  const sink: Sink = []
  const warnings: string[] = []
  if (!RECIPE_ID.test(id)) report(sink, 'id', `"${id}" is not a recipe id; use 1 to 40 of a-z, 0-9 and -`)
  const one = record(sink, raw, '', 'a recipe', ['name', 'match', 'overrides', 'source', 'refreshMinutes'])
  if (!one) return { ok: false, problems: sink, warnings }
  const name = text(sink, one.name, 'name', RECIPE_CAPS.name, { required: true })
  const match = listOf(sink, one.match, 'match', RECIPE_CAPS.match, 'match entries', (entry, path) => matchEntry(sink, entry, path))
  if (match && match.length === 0) report(sink, 'match', 'needs at least one host to match')
  const overrides =
    one.overrides === undefined
      ? []
      : listOf(sink, one.overrides, 'overrides', RECIPE_FAMILIES.length, 'overrides', (family, path) => {
          if (typeof family === 'string' && (RECIPE_FAMILIES as readonly string[]).includes(family)) return family as RecipeFamily
          report(sink, path, `${JSON.stringify(family)} is not a built-in page type; use one of ${RECIPE_FAMILIES.join(', ')}`)
          return undefined
        })
  const body = source(sink, one.source, warnings)
  const refreshMinutes = integer(
    sink,
    one.refreshMinutes,
    'refreshMinutes',
    value => value === 0 || (value >= RECIPE_CAPS.minRefreshMinutes && value <= RECIPE_CAPS.maxRefreshMinutes),
    `0, or whole minutes from ${RECIPE_CAPS.minRefreshMinutes} to ${RECIPE_CAPS.maxRefreshMinutes}`,
  )
  if (sink.length > 0 || name === undefined || !match || !overrides || !body) return { ok: false, problems: sink, warnings }
  return { ok: true, recipe: { id, name, match, overrides, source: body, refreshMinutes: refreshMinutes ?? 0 }, warnings }
}
