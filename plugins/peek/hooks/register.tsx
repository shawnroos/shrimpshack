import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Loaded, Mention, Mode, View } from '../types'
import type { FileEntry, GallerySort, GalleryType, RoleFilter, Scope } from './lib'
import { C as BASE, MUTED, ICON, META_ICON, colorFor, iconFor, mute, ruleParts } from './theme'
import { capturedLinearContext, record } from './capture'
import type { CaptureIo } from './capture'
import { familyOf, itemKey, parseRef } from './refs'
import type { Ref, RefContext } from './refs'
import { loadItem } from './remote'
import type { RemoteIo } from './remote'
import { bootstrapLinear } from './linear'
import type { LinearBootstrap } from './linear'
import { failureText } from './sources'
import { IDLE_MS, cached, isCurrent, isTimed, refreshItem, tick, titleOf, withTitle } from './refresh'
import type { CacheEntry, TitleEntry } from './refresh'
import {
  describeAge,
  describeSize,
  extOf,
  fileHref,
  fitMarkdown,
  fromSection,
  hasMeaningfulWords,
  htmlToMarkdown,
  imageBox,
  kindLabel,
  IMAGE_ROWS,
  gridColumns,
  classifyBlocks,
  columnWidths,
  filterRole,
  toggleStar,
  fitCell,
  kindOf,
  linkTasks,
  parseDelimited,
  prettyJson,
  tomlSections,
  nextOf,
  parseStatLines,
  selectEntries,
  linkify,
  markdownPage,
  mermaidFences,
  mermaidPage,
  noteMentions,
  outlineOf,
  chunkMarkdown,
  estimateRows,
  parseHref,
  pathCandidates,
  plainInline,
  fitName,
  pushRecent,
  rankRecent,
  rasterGradient,
  resolvePath,
  segmentsOf,
  shortPath,
  diagramType,
  swapMermaidFences,
  taskRows,
  toggleTaskLine,
  urlCandidates,
} from './lib'

const C = BASE

const PANE = 'peek'
const SCRATCH = '/tmp/claude-peek'
const view = atom({ plugin: 'peek', key: 'view' } as const, null)
const mentions = atom({ plugin: 'peek', key: 'mentions' } as const, [])
const mode = atom({ plugin: 'peek', key: 'mode' } as const, 'view')
const page = atom({ plugin: 'peek', key: 'page' } as const, 0)
const trail = atom({ plugin: 'peek', key: 'trail' } as const, [])
const section = atom({ plugin: 'peek', key: 'section' } as const, -1)
const menuOpen = atom({ plugin: 'peek', key: 'menuOpen' } as const, false)
const menuFilter = atom({ plugin: 'peek', key: 'menuFilter' } as const, '')
const NARROW = 60
const MIN_CPL = 30
const MAX_CPL = 104
const MODES: { id: Mode; label: string; icon: string; hotkey: string }[] = [
  { id: 'view', label: 'Peek', icon: '\u{f06e}', hotkey: 'p' },
  { id: 'recent', label: 'Recent', icon: '\u{f017}', hotkey: 'r' },
  { id: 'gallery', label: 'Gallery', icon: '\u{f0c6c}', hotkey: 'g' },
]
const scopeAtom = atom({ plugin: 'peek', key: 'scope' } as const, 'session')
const galleryType = atom({ plugin: 'peek', key: 'galleryType' } as const, 'all')
const gallerySort = atom({ plugin: 'peek', key: 'gallerySort' } as const, 'recent')
const galleryFilter = atom({ plugin: 'peek', key: 'galleryFilter' } as const, '')
const roleFilter = atom({ plugin: 'peek', key: 'roleFilter' } as const, 'all')
const stars = atom({ plugin: 'peek', key: 'stars' } as const, [])
const cursorAtom = atom({ plugin: 'peek', key: 'cursor' } as const, 0)
type NavItem = { href: string; key: string; line: number; col: number }
let navOrder: NavItem[] = []

type Direction = 'up' | 'down' | 'left' | 'right'

// Up and down keep the column, so a card grid moves like a grid.
function stepFrom(at: number, direction: Direction): number {
  const here = navOrder[at]
  if (!here) return 0
  if (direction === 'left' || direction === 'right') {
    const next = navOrder[at + (direction === 'left' ? -1 : 1)]
    return next && next.line === here.line ? at + (direction === 'left' ? -1 : 1) : at
  }
  const line = here.line + (direction === 'up' ? -1 : 1)
  let best = -1
  navOrder.forEach((one, index) => {
    if (one.line === line && (best < 0 || Math.abs(one.col - here.col) < Math.abs((navOrder[best]?.col ?? 0) - here.col))) best = index
  })
  return best < 0 ? at : best
}

async function moveSelection($: EngineInterface, direction: Direction) {
  let landed = 0
  await update($, cursorAtom, at => {
    landed = stepFrom(Math.max(0, Math.min(navOrder.length - 1, at)), direction)
    return landed
  })
  const key = navOrder[landed]?.key
  // 'nearest' counts a row under the pinned footer as already showing, so the
  // cursor could walk behind it; centring always leaves it in the clear.
  if (key) await $.ui.scroll({ in: PANE, to: { key }, block: 'center' }).catch(() => undefined)
  await $.ui.focus({ requestId: PANE, key: `item-${landed}` }).catch(() => undefined)
}

async function selectAndOpen($: EngineInterface, index: number) {
  await update($, cursorAtom, () => index)
  const href = navOrder[index]?.href
  if (href) await show($, href)
}

async function selectedHref($: EngineInterface): Promise<string | undefined> {
  const at = await read($, cursorAtom)
  return navOrder[Math.max(0, Math.min(navOrder.length - 1, at))]?.href
}

const ROLES: RoleFilter[] = ['all', 'artifacts', 'touched']
const SCOPES: Scope[] = ['session', 'worktree', 'repo']
const TYPES: GalleryType[] = ['all', 'markdown', 'code', 'data', 'image', 'diagram', 'html']
const SORTS: GallerySort[] = ['recent', 'name', 'size', 'mentions']
const SCOPE_ICON: Record<Scope, string> = { session: '\u{f0b79}', worktree: '\u{f418}', repo: '\u{f401}' }
const LIST_CHUNK = 10
const CARD_ROWS = 5
const CARD_MIN = 26
const CARD_GAP = 2
const fullText = new Map<string, string>()
const roots = new Map<string, { root: string; isWorktree: boolean } | null>()
const GALLERY = 'peek-ui'
const presses = atom({ plugin: 'peek', key: 'galleryPresses' } as const, 0)
const typed = atom({ plugin: 'peek', key: 'galleryText' } as const, '')
const picked = atom({ plugin: 'peek', key: 'galleryPick' } as const, 'round')
const BORDERS = ['single', 'double', 'round', 'bold', 'singleDouble', 'doubleSingle', 'classic']
const SAMPLE_RUST = 'fn greet(name: &str) -> String {\n    format!("hello, {name}")\n}\n\nfn main() {\n    println!("{}", greet("peek"));\n}'
const SAMPLE_DIFF = '@@ -1,3 +1,3 @@\n fn main() {\n-    println!("hi");\n+    println!("hello, peek");\n }'
const SAMPLE_MARKDOWN = '## Markdown\n\nRenders **bold**, *italic*, `code`, [links](https://claude.com) and lists:\n\n- one\n- two\n\n| Element | Use |\n|---|---|\n| Box | layout |\n| Text | words |\n\n```ts\nconst peek = true\n```'

const MERMAID_ASCII = '/.cache/claude-peek/bin/mermaid-ascii'
const MAX_PNG_BYTES = 2 * 1024 * 1024

const exists = new Map<string, boolean>()
const pixels = new Map<string, string>()
let paneColumns = 100
let scrollLimit = 0
let contentRows = 0
let blockStarts: number[] = []
let blockHeadings: string[] = []
let estimatedRows = 1
const HEADER_ROWS = 2
const FOOTER_ROWS = 3
const PAGE_TOP = HEADER_ROWS + 1
const converted = new Map<string, { file: string; width: number; height: number }>()

async function pathExists($: EngineInterface, abs: string): Promise<boolean> {
  const known = exists.get(abs)
  if (known !== undefined) return known
  const found = await $.fs.stat(abs).then(
    stat => stat.kind !== 'other',
    () => false,
  )
  exists.set(abs, found)
  return found
}

async function pngSize($: EngineInterface, file: string) {
  const { stdout } = await $.process.run(['sips', '-g', 'pixelWidth', '-g', 'pixelHeight', file])
  const width = Number(/pixelWidth:\s*(\d+)/.exec(stdout)?.[1] ?? 0)
  const height = Number(/pixelHeight:\s*(\d+)/.exec(stdout)?.[1] ?? 0)
  return { width: width || 800, height: height || 600 }
}

async function hashName(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-1', new TextEncoder().encode(text))
  return [...new Uint8Array(digest)].slice(0, 8).map(b => b.toString(16).padStart(2, '0')).join('')
}

async function runOrThrow($: EngineInterface, argv: string[]) {
  const ran = await $.process.run(argv)
  if (ran.exitCode !== 0) throw new Error(ran.stderr.trim() || `${argv[0]} failed`)
}

// The bytes go to the terminal inline: a multiplexer between Claude Code and
// the terminal may pass kitty images sent as data but not ones sent as a path.
async function toPng($: EngineInterface, abs: string, mtimeMs: number) {
  const cacheKey = `${abs}@${mtimeMs}`
  const cached = converted.get(cacheKey)
  if (cached && pixels.has(cached.file)) return cached
  await $.process.run(['mkdir', '-p', SCRATCH])
  const name = await hashName(cacheKey)
  let source = abs
  if (extOf(abs) === 'svg') {
    source = `${SCRATCH}/${name}-svg.png`
    await runOrThrow($, ['rsvg-convert', '-w', '1600', '-o', source, abs])
  }
  const file = `${SCRATCH}/${name}.png`
  for (const edge of [1600, 1000, 600]) {
    await runOrThrow($, ['sips', '-Z', String(edge), '-s', 'format', 'png', source, '--out', file])
    const { base64 } = await $.fs.read(file, { as: 'bytes' })
    if (base64.length * 0.75 <= MAX_PNG_BYTES) {
      pixels.set(file, base64)
      break
    }
  }
  if (!pixels.has(file)) throw new Error('Image is too large to show here. Press "Open externally".')
  const image = { file, ...(await pngSize($, file)) }
  converted.set(cacheKey, image)
  return image
}

async function drawMermaid($: EngineInterface, source: string): Promise<string | null> {
  const home = (await $.env.get('HOME')) ?? ''
  const ran = await $.process
    .run([`${home}${MERMAID_ASCII}`, '-f', '-', '--max-width', String(Math.max(40, paneColumns - 4))], {
      stdin: source,
      timeoutMs: 10000,
    })
    .catch(() => null)
  if (!ran || ran.exitCode !== 0 || !ran.stdout.trim()) return null
  return ran.stdout
}

async function withDrawnMermaid($: EngineInterface, markdown: string): Promise<string> {
  const fences = mermaidFences(markdown)
  if (!fences.length) return markdown
  const drawn: (string | null)[] = []
  for (const fence of fences) drawn.push(await drawMermaid($, fence))
  return swapMermaidFences(markdown, drawn)
}

async function gitRoot($: EngineInterface, folder: string): Promise<{ root: string; isWorktree: boolean } | null> {
  if (roots.has(folder)) return roots.get(folder) ?? null
  const ran = await $.process
    .run(['git', '-C', folder, 'rev-parse', '--path-format=absolute', '--show-toplevel', '--git-dir', '--git-common-dir'])
    .catch(() => null)
  const [root, gitDir, commonDir] = ran && ran.exitCode === 0 ? ran.stdout.trim().split('\n') : []
  const found = root ? { root, isWorktree: Boolean(gitDir && commonDir && gitDir !== commonDir) } : null
  roots.set(folder, found)
  return found
}

async function loadFile($: EngineInterface, href: string, path: string, line?: number): Promise<View> {
  const title = path.split('/').pop() || path
  const folderOf = path.slice(0, Math.max(1, path.length - title.length - 1))
  const git = await gitRoot($, folderOf)
  const base: View = { href, title, location: line ? `${path}:${line}` : path, root: git?.root, isWorktree: git?.isWorktree }
  const stat = await $.fs.stat(path)
  const age = describeAge(stat.mtimeMs, await $.clock.now())
  if (stat.kind === 'dir') {
    const entries = (await $.fs.list(path)).filter(one => !one.name.startsWith('.'))
    const dir = entries
      .sort((a, b) => Number(b.kind === 'dir') - Number(a.kind === 'dir') || a.name.localeCompare(b.name))
      .slice(0, 500)
      .map(one => ({ name: one.name, isDir: one.kind === 'dir', size: one.size, mtimeMs: one.mtimeMs }))
    const folders = dir.filter(one => one.isDir).length
    const summary = `${folders} folders · ${dir.length - folders} files`
    return { ...base, kind: 'folder', meta: `${entries.length} items · edited ${age}`, summary, dir }
  }
  const kind = kindOf(path)
  const sized = `${describeSize(stat.size)} · edited ${age}`
  if (kind === 'image' || kind === 'svg') {
    const image = await toPng($, path, stat.mtimeMs)
    return { ...base, kind, meta: `${image.width}×${image.height} · ${sized}`, image }
  }
  if (kind === 'html') {
    const html = await $.fs.read(path)
    return { ...base, kind, meta: sized, markdown: fitMarkdown(htmlToMarkdown(html)) }
  }
  const text = await $.fs.read(path)
  const lineCount = text.split('\n').length
  const meta = `${lineCount} lines · ${sized}`
  if (kind === 'markdown') {
    const tasks = linkTasks(text, fileHref(path))
    const drawn = await withDrawnMermaid($, tasks.text)
    fullText.set(href, drawn)
    const outline = outlineOf(drawn).map(({ level, text: heading }) => ({ level, text: heading }))
    const taskCount = tasks.total ? `${tasks.done}/${tasks.total} tasks` : undefined
    return { ...base, kind, meta, tasks: taskCount, outline, markdown: fitMarkdown(drawn) }
  }
  if (kind === 'mermaid') {
    const art = await drawMermaid($, text)
    const body = art
      ? `\`\`\`text\n${art.replace(/\s+$/, '')}\n\`\`\``
      : `*This diagram type cannot be drawn as text. Press "Open externally" to see it rendered.*\n\n\`\`\`mermaid\n${text}\n\`\`\``
    return { ...base, kind, meta, markdown: fitMarkdown(body) }
  }
  if (kind === 'csv') {
    const rows = parseDelimited(text, extOf(path) === 'tsv' ? '\t' : ',')
    const [header = [], ...body] = rows
    const columns = Math.max(header.length, ...body.slice(0, 200).map(row => row.length))
    const table = { header, rows: body.slice(0, 500), total: body.length }
    return { ...base, kind, meta, summary: `${body.length} rows × ${columns} columns`, table }
  }
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
  const code = { source: window.join('\n'), language, startLine, focusLine: line }
  return { ...base, kind: kind === 'json' || kind === 'toml' ? kind : 'text', meta, summary, code }
}

async function loadUrl($: EngineInterface, href: string): Promise<View> {
  const url = new URL(href)
  const base: View = { href, title: url.hostname + url.pathname, location: href, kind: 'web', meta: url.hostname }
  const kind = kindOf(url.pathname)
  if (kind === 'image' || kind === 'svg') {
    return { ...base, error: 'Remote images open in the browser. Press "Open externally".' }
  }
  const response = await $.http.fetch(href)
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

function remoteIoOf($: EngineInterface): RemoteIo {
  return {
    sessionId: () => $.session.id(),
    run: (argv, init) => $.process.run(argv, init),
    fetch: (url, init) => $.http.fetch(url, init),
    linearKeyEnv: () => $.env.get('LINEAR_API_KEY'),
    home: () => $.env.get('HOME'),
    read: path => $.fs.read(path),
    sleep: ms => $.clock.sleep(ms),
    mcpCall: (server, tool, args) => $.mcp.call(server, tool, args),
    now: () => $.clock.now(),
  }
}

async function remotePicture($: EngineInterface, file: string | undefined) {
  if (!file || failedPictures.has(file)) return undefined
  return toPng($, file, 0).catch(() => {
    failedPictures.add(file)
    return undefined
  })
}

const LINEAR_BOOT_TTL_MS = 24 * 3600_000
const MAX_BLOCK_MEMO = 400
let lastActivity = 0
let isTicking = false
let linearBoot: Omit<LinearBootstrap, 'ok'> | null = null
let titles: Record<string, TitleEntry> = {}
let topBlockKey = 'block-0'
let showGeneration = 0
const repoContexts = new Map<string, string | null>()
const backStack: { view: View; key: string }[] = []
const failedPictures = new Set<string>()
const blockMemo = new Map<string, { chunk: string; rows: number }[]>()

async function repoContext($: EngineInterface, cwd: string): Promise<string | undefined> {
  if (!repoContexts.has(cwd)) {
    let found: string | null = null
    for (const remote of ['upstream', 'origin']) {
      const ran = await $.process.run(['git', '-C', cwd, 'remote', 'get-url', remote]).catch(() => null)
      const match = ran?.exitCode === 0 ? /github\.com[:/]([\w.-]+)\/([\w.-]+?)(?:\.git)?\s*$/.exec(ran.stdout) : null
      if (match) {
        found = `${match[1]}/${match[2]}`
        break
      }
    }
    repoContexts.set(cwd, found)
  }
  return repoContexts.get(cwd) ?? undefined
}

function refContext(repo?: string): RefContext {
  const captured = capturedLinearContext()
  return {
    teamKeys: [...new Set([...(linearBoot?.teamKeys ?? []), ...captured.teamKeys])],
    workspace: linearBoot?.workspace ?? captured.workspace,
    repo,
  }
}

async function sessionRefContext($: EngineInterface): Promise<RefContext> {
  return refContext(await repoContext($, await $.session.cwd()))
}

async function bootLinear($: EngineInterface) {
  const now = await $.clock.now()
  const saved = (await $.store.get('linear').catch(() => undefined)) as typeof linearBoot | undefined
  if (saved && typeof saved.workspace === 'string' && Array.isArray(saved.teamKeys) && now - saved.fetchedAt < LINEAR_BOOT_TTL_MS) {
    linearBoot = saved
    return
  }
  const boot = await bootstrapLinear(remoteIoOf($), now)
  if (!boot.ok) return
  linearBoot = { workspace: boot.workspace, teamKeys: boot.teamKeys, fetchedAt: boot.fetchedAt }
  await $.store.set('linear', linearBoot).catch(() => undefined)
  $.ui.invalidate('ui.render')
}

async function openFromPage($: EngineInterface, href: string) {
  const current = await read($, view)
  if (current && (await read($, mode)) === 'view') {
    backStack.push({ view: current, key: topBlockKey })
    if (backStack.length > 20) backStack.shift()
  }
  await show($, href)
}

async function goBack($: EngineInterface) {
  const last = backStack.pop()
  if (!last) return
  await update($, view, () => last.view)
  await update($, mode, () => 'view')
  void $.ui.scroll({ in: PANE, to: { key: last.key }, block: 'start' }).catch(() => undefined)
}

function remoteLoader($: EngineInterface, canReplay: boolean) {
  return async (address: string): Promise<Loaded> => {
    const ref = parseRef(address)
    if (!ref) return { ok: false, failure: 'query-bug' }
    return loadItem(remoteIoOf($), ref, await $.clock.now(), { canReplay })
  }
}

async function noteTitle($: EngineInterface, entry: CacheEntry) {
  if (!entry.record) return
  const next = titleOf(entry.record)
  const { updatedAt: _, ...known } = titles[entry.record.address] ?? { updatedAt: 0 }
  if (JSON.stringify(known) === JSON.stringify(next)) return
  titles = withTitle(titles, entry.record.address, next, await $.clock.now())
  await $.store.set('titles', titles).catch(() => undefined)
}

async function loadRemote($: EngineInterface, ref: Ref, canReplay = false): Promise<View> {
  if (!isTicking) {
    isTicking = true
    $.clock.every(15_000, () => void tickRemote($).catch(() => undefined))
  }
  const known = cached(ref.address)
  if (known?.state === 'frozen') return viewOf($, ref, known)
  const entry = await refreshItem(ref.address, remoteLoader($, canReplay), await $.clock.now())
  await noteTitle($, entry)
  return viewOf($, ref, entry)
}

async function viewOf($: EngineInterface, ref: Ref, entry: CacheEntry): Promise<View> {
  const base: View = { href: ref.address, title: ref.key ?? ref.address.replace(/^https:\/\//, ''), location: ref.address, kind: ref.kind }
  const record = entry.record
  if (!record) return { ...base, remote: { failure: entry.failure ?? 'offline' } }
  return {
    href: record.address,
    title: record.title,
    location: record.browserUrl,
    kind: record.kind,
    remote: {
      record,
      tier: entry.tier,
      fetchedAt: entry.fetchedAt,
      staleSince: entry.staleSince,
      favicon: await remotePicture($, record.favicon),
      preview: await remotePicture($, record.og?.image),
    },
  }
}

function remoteRef(href: string, context: RefContext = {}): Ref | null {
  if (parseHref(href)) return null
  const ref = parseRef(href, context)
  if (!ref) return null
  const kind = ref.kind === 'web' ? kindOf(new URL(ref.address).pathname) : null
  return kind === 'image' || kind === 'svg' ? null : ref
}

async function show($: EngineInterface, raw: string) {
  const generation = ++showGeneration
  const ref = remoteRef(raw)
  const href = ref?.address ?? raw
  const file = parseHref(href)
  const loading: View = { href, title: 'Loading…', location: file?.path ?? href }
  await update($, view, () => loading)
  const at = await $.clock.now()
  await update($, mentions, list => noteMentions(list, [href], at))
  await update($, trail, list => pushRecent(list, [href], 8))
  await update($, section, () => -1)
  await update($, page, () => 0)
  await update($, mode, () => 'view')
  void $.ui.scroll({ in: PANE, to: 'start' }).catch(() => undefined)
  void $.ui.open({ id: PANE, title: 'Peek' })
  let next: View
  try {
    next = file ? await loadFile($, href, file.path, file.line) : ref ? await loadRemote($, ref) : await loadUrl($, href)
  } catch (error) {
    next = { ...loading, title: 'Could not open', error: error instanceof Error ? error.message : String(error) }
  }
  if (generation !== showGeneration) return
  await update($, view, () => next)
  void $.ui.open({ id: PANE, title: next.title })
}

async function openExternally($: EngineInterface, current: View) {
  const file = parseHref(current.href)
  if (!file) {
    await $.process.run(['open', current.href])
    return
  }
  const kind = kindOf(file.path)
  if (kind !== 'markdown' && kind !== 'mermaid') {
    await $.process.run(['open', file.path])
    return
  }
  const source = await $.fs.read(file.path)
  const page = kind === 'mermaid' ? mermaidPage(current.title, source) : markdownPage(current.title, source)
  const out = `${SCRATCH}/${current.title.replace(/[^\w.-]/g, '_')}.html`
  await $.fs.write(out, page)
  await $.process.run(['open', out])
}

async function remember(
  $: EngineInterface,
  texts: readonly string[],
  created: readonly string[],
  touched: readonly string[],
) {
  const cwd = await $.session.cwd()
  const home = (await $.env.get('HOME')) ?? ''
  const toHrefs = async (raws: readonly string[]) => {
    const out: string[] = []
    for (const raw of raws) {
      const abs = resolvePath(raw, cwd, home)
      if (await pathExists($, abs)) out.push(fileHref(abs))
    }
    return out
  }
  const artifacts = [...(await toHrefs([...texts.flatMap(pathCandidates), ...created])), ...texts.flatMap(urlCandidates)]
  const worked = await toHrefs(touched)
  if (!artifacts.length && !worked.length) return
  const at = await $.clock.now()
  await update($, mentions, list =>
    noteMentions(noteMentions(list, [...new Set(worked)], at), [...new Set(artifacts)], at, 200, true),
  )
}

function captureIoOf($: EngineInterface): CaptureIo {
  return {
    mcpCall: (server, tool, args) => $.mcp.call(server, tool, args),
    now: () => $.clock.now(),
  }
}

async function noteCapture($: EngineInterface, input: Record<string, unknown>, answer: unknown) {
  const at = await $.clock.now()
  lastActivity = at
  const { addresses, grewLinear } = record(input, answer, at)
  if (addresses.length) await update($, mentions, list => noteMentions(list, addresses, at, 200, true))
  if (grewLinear) $.ui.invalidate('ui.render')
}

async function toHref($: EngineInterface, raw: string): Promise<string | null> {
  const cleaned = raw.trim().replace(/^[`'"<]+|[`'">.]+$/g, '')
  if (/^https?:\/\//.test(cleaned)) return cleaned
  if (cleaned.startsWith('file:')) return cleaned
  const needsContext = /^(?:#\d+|[A-Z][A-Z0-9]{0,9}-\d+)$/.test(cleaned)
  const ref = parseRef(cleaned, needsContext ? await sessionRefContext($) : {})
  if (ref) return ref.address
  const match = /^(.+?)(?::(\d+))?$/.exec(cleaned)
  const abs = resolvePath(match?.[1] ?? cleaned, await $.session.cwd(), (await $.env.get('HOME')) ?? '')
  exists.delete(abs)
  if (!(await pathExists($, abs))) return null
  return fileHref(abs, match?.[2] ? Number(match[2]) : undefined)
}

async function guess($: EngineInterface, query: string): Promise<string | null> {
  const list = (await read($, mentions)).map(one => one.href)
  const ranked = rankRecent(query, list)
  const [first, second] = ranked
  if (first && hasMeaningfulWords(query) && first.score >= 3 && first.score - (second?.score ?? 0) >= 1) {
    return first.href
  }
  const shortlist = list.slice(-25).reverse().map(href => `- ${parseHref(href)?.path ?? href}`).join('\n')
  $.ui.toast('Peek: working out which one you mean…')
  const reply = await $.model.fork({
    prompt: [
      `I ran /peek ${query}`,
      'Which ONE file path or URL from this conversation do I mean? Prefer the most recent match.',
      shortlist ? `Paths and links seen recently, newest first:\n${shortlist}` : '',
      'Reply with only the absolute path (optionally :line) or the URL, nothing else. If nothing fits, reply NONE.',
    ].filter(Boolean).join('\n\n'),
  })
  if (reply.isAnswered) {
    const line = reply.text.trim().split('\n')[0] ?? ''
    if (line && line !== 'NONE') {
      const href = await toHref($, line)
      if (href) return href
    }
    return null
  }
  return first && first.score >= 1 ? first.href : null
}

const SCOPE_TTL_MS = 30_000
const MAX_WORKTREES = 12
const LIST_FILES =
  "git ls-files -z --cached --others --exclude-standard | head -c 2000000 | xargs -0 stat -f '%m %z %N' 2>/dev/null | head -4000"
const scopeCache = new Map<string, { at: number; entries: FileEntry[] }>()
const scopeLoading = new Set<string>()

async function listRoot($: EngineInterface, root: string, worktree?: string): Promise<FileEntry[]> {
  const ran = await $.process.run(['sh', '-c', LIST_FILES], { cwd: root, timeoutMs: 20_000 }).catch(() => null)
  return ran ? parseStatLines(ran.stdout, root, worktree) : []
}

async function sessionEntries($: EngineInterface, list: readonly Mention[]): Promise<FileEntry[]> {
  const out: FileEntry[] = []
  const remoteTitles = new Map(Object.entries(titles).map(([address, entry]) => [itemKey(address), entry]))
  for (const one of [...list].reverse()) {
    const file = parseHref(one.href)
    const path = file?.path ?? one.href
    const name = path.split('/').pop() || path
    const stat = file ? await $.fs.stat(path).catch(() => null) : null
    if (file && !stat) continue
    const ref = file ? null : remoteRef(one.href)
    const label = ref ? remoteTitles.get(itemKey(ref.address)) : undefined
    if (ref) {
      out.push({
        href: one.href,
        path,
        name: label?.title ?? ref.key ?? (ref.number ? `#${ref.number}` : path.replace(/^https?:\/\/(www\.)?/, '')),
        folder: ref.owner ? `${ref.owner}/${ref.repo}` : label?.trail?.join(' · ') || new URL(ref.address).hostname,
        kind: label?.kind ?? ref.kind,
        status: label?.status,
        favicon: (await remotePicture($, label?.favicon))?.file,
        mtimeMs: 0,
        size: 0,
        mentions: one.count,
        mentionedAt: one.at,
        role: one.isArtifact ? 'artifact' : 'touched',
      })
      continue
    }
    out.push({
      href: one.href,
      path,
      name,
      folder: path.slice(0, Math.max(0, path.length - name.length - 1)),
      kind: file ? (stat?.kind === 'dir' ? 'folder' : kindOf(path)) : 'web',
      mtimeMs: stat?.mtimeMs ?? 0,
      size: stat?.size ?? 0,
      mentions: one.count,
      mentionedAt: one.at,
      role: one.isArtifact ? 'artifact' : 'touched',
    })
  }
  return out
}

async function loadScope($: EngineInterface, scope: Exclude<Scope, 'session'>, cwd: string): Promise<FileEntry[]> {
  const git = await gitRoot($, cwd)
  if (!git) return []
  if (scope === 'worktree') return listRoot($, git.root, git.root.split('/').pop())
  const ran = await $.process.run(['git', '-C', git.root, 'worktree', 'list', '--porcelain']).catch(() => null)
  const roots = (ran?.stdout ?? '')
    .split('\n')
    .filter(line => line.startsWith('worktree '))
    .map(line => line.slice('worktree '.length))
    .slice(0, MAX_WORKTREES)
  const all: FileEntry[] = []
  for (const root of roots.length ? roots : [git.root]) all.push(...(await listRoot($, root, root.split('/').pop())))
  return all
}

// Returns the cached listing, or null while a background load runs; the load
// redraws the pane when it lands.
function scopeEntries($: EngineInterface, scope: Exclude<Scope, 'session'>, cwd: string, now: number): FileEntry[] | null {
  const key = `${scope}|${cwd}`
  const cached = scopeCache.get(key)
  if (cached && now - cached.at < SCOPE_TTL_MS) return cached.entries
  if (!scopeLoading.has(key)) {
    scopeLoading.add(key)
    void loadScope($, scope, cwd)
      .then(entries => scopeCache.set(key, { at: Date.now(), entries }))
      .catch(() => scopeCache.set(key, { at: Date.now(), entries: [] }))
      .finally(() => {
        scopeLoading.delete(key)
        $.ui.invalidate('ui.render')
      })
  }
  return cached?.entries ?? null
}

function withMentions(entries: readonly FileEntry[], list: readonly Mention[]): FileEntry[] {
  const byHref = new Map(list.map(one => [one.href, one]))
  return entries.map(one => {
    const hit = byHref.get(one.href)
    return hit
      ? { ...one, mentions: hit.count, mentionedAt: hit.at, role: hit.isArtifact ? ('artifact' as const) : ('touched' as const) }
      : one
  })
}

async function setStar($: EngineInterface, raw: string, wanted?: boolean): Promise<boolean> {
  const canonical = remoteRef(raw)?.address ?? raw
  let isOn = false
  await update($, stars, list => {
    const href = list.find(one => itemKey(remoteRef(one)?.address ?? one) === itemKey(canonical)) ?? canonical
    const next = toggleStar(list, href, wanted)
    isOn = next.includes(href)
    return next
  })
  await $.store.set('stars', await read($, stars)).catch(() => undefined)
  return isOn
}

async function refresh($: EngineInterface, href: string) {
  const ref = remoteRef(href)
  if (ref) {
    const entry = await refreshItem(ref.address, remoteLoader($, true), await $.clock.now())
    await noteTitle($, entry)
    await redrawIfCurrent($, entry.address)
    return
  }
  const file = parseHref(href)
  if (!file) return
  exists.delete(file.path)
  const next = await loadFile($, href, file.path, file.line).catch(() => null)
  if (next) await update($, view, () => next)
}

// The header shortens a crumb by keeping its first two characters as the icon,
// so every trail piece needs one.
function trailIcon(kind: string, index: number, count: number): string {
  const family = familyOf(kind)
  if (family === 'gh') return index === 0 && count > 1 ? '\u{f09b}' : ICON['gh-repo']
  if (family === 'linear') return index === 0 ? '\u{f0c0}' : ICON['linear-project']
  return '\u{f0ac}'
}

const TIER_NAMES: Record<string, string> = { 'gh-cli': 'via gh', 'web-cli': 'via curl', 'web-api': 'via web fetch', 'linear-api': 'via Linear API' }

function sourceLine(remote: NonNullable<View['remote']>, now: number): string {
  const { tier, fetchedAt, staleSince } = remote
  const family = familyOf(remote.record?.kind ?? 'web')
  const name = tier === 'session' ? 'from this session' : (TIER_NAMES[`${family}-${tier}`] ?? `via ${tier ?? '?'}`)
  const seconds = fetchedAt === undefined ? 0 : Math.max(0, Math.round((now - fetchedAt) / 1000))
  const age = fetchedAt === undefined ? '' : seconds < 60 ? `${seconds}s ago` : describeAge(fetchedAt, now)
  const stale = staleSince === undefined ? '' : ` · stale since ${describeAge(staleSince, now)}`
  return `${name}${age ? ` · ${age}` : ''}${stale}`
}

async function redrawIfCurrent($: EngineInterface, address: string) {
  const current = await read($, view)
  const ref = current && remoteRef(current.href)
  const entry = cached(address)
  if (!current || !ref || !entry || !isCurrent(current.href, address)) return
  const next = await viewOf($, ref, entry)
  if ((await read($, view))?.href === current.href) await update($, view, () => next)
}

async function tickRemote($: EngineInterface) {
  if ((await $.clock.now()) - lastActivity >= IDLE_MS) return
  const current = await read($, view)
  const onScreen = current?.remote && (await read($, mode)) === 'view' ? current.href : undefined
  const hrefs = [...(await read($, mentions)).map(one => one.href), ...(await read($, stars))]
  const background = [...new Set(hrefs)].filter(href => remoteRef(href) && isTimed(href))
  const changed = await tick({ onScreen, background, now: await $.clock.now(), lastActivity, load: remoteLoader($, true) })
  for (const address of changed) {
    const entry = cached(address)
    if (entry) await noteTitle($, entry)
    await redrawIfCurrent($, address)
  }
}

async function pressLink($: EngineInterface, href: string) {
  const task = /#task-(\d+)$/.exec(href)
  const current = await read($, view)
  const file = parseHref(href)
  if (task && file && current && parseHref(current.href)?.path === file.path) {
    const source = await $.fs.read(file.path)
    const toggled = toggleTaskLine(source, Number(task[1]))
    if (toggled !== null) {
      await $.fs.write(file.path, toggled)
      await refresh($, current.href)
      return
    }
  }
  await openFromPage($, href)
}

async function docImage($: EngineInterface, src: string, docPath: string) {
  if (/^https?:/.test(src)) return null
  const folder = docPath.slice(0, docPath.lastIndexOf('/'))
  const home = (await $.env.get('HOME')) ?? ''
  const abs = resolvePath(decodeURIComponent(src.replace(/^file:\/\//, '')), folder, home)
  const stat = await $.fs.stat(abs).catch(() => null)
  if (!stat || stat.kind !== 'file') return null
  const image = await toPng($, abs, stat.mtimeMs).catch(() => null)
  const png = image ? pixels.get(image.file) : undefined
  return image && png ? { abs, png, width: image.width, height: image.height } : { abs, png: undefined, width: 0, height: 0 }
}

// Esc closes a pane only while it is opened with closeOnEscape, so the menu
// turns that on and the ui.close hook turns the close into closing the menu.
async function setMenu($: EngineInterface, isOpen: boolean) {
  await update($, menuFilter, () => '')
  await update($, menuOpen, () => isOpen)
  await $.ui.open(isOpen ? { id: PANE, title: 'Peek', focus: true, closeOnEscape: true } : { id: PANE, title: 'Peek' })
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    lastActivity = await $.clock.now()
    const savedTitles = await $.store.get('titles').catch(() => undefined)
    if (savedTitles && typeof savedTitles === 'object' && !Array.isArray(savedTitles)) titles = savedTitles as Record<string, TitleEntry>
    void bootLinear($).catch(() => undefined)
    const saved = await $.store.get('stars').catch(() => undefined)
    if (Array.isArray(saved)) await update($, stars, () => saved.filter((one): one is string => typeof one === 'string'))
    await $.tool
      .register({
        name: 'star',
        description:
          'Star or unstar a file path or URL in the peek side pane, so it sorts first in Recent and Gallery. Star the things the user should look at: a plan, a report, a diagram you made. Use sparingly.',
        inputSchema: {
          type: 'object',
          properties: {
            target: { type: 'string', description: 'An absolute or relative file path, or an http(s) URL' },
            starred: { type: 'boolean', description: 'true to star (the default), false to unstar' },
          },
          required: ['target'],
        },
      })
      .catch(() => undefined)
    await $.command.register({ name: 'peek-menu', description: 'Open the peek command menu (ctrl+k in the peek pane)' })
    await $.command.register({ name: 'peek-ui', description: 'Show every Claude Code UI element a mod can draw, live' })
    await $.command.register({ name: 'peek', description: 'Peek at a file, folder or URL in the side pane: a path, a description ("the export diagram"), or nothing for the last one' })
    return next(e)
  })

  on('session.append', async ($, e, next) => {
    const stored = await next(e)
    lastActivity = await $.clock.now()
    if (e.message.type !== 'assistant' || e.agentId) return stored
    const { texts, created, touched } = classifyBlocks(e.message.content)
    await remember($, texts, created, touched).catch(() => undefined)
    return stored
  })

  on('command.run', { command: 'peek-menu' }, async $ => {
    await setMenu($, !(await read($, menuOpen)))
    return { text: '' }
  })

  on('ui.focus', { component: 'Pane', requestId: PANE }, async ($, e, next) => {
    const picked = /^item-(\d+)$/.exec(e.element ?? '')
    if (picked && e.origin.kind === 'person') {
      const index = Number(picked[1])
      await update($, cursorAtom, () => index).catch(() => undefined)
      const key = navOrder[index]?.key
      if (key) void $.ui.scroll({ in: PANE, to: { key }, block: 'center' }).catch(() => undefined)
    }
    return next(e)
  })

  on('ui.close', { id: PANE }, async ($, e, next) => {
    if (e.origin.kind === 'person' && (await read($, menuOpen).catch(() => false))) {
      await setMenu($, false).catch(() => undefined)
      return { value: undefined }
    }
    return next(e)
  })

  on('command.run', { command: 'peek-ui' }, async $ => {
    await $.ui.open({ id: GALLERY, title: 'UI gallery', focus: true })
    return { text: 'UI gallery open. Click the pane to use its buttons, input, select and the live Client; arrows scroll.' }
  })

  on('ui.render', { component: 'Pane', requestId: GALLERY }, async ($, e) => {
    const elements = $.ui.resolve(e)
    const { Box, Text, Button, Link, Code, Markdown } = elements
    const Input = 'Input' in elements ? elements.Input : undefined
    const Select = 'Select' in elements ? elements.Select : undefined
    const Image = 'Image' in elements ? elements.Image : undefined
    const Raster = 'Raster' in elements ? elements.Raster : undefined
    const Client = 'Client' in elements ? elements.Client : undefined
    const width = Math.max(20, e.props.bodyColumns - 2)
    const count = await read($, presses)
    const text = await read($, typed)
    const border = await read($, picked)
    let png: string | undefined
    if (Image) {
      const image = await toPng($, `${$.plugin.root}/assets/sample.png`, 0).catch(() => undefined)
      png = image ? pixels.get(image.file) : undefined
    }
    const heading = (title: string, note: string) => (
      <Box flexDirection="column" marginTop={1}>
        <Text bold color="cyan">{title}</Text>
        <Text dimColor wrap="truncate-end">{note}</Text>
      </Box>
    )

    return (
      <Box flexDirection="column">
        <Text bold>Claude Code UI elements for mods ({e.surface})</Text>
        <Text dimColor>Every element this surface offers, drawn live. ↑↓ scroll.</Text>

        {heading('Text', 'Styles, colours and how long lines are cut')}
        <Box flexDirection="row" gap={1} flexWrap="wrap">
          <Text bold>bold</Text>
          <Text italic>italic</Text>
          <Text underline>underline</Text>
          <Text strikethrough>strike</Text>
          <Text inverse> inverse </Text>
          <Text dimColor>dim</Text>
          <Text color="red">red</Text>
          <Text color="#ff8800">#ff8800</Text>
          <Text backgroundColor="blue" color="white"> on blue </Text>
          <Box key="hover-text">
            <Text hover={{ color: 'magenta', bold: true }}>hover me</Text>
          </Box>
        </Box>
        <Text wrap="truncate-start">truncate-start: /a/very/long/path/to/some/deeply/nested/folder/and/the/file-name.md</Text>
        <Text wrap="truncate-middle">truncate-middle: /a/very/long/path/to/some/deeply/nested/folder/and/the/file-name.md</Text>
        <Text wrap="truncate-end">truncate-end: /a/very/long/path/to/some/deeply/nested/folder/and/the/file-name.md</Text>

        {heading('Box', 'Flexbox layout, borders, padding, background, hover reveal')}
        <Box flexDirection="row" flexWrap="wrap" gap={1}>
          {BORDERS.map(style => (
            <Box key={`border-${style}`} borderStyle={style} borderColor={style === border ? 'green' : 'gray'} paddingX={1}>
              <Text>{style}</Text>
            </Box>
          ))}
        </Box>
        <Box flexDirection="row" justifyContent="space-between" backgroundColor="#202838" paddingX={1}>
          <Text>left</Text>
          <Text>space-between</Text>
          <Text>right</Text>
        </Box>
        <Box key="hover-card" flexDirection="row" borderStyle="round" borderColor="gray" hover={{ borderColor: 'yellow' }} paddingX={1}>
          <Text>Hover this box: its border lights up</Text>
        </Box>

        {heading('Button', 'Click, Enter or its hotkey (g) while the pane has the keys')}
        <Box flexDirection="row" gap={1} flexWrap="wrap">
          <Button key="g-press" label={`Pressed ${count}×`} hotkey="g" variant="primary" onPress={() => void update($, presses, n => n + 1)} />
          <Button key="g-reset" label="Reset" variant="secondary" onPress={() => void update($, presses, () => 0)} />
          <Button key="g-plain" label="plain" plain onPress={() => void update($, presses, n => n + 1)} />
          <Button key="g-dim" label="dim" dimColor onPress={() => void update($, presses, n => n + 1)} />
        </Box>

        {heading('Input', 'A text field; Enter submits')}
        {Input ? (
        <Input
          key="g-input"
          label="Say something"
          placeholder="type, then Enter"
          submitLabel="Send"
          onSubmit={(value: string) => void update($, typed, () => value)}
        />
        ) : (
          <Text dimColor>Not available on this surface.</Text>
        )}
        <Text dimColor>Last submitted: {text || '—'}</Text>

        {heading('Select', 'A pick list; here it chooses which Box border is highlighted')}
        {Select ? (
        <Select
          key="g-select"
          label="Border"
          value={border}
          options={BORDERS.map(style => ({ value: style, label: style }))}
          onSelect={(value: string) => void update($, picked, () => value)}
        />
        ) : (
          <Text dimColor>Not available on this surface.</Text>
        )}

        {heading('Link', 'A clickable web link')}
        <Link href="https://docs.claude.com/en/docs/claude-code/overview" label="Claude Code docs" />

        {heading('Code', 'Syntax colours, line numbers, and diff format')}
        <Code source={SAMPLE_RUST} language="rust" path="greet.rs" startLine={1} />
        <Code source={SAMPLE_DIFF} language="rust" format="diff" />

        {heading('Markdown', 'Drawn the way Claude Code draws a reply')}
        <Markdown text={SAMPLE_MARKDOWN} />

        {heading('Image', 'Real pixels, terminal only (kitty / Ghostty graphics)')}
        {Image && png ? (
          <Image key="g-image" source={{ png }} columns={Math.min(40, width)} rows={12} alt="(this terminal cannot draw images)" />
        ) : (
          <Text dimColor>Not available on this surface.</Text>
        )}

        {heading('Raster', 'A raw grid of coloured cells, terminal only')}
        {Raster ? (
          <Raster key="g-raster" columns={Math.min(48, width)} rows={6} cells={rasterGradient(Math.min(48, width), 6)} />
        ) : (
          <Text dimColor>Not available on this surface.</Text>
        )}

        {heading('Client', 'A live mini-app with its own state, timer and keys')}
        {Client ? (
          <Client key="g-client" module="./ticker.tsx" props={{ width: Math.min(40, width) }} />
        ) : (
          <Text dimColor>Not available on this surface.</Text>
        )}
      </Box>
    )
  })

  on('command.run', { command: 'peek' }, async ($, e) => {
    const arg = e.args.trim()
    if (!arg) {
      const last = (await read($, mentions)).at(-1)?.href
      if (!last) {
        await $.ui.open({ id: PANE, title: 'Peek' })
        return { text: 'Nothing to reopen yet. Peek pane opened.' }
      }
      await show($, last)
      return { text: `Peeking at ${parseHref(last)?.path ?? last}` }
    }
    const href = (await toHref($, arg)) ?? (await guess($, arg))
    if (!href) {
      const latest = (await read($, mentions)).slice(-5).reverse().map(one => one.href)
      const hint = latest.length ? `\nRecent: ${latest.map(one => parseHref(one)?.path ?? one).join(', ')}` : ''
      return { text: `Could not tell which file "${arg}" means.${hint}` }
    }
    await show($, href)
    return { text: `Peeking at ${parseHref(href)?.path ?? href}` }
  })

  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
    const { Box, Text, Markdown } = $.ui.resolve(e)
    const cwd = await $.session.cwd()
    const home = (await $.env.get('HOME')) ?? ''
    const real = new Map<string, string>()
    for (const raw of pathCandidates(e.props.text)) {
      const abs = resolvePath(raw, cwd, home)
      if (await pathExists($, abs)) real.set(raw, abs)
    }
    const linked = linkify(
      e.props.text,
      (raw, line) => {
        const abs = real.get(raw)
        return abs ? fileHref(abs, line) : null
      },
      refContext(await repoContext($, cwd)),
    )
    const text = linked.length <= 10000 ? linked : e.props.text
    if (text.length > 10000) return next(e)

    const body = <Markdown key="reply" text={text} onLinkPress={link => void show($, link.href)} />
    if (!e.props.isFirstOfReply) return body

    return (
      <Box flexDirection="row">
        <Text>⏺ </Text>
        {body}
      </Box>
    )
  })

  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc; the validator checks this hook
  on('tool.call', { tool: /^mcp__peek__star$/ }, async ($, e) => {
    const input = e as unknown as { target?: unknown; starred?: unknown }
    if (typeof input.target !== 'string') return { result: 'Give a target: a file path or URL.' }
    const target = input.target
    const href = await toHref($, target).catch(() => null)
    if (!href) return { result: `No file or URL at ${target}.` }
    const isOn = await setStar($, href, input.starred !== false).catch(() => null)
    if (isOn === null) return { result: 'Could not save the star.' }
    return { result: `${isOn ? 'Starred' : 'Unstarred'} ${parseHref(href)?.path ?? href} in peek.` }
  })

  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc; the validator checks this hook
  on('tool.call', { tool: /^(?:Bash$|WebFetch$|mcp__(?!peek__))/ }, async ($, e, next) => {
    const answer = await next(e)
    await noteCapture($, e as unknown as Record<string, unknown>, answer).catch(() => undefined)
    return answer
  })

  on('ui.message', async ($, e, next) => {
    const starring = e.data as { star?: unknown } | null
    if (e.requestId === PANE && starring && typeof starring.star === 'string') {
      await setStar($, starring.star).catch(() => undefined)
      return {}
    }
    const data = e.data as { toggle?: unknown } | null
    if (e.requestId === PANE && data && typeof data.toggle === 'string') {
      await pressLink($, data.toggle).catch(() => undefined)
      return {}
    }
    const switching = e.data as { mode?: unknown } | null
    if (e.requestId === PANE && switching && (switching.mode === 'view' || switching.mode === 'recent' || switching.mode === 'gallery')) {
      const target = switching.mode
      await update($, mode, () => target).catch(() => undefined)
      await update($, page, () => 0).catch(() => undefined)
      void $.ui.scroll({ in: PANE, to: 'start' }).catch(() => undefined)
      return {}
    }
    const opening = e.data as { open?: unknown } | null
    if (e.requestId === PANE && opening && typeof opening.open === 'string') {
      await show($, opening.open).catch(() => undefined)
      return {}
    }
    return next(e)
  })

  on('ui.scroll', { component: 'Pane', requestId: PANE }, async ($, e, next) => {
    const isList = (await read($, mode).catch(() => 'view')) !== 'view' || !(await read($, view).catch(() => null))
    if (isList && !e.pointer && e.origin.kind === 'person' && Math.abs(e.by) === 1 && !(await read($, menuOpen).catch(() => false))) {
      await moveSelection($, e.by > 0 ? 'down' : 'up').catch(() => undefined)
      return {}
    }
    contentRows = e.contentRows
    const wanted = e.origin.kind === 'plugin' && e.offset > 0 ? e.offset - HEADER_ROWS : e.offset
    const target = Math.max(0, Math.min(wanted, Math.max(0, e.contentRows - e.bodyRows)))
    await update($, page, () => target).catch(() => undefined)
    return next({ ...e, offset: target })
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const isMenuOpen = await read($, menuOpen)
    const C = isMenuOpen ? MUTED : BASE
    const elements = $.ui.resolve(e)
    const { Box, Text, Button, Markdown, Code } = elements
    const Image = 'Image' in elements ? elements.Image : undefined
    const Client = 'Client' in elements ? elements.Client : undefined
    const current = await read($, view)
    const chosen = await read($, mode)
    const at = await read($, page)
    const list = await read($, mentions)
    const now = await $.clock.now()
    const cwd = await $.session.cwd()
    const home = (await $.env.get('HOME')) ?? ''
    const columns = Math.max(20, e.props.bodyColumns - 1)
    paneColumns = columns
    const isNarrow = columns < NARROW
    const textWidth = isNarrow ? columns : Math.min(MAX_CPL, Math.max(MIN_CPL, columns - 6))
    const pageWidth = isNarrow ? columns : textWidth + 4
    const rows = Math.max(4, e.props.scroll.bodyRows - 4)
    const turn = (to: number) => void update($, page, () => Math.max(0, to))

    const chip = (label: string, isOn: boolean) => (
      <Text color={isOn ? C.appBg : C.overlay0} backgroundColor={isOn ? C.accent : C.panelBg} bold={isOn}>
        {label}
      </Text>
    )
    const peekChip = ` ${MODES[0]?.icon ?? ''} PEEK `
    const recentChip = ` ${MODES[1]?.icon ?? ''} RECENT `
    const galleryChip = ` ${MODES[2]?.icon ?? ''} GALLERY `
    const crumbs = (parts: { label: string; fg: string; bg: string; bold?: boolean; canShrink?: boolean }[]) => {
      const room = Math.max(8, isNarrow ? columns - 2 : columns - peekChip.length - recentChip.length - galleryChip.length - 4)
      const width = (label: string) => label.length + 2
      let spare = room - 2 - parts.reduce((sum, one) => sum + width(one.label), 0)
      const fitted = parts.map(one => ({ ...one }))
      for (const one of fitted) {
        if (spare >= 0 || !one.canShrink) continue
        const keep = Math.max(3, one.label.length + spare)
        const icon = one.label.slice(0, 2)
        const rest = one.label.slice(2)
        const tail = Math.max(1, keep - 3)
        one.label = rest.length > tail ? `${icon}…${rest.slice(rest.length - tail)}` : one.label
        spare = room - 2 - fitted.reduce((sum, item) => sum + width(item.label), 0)
      }
      for (const one of fitted) {
        if (spare >= 0) break
        const cut = Math.max(4, one.label.length + spare)
        if (cut < one.label.length) one.label = `${one.label.slice(0, cut - 1)}…`
        spare = room - 2 - fitted.reduce((sum, item) => sum + width(item.label), 0)
      }
      const last = fitted.length - 1
      return (
        <Box flexDirection="row" flexShrink={1} height={1} overflow="hidden">
          <Text color={fitted[0]?.bg ?? C.surface0} backgroundColor={C.frame}>{'\u{e0b6}'}</Text>
          {fitted.map((one, index) => (
            <Box key={`crumb-${index}`} flexDirection="row" flexShrink={0}>
              <Text color={one.fg} backgroundColor={one.bg} bold={one.bold} wrap="truncate-end">{index === 0 ? `${one.label} ` : ` ${one.label}${index === last ? '' : ' '}`}</Text>
              {index === last ? (
                <Text color={one.bg} backgroundColor={C.frame}>{'\u{e0b4}'}</Text>
              ) : (
                <Text color={one.bg} backgroundColor={fitted[index + 1]?.bg ?? C.frame}>{'\u{e0bc}'}</Text>
              )}
            </Box>
          ))}
        </Box>
      )
    }
    const tabStrip = (key: string, tabs: { id: string; label: string; isOn: boolean }[]) =>
      Client ? (
        <Client
          key={key}
          module="./tabs.tsx"
          props={{ muted: isMenuOpen, tabs }}
          width={tabs.reduce((sum, tab) => sum + tab.label.length, 0)}
          height={1}
        />
      ) : (
        <Box flexDirection="row">{tabs.map(tab => chip(tab.label, tab.isOn))}</Box>
      )
    const header = (middle: unknown) =>
      isNarrow ? (
        <Box flexDirection="row" justifyContent="center" width={e.props.bodyColumns} height={1} overflow="hidden" backgroundColor={C.frame}>
          {middle as never}
        </Box>
      ) : (
        <Box flexDirection="row" justifyContent="space-between" width={e.props.bodyColumns} height={1} overflow="hidden" backgroundColor={C.frame}>
          {tabStrip('tabs-left', [{ id: 'view', label: peekChip, isOn: chosen === 'view' }])}
          {middle as never}
          {tabStrip('tabs-right', [
            { id: 'recent', label: recentChip, isOn: chosen === 'recent' },
            { id: 'gallery', label: galleryChip, isOn: chosen === 'gallery' },
          ])}
        </Box>
      )

    const footer = (info: string, keys: { key: string; label: string; hotkey: string; onPress: () => void; isDim?: boolean; isDefault?: boolean }[]) => (
      <Box flexDirection="row" flexWrap="wrap" columnGap={2} justifyContent="center" width={columns}>
        {info && <Text color={C.overlay1}>{info}</Text>}
        {!isNarrow && info && <Text color={C.surface1}>│</Text>}
        {!isNarrow &&
          keys.map(one => (
            <Button
              key={one.key}
              label={one.label}
              hotkey={one.hotkey}
              plain
              dimColor={one.isDim}
              autoFocus={one.isDefault ? true : undefined}
              onPress={one.onPress}
            />
          ))}
        {!isNarrow && <Text color={C.overlay0}>⌃k menu</Text>}
      </Box>
    )
    const modeKeys = MODES.map(one => ({
      key: `mode-${one.id}`,
      label: one.label,
      hotkey: one.hotkey,
      isDim: one.id !== chosen,
      onPress: () => {
        void update($, mode, () => one.id)
        void update($, page, () => 0)
      },
    }))

    const rule = (label: string, right: string, color: string = C.accent) => {
      const parts = ruleParts(label, right, columns)
      return (
        <Text wrap="truncate-end">
          <Text color={C.surface1}>─</Text>
          <Text color={color} bold>{parts.head}</Text>
          <Text color={C.surface1}>{parts.fill}</Text>
          <Text color={color}>{parts.tail}</Text>
          <Text color={C.surface1}>─</Text>
        </Text>
      )
    }

    const filter = await read($, menuFilter)
    const closeMenu = () => void setMenu($, false)
    const commands: { id: string; icon: string; label: string; hint: string; run: () => void }[] = [
      ...(current
        ? [
            { id: 'peek', icon: ICON.peek, label: 'Peek: show the open file', hint: 'p', run: () => void update($, mode, () => 'view') },
          ]
        : []),
      { id: 'recent', icon: ICON.recent, label: 'Recent: files by last use', hint: 'r', run: () => void update($, mode, () => 'recent') },
      { id: 'gallery', icon: ICON.gallery, label: 'Gallery: files as cards by type', hint: 'g', run: () => void update($, mode, () => 'gallery') },
      ...ROLES.map(one => ({
        id: `role-${one}`,
        icon: one === 'artifacts' ? '◆' : one === 'touched' ? '◇' : '\u{f0c9}',
        label: `Show: ${one}`,
        hint: 'a',
        run: () => void update($, roleFilter, () => one),
      })),
      ...SCOPES.map(one => ({
        id: `scope-${one}`,
        icon: SCOPE_ICON[one],
        label: `Scope: ${one}`,
        hint: 's',
        run: () => void update($, scopeAtom, () => one),
      })),
      { id: 'top', icon: '\u{f062}', label: 'Scroll to top', hint: 'home', run: () => void $.ui.scroll({ in: PANE, to: 'start' }).catch(() => undefined) },
      { id: 'bottom', icon: '\u{f063}', label: 'Scroll to bottom', hint: 'end', run: () => void $.ui.scroll({ in: PANE, to: 'end' }).catch(() => undefined) },
      ...(current
        ? [
            { id: 'open', icon: '\u{f08e}', label: 'Open in its own app', hint: 'o', run: () => void openExternally($, current) },
            ...(current.remote
              ? [{ id: 'refresh', icon: '\u{f021}', label: 'Refresh this page', hint: 'u', run: () => void refresh($, current.href) }]
              : []),
            { id: 'copy', icon: '\u{f0c5}', label: current.remote ? 'Copy link' : 'Copy path', hint: 'c', run: () => void $.ui.copy({ text: current.location }) },
            { id: 'star', icon: '\u{f51a}', label: 'Star or unstar this file', hint: 'f', run: () => void setStar($, current.href) },
          ]
        : []),
      { id: 'close', icon: '\u{f00d}', label: 'Close the pane', hint: 'x', run: () => void $.ui.close({ id: PANE }) },
      ...[...list]
        .reverse()
        .slice(0, 15)
        .map((one, index) => {
          const target = parseHref(one.href)?.path ?? one.href
          const kind = parseHref(one.href) ? kindOf(target) : 'web'
          return {
            id: `file-${index}`,
            icon: iconFor(kind),
            label: `Go to ${target.split('/').pop() || target}`,
            hint: describeAge(one.at, now),
            run: () => void show($, one.href),
          }
        }),
    ]
    const words = filter.toLowerCase().split(/\s+/).filter(Boolean)
    const matches = commands.filter(one => words.every(word => one.label.toLowerCase().includes(word)))
    const runCommand = (one: (typeof commands)[number] | undefined) => {
      if (!one) return
      closeMenu()
      one.run()
    }
    const Input = 'Input' in elements ? elements.Input : undefined
    const menuWidth = Math.max(24, Math.min(64, columns - 8))
    const menu = (
      <Box flexDirection="column" width={menuWidth}>
        <Text wrap="truncate-end">
          <Text color={BASE.surface1}>─</Text>
          <Text color={BASE.accent} bold> COMMANDS </Text>
          <Text color={BASE.surface1}>{'─'.repeat(Math.max(1, menuWidth - 12))}</Text>
        </Text>
        {Input && (
          <Box
            key="menu-filter-frame"
            flexDirection="row"
            width={menuWidth}
            borderStyle="round"
            borderColor={BASE.accent}
            paddingX={1}
            marginY={1}
          >
            <Text color={BASE.accent}>{'\u{f002}  '}</Text>
            <Box flexGrow={1}>
          <Input
            key="menu-filter"
            placeholder="type to filter · Enter runs the first match"
            value={filter}
            autoFocus
            onInput={(value: string) => void update($, menuFilter, () => value)}
            onSubmit={() => runCommand(matches[0])}
          />
            </Box>
          </Box>
        )}
        {matches.length === 0 && <Text color={BASE.overlay0}>No command matches.</Text>}
        {matches.slice(0, 20).map(one => (
          <Box key={`menu-row-${one.id}`} flexDirection="row" justifyContent="space-between" width={menuWidth}>
            <Box flexDirection="row" flexShrink={1}>
              <Text color={BASE.accent}>{`${one.icon}  `}</Text>
              <Button key={`menu-${one.id}`} label={one.label} plain onPress={() => runCommand(one)} />
            </Box>
            <Text color={BASE.overlay0}>{one.hint}</Text>
          </Box>
        ))}
        <Button key="menu-close" label="Close menu" plain dimColor onPress={closeMenu} />
      </Box>
    )

    const offset = at
    const jumpTo = (key: string) => void $.ui.scroll({ in: PANE, to: { key }, block: 'start' }).catch(() => undefined)
    const realBody = Math.max(1, contentRows - PAGE_TOP - FOOTER_ROWS - 1)
    const scale = contentRows > 0 ? realBody / Math.max(1, estimatedRows) : 1
    const rowOf = (index: number) => PAGE_TOP + (blockStarts[index] ?? 0) * scale
    const keyJumps = (keys: readonly string[]) => ({
      next: () => {
        const found = keys.findIndex((_, i) => rowOf(i) > offset + PAGE_TOP + 1)
        const key = keys[found]
        if (found < 0 || !key) void $.ui.scroll({ in: PANE, to: 'end' }).catch(() => undefined)
        else jumpTo(key)
      },
      prev: () => {
        const found = [...keys.keys()].reverse().find(i => rowOf(i) < offset + PAGE_TOP - 1)
        const key = found === undefined ? undefined : keys[found]
        if (!key) void $.ui.scroll({ in: PANE, to: 'start' }).catch(() => undefined)
        else jumpTo(key)
      },
    })
    const blockJumps = (count: number, prefix: string) => keyJumps(Array.from({ length: count }, (_, i) => `${prefix}-${i}`))
    type Key = { key: string; label: string; hotkey: string; onPress: () => void; isDim?: boolean; isDefault?: boolean }
    const frame = (middle: unknown, content: unknown, info: string, keys: Key[], pageBg: string = C.panelBg) => (
      <Box
        flexDirection="column"
        alignItems="center"
        backgroundColor={C.appBg}
        minHeight={e.props.scroll.bodyRows}
        width={e.props.bodyColumns}
      >
        <Box height={HEADER_ROWS} />
        <Box flexDirection="column" width={pageWidth} backgroundColor={pageBg} paddingX={isNarrow ? 0 : 2} paddingY={1}>
          <Box flexDirection="column" width={textWidth}>
            {content as never}
          </Box>
        </Box>
        <Box height={FOOTER_ROWS} />
        <Box
          position="absolute"
          top={offset}
          left={0}
          width={e.props.bodyColumns}
          height={HEADER_ROWS}
          flexDirection="column"
          alignItems="center"
          backgroundColor={C.appBg}
        >
          {header(middle)}
        </Box>
        <Box
          position="absolute"
          top={offset + e.props.scroll.bodyRows - FOOTER_ROWS}
          left={0}
          width={e.props.bodyColumns}
          height={FOOTER_ROWS}
          flexDirection="column"
          alignItems="center"
          justifyContent="flex-end"
          backgroundColor={C.appBg}
        >
          {footer(info, keys)}
        </Box>
        {isMenuOpen && (
          <Box
            position="absolute"
            top={offset + HEADER_ROWS + 2}
            left={Math.max(0, Math.floor((e.props.bodyColumns - menuWidth - 4) / 2))}
            width={menuWidth + 4}
            flexDirection="column"
            backgroundColor={BASE.panelBg}
            paddingX={2}
            paddingY={1}
          >
            {menu as never}
          </Box>
        )}
      </Box>
    )
    const selectKeys: Key[] = [
      { key: 'next', label: 'Down', hotkey: 'j', onPress: () => void moveSelection($, 'down') },
      { key: 'prev', label: 'Up', hotkey: 'k', onPress: () => void moveSelection($, 'up') },
      { key: 'left', label: 'Left', hotkey: 'h', onPress: () => void moveSelection($, 'left') },
      { key: 'right', label: 'Right', hotkey: 'l', onPress: () => void moveSelection($, 'right') },
      {
        key: 'open-selected',
        label: '⏎ Open',
        hotkey: 'o',
        onPress: () => void selectedHref($).then(href => (href ? show($, href) : undefined)),
      },
      {
        key: 'star-selected',
        label: 'Star',
        hotkey: 'f',
        onPress: () => void selectedHref($).then(href => (href ? setStar($, href).then(() => undefined) : undefined)),
      },
    ]
    const closeKey: Key = { key: 'close', label: 'Close', hotkey: 'x', onPress: () => void $.ui.close({ id: PANE }) }

    if (chosen !== 'view' || !current) {
      const scope = await read($, scopeAtom)
      const role = await read($, roleFilter)
      const starList = await read($, stars)
      const starSet = new Set(starList)
      const raw = scope === 'session' ? await sessionEntries($, list) : scopeEntries($, scope, cwd, now)
      const entries = raw ? filterRole(withMentions(raw, list), role) : null
      const roleKey: Key = {
        key: 'role',
        label: `Show: ${role}`,
        hotkey: 'a',
        onPress: () => void update($, roleFilter, one => nextOf(ROLES, one)),
      }
      const scopeNote = role === 'all' ? scope : `${scope} · ${role}`
      const scopeKey: Key = {
        key: 'scope',
        label: `Scope: ${scope}`,
        hotkey: 's',
        onPress: () => void update($, scopeAtom, one => nextOf(SCOPES, one)),
      }
      const describe = (one: FileEntry) => {
        const age = describeAge(Math.max(one.mentionedAt, one.mtimeMs), now)
        const where = one.worktree && scope === 'repo' ? `${one.worktree} · ` : ''
        return { where, age }
      }
      const looks = (one: FileEntry) => ({
        href: one.href,
        isStarred: starSet.has(one.href),
        favicon: one.favicon && Image ? pixels.get(one.favicon) : undefined,
        icon: iconFor(one.kind),
        color: colorFor(one.kind),
        name: one.name,
        folder: scope === 'session' ? shortPath(one.folder, cwd, home) : one.folder,
      })
      const scopeCrumb = crumbs([
        { label: `${SCOPE_ICON[scope]} ${scope}`, fg: C.appBg, bg: C.accent, bold: true },
      ])
      const waiting = <Text color={C.overlay0}>Loading files…</Text>

      const favMentions = starList.map(href => list.find(one => one.href === href) ?? { href, at: 0, count: 0 })
      const favourites = filterRole(withMentions(await sessionEntries($, favMentions), list), role)
      const rest = entries ? entries.filter(one => !starSet.has(one.href)) : null
      const perRow = gridColumns(textWidth, CARD_MIN, CARD_GAP)
      const cardWidth = Math.floor((textWidth - (perRow - 1) * CARD_GAP) / perRow)
      const section = (label: string, right: string) => (
        <Text wrap="truncate-end">
          <Text color={C.accent} bold>{`${label} `}</Text>
          <Text color={C.surface1}>{'─'.repeat(Math.max(1, textWidth - label.length - right.length - 2))}</Text>
          <Text color={C.overlay0}>{right ? ` ${right}` : ''}</Text>
        </Text>
      )
      const keys: string[] = []
      const starts: number[] = []
      let cursor = 0
      const selected = await read($, cursorAtom)
      const nav: NavItem[] = []
      navOrder = nav
      let navLine = 0
      const cardGrid = (list: readonly FileEntry[], prefix: string) => {
        const rowsOfCards = Array.from({ length: Math.ceil(list.length / perRow) }, (_, r) => list.slice(r * perRow, r * perRow + perRow))
        const firstNav = nav.length
        rowsOfCards.forEach((cards, r) => {
          keys.push(`${prefix}-${r}`)
          starts.push(cursor + r * (CARD_ROWS + 1))
          const line = navLine++
          cards.forEach((one, col) => nav.push({ href: one.href, key: `${prefix}-${r}`, line, col }))
        })
        cursor += rowsOfCards.length * (CARD_ROWS + 1)
        return rowsOfCards.map((cards, r) => (
          <Box key={`${prefix}-${r}`} flexDirection="row" columnGap={CARD_GAP} marginBottom={1}>
            {cards.map((one, c) => {
              const index = firstNav + r * perRow + c
              const isSelected = index === selected
              const look = looks(one)
              const { where, age } = describe(one)
              const inner = Math.max(4, cardWidth - 7)
              return (
                <Box
                  key={`${prefix}-${r}-${c}`}
                  flexDirection="column"
                  width={cardWidth}
                  height={CARD_ROWS}
                  paddingX={2}
                  paddingY={1}
                  backgroundColor={isSelected ? C.surface0 : C.panelBg}
                  hover={{ backgroundColor: C.surface0 }}
                >
                  <Box flexDirection="row">
                    {look.favicon && !look.isStarred && Image && (
                      <Image key={`favicon-${index}`} source={{ png: look.favicon }} columns={2} rows={1} alt={look.icon} />
                    )}
                    <Button
                      key={`item-${index}`}
                      label={look.isStarred ? '\u{f51a}' : look.favicon ? ' ' : look.icon}
                      plain
                      autoFocus={isSelected ? true : undefined}
                      onPress={() => void selectAndOpen($, index)}
                    />
                    <Box key={`name-${index}`}>
                      <Text color={isSelected ? C.accent : C.text} bold hover={{ color: C.accent }}>{` ${look.name.slice(0, inner)}`}</Text>
                    </Box>
                  </Box>
                  <Text color={C.overlay0} wrap="truncate-start">{look.folder || ' '}</Text>
                  <Text color={isSelected ? C.overlay1 : C.overlay0} wrap="truncate-end">{`${where}${age} · ${one.status ?? describeSize(one.size)}`}</Text>
                </Box>
              )
            })}
          </Box>
        ))
      }
      const favouritesBlock = (shownFavs: readonly FileEntry[]) => {
        if (!shownFavs.length) return null
        cursor += 2
        const grid = cardGrid(shownFavs, 'favs')
        cursor += 1
        return (
          <Box flexDirection="column" width={textWidth}>
            {section('FAVOURITES', `${shownFavs.length}`)}
            <Box height={1} />
            {grid}
          </Box>
        )
      }

      const groupsOf = (items: readonly FileEntry[]) =>
        [
          { id: 'artifacts', label: 'ARTIFACTS', items: items.filter(one => one.role === 'artifact') },
          { id: 'touched', label: 'TOUCHED', items: items.filter(one => one.role === 'touched') },
          { id: 'files', label: scope.toUpperCase(), items: items.filter(one => !one.role) },
        ].filter(group => group.items.length > 0)

      if (chosen === 'gallery') {
        const type = await read($, galleryType)
        const sort = await read($, gallerySort)
        const query = await read($, galleryFilter)
        const favs = selectEntries(favourites, type, query, sort)
        const picked = rest ? selectEntries(rest, type, query, sort).slice(0, 240) : []
        const Input = 'Input' in elements ? elements.Input : undefined
        cursor = 2
        const favBlock = favouritesBlock(favs)
        const groups = groupsOf(picked).map(group => {
          cursor += 2
          const grid = cardGrid(group.items, group.id)
          cursor += 1
          return { ...group, grid }
        })
        blockStarts = starts
        estimatedRows = Math.max(1, cursor)
        const jumps = keyJumps(keys)
        const content = (
          <Box flexDirection="column" width={textWidth}>
            <Box flexDirection="row" columnGap={2} width={textWidth}>
              {Input && (
                <Box flexGrow={1}>
                  <Input
                    key="gallery-filter"
                    placeholder="filter by name or folder"
                    value={query}
                    onInput={(value: string) => void update($, galleryFilter, () => value)}
                    onSubmit={(value: string) => void update($, galleryFilter, () => value)}
                  />
                </Box>
              )}
              <Text color={C.overlay1}>{`${type} · ${sort}`}</Text>
            </Box>
            <Box height={1} />
            {favBlock}
            {!rest && waiting}
            {rest && picked.length === 0 && favs.length === 0 && <Text color={C.overlay0}>No files match.</Text>}
            {groups.map(group => (
              <Box key={`group-${group.id}`} flexDirection="column" width={textWidth}>
                {section(group.label, `${group.items.length}`)}
                <Box height={1} />
                {group.grid}
              </Box>
            ))}
          </Box>
        )
        return frame(
          scopeCrumb,
          content,
          rest ? `${favs.length + picked.length} ${type === 'all' ? 'files' : type} · ${scopeNote}` : 'loading…',
          [
            ...modeKeys,
            scopeKey,
            roleKey,
            { key: 'type', label: 'Type', hotkey: 't', onPress: () => void update($, galleryType, one => nextOf(TYPES, one)) },
            { key: 'sort', label: 'Sort', hotkey: 'n', onPress: () => void update($, gallerySort, one => nextOf(SORTS, one)) },
            ...selectKeys,
            closeKey,
          ],
          C.appBg,
        )
      }

      const favs = selectEntries(favourites, 'all', '', 'recent')
      const recentList = rest ? selectEntries(rest, 'all', '', 'recent').slice(0, 300) : []
      cursor = 0
      const favBlock = favouritesBlock(favs)
      const rowList = (items: readonly FileEntry[], prefix: string) => {
        const chunks = Array.from({ length: Math.ceil(items.length / LIST_CHUNK) }, (_, i) =>
          items.slice(i * LIST_CHUNK, i * LIST_CHUNK + LIST_CHUNK),
        )
        const firstNav = nav.length
        chunks.forEach((chunk, i) => {
          keys.push(`${prefix}-${i}`)
          starts.push(cursor)
          cursor += chunk.length
          for (const one of chunk) nav.push({ href: one.href, key: `${prefix}-${i}`, line: navLine++, col: 0 })
        })
        return chunks.map((chunk, i) => (
          <Box key={`${prefix}-${i}`} flexDirection="column" width={textWidth}>
            {chunk.map((one, j) => {
              const index = firstNav + i * LIST_CHUNK + j
              const isSelected = index === selected
              const look = looks(one)
              const { where, age } = describe(one)
              const count = one.mentions > 1 ? `${one.mentions}× · ` : ''
              const meta = `${one.status ? `${one.status} · ` : ''}${where}${count}${age}`
              const leftWidth = Math.max(4, textWidth - meta.length - 1)
              const nameRoom = Math.max(8, Math.floor((leftWidth - 3) * 0.6))
              return (
                <Box
                  key={`${prefix}-${i}-${j}`}
                  height={1}
                  flexDirection="row"
                  justifyContent="space-between"
                  width={textWidth}
                  backgroundColor={isSelected ? C.surface0 : undefined}
                  hover={{ backgroundColor: C.surface0 }}
                >
                  <Box flexDirection="row" width={leftWidth} height={1} overflow="hidden">
                    {look.favicon && !look.isStarred && Image && (
                      <Box flexShrink={0}>
                        <Image key={`favicon-${index}`} source={{ png: look.favicon }} columns={2} rows={1} alt={look.icon} />
                      </Box>
                    )}
                    <Box flexShrink={0}>
                      <Button
                        key={`item-${index}`}
                        label={look.isStarred ? '\u{f51a}' : look.favicon ? ' ' : look.icon}
                        plain
                        autoFocus={isSelected ? true : undefined}
                        onPress={() => void selectAndOpen($, index)}
                      />
                    </Box>
                    <Box key={`name-${index}`} flexShrink={0}>
                      <Text color={isSelected ? C.accent : C.text} bold={isSelected} hover={{ color: C.accent }} wrap="truncate-end">{`  ${fitName(look.name, nameRoom)}`}</Text>
                    </Box>
                    <Box flexShrink={1} flexGrow={1} overflow="hidden">
                      <Text color={C.overlay0} wrap="truncate-middle">{look.folder ? `  ${look.folder}` : ''}</Text>
                    </Box>
                  </Box>
                  <Box flexShrink={0} height={1}>
                    <Text color={C.overlay0}>{meta}</Text>
                  </Box>
                </Box>
              )
            })}
          </Box>
        ))
      }
      const groups = groupsOf(recentList).map(group => {
        cursor += 2
        const list = rowList(group.items, group.id)
        cursor += 1
        return { ...group, list }
      })
      blockStarts = starts
      estimatedRows = Math.max(1, cursor)
      const jumps = keyJumps(keys)
      const content = (
        <Box flexDirection="column" width={textWidth}>
          {favBlock}
          {!rest && waiting}
          {rest && recentList.length === 0 && favs.length === 0 && (
            <Text color={C.overlay0}>
              {scope === 'session' ? 'Nothing mentioned yet. Paths and links in replies land here.' : 'No files found here.'}
            </Text>
          )}
          {groups.map(group => (
            <Box key={`group-${group.id}`} flexDirection="column" width={textWidth} marginBottom={1}>
              {section(group.label, `${group.items.length}`)}
              <Box height={1} />
              {group.list as never}
            </Box>
          ))}
        </Box>
      )
      return frame(
        scopeCrumb,
        content,
        rest ? `${favs.length} favourites · ${recentList.length} files · ${scopeNote}` : 'loading…',
        [
          ...modeKeys,
          scopeKey,
          roleKey,
          ...selectKeys,
          closeKey,
        ],
        C.appBg,
      )
    }

    let png = current.image ? pixels.get(current.image.file) : undefined
    if (current.image && !png) {
      png = await $.fs.read(current.image.file, { as: 'bytes' }).then(
        bytes => bytes.base64,
        () => undefined,
      )
      if (png) pixels.set(current.image.file, png)
    }
    const kind = current.kind
    const path = parseHref(current.href)?.path ?? current.href
    const embed = (key: string, icon: string, label: string, detail: string, color: string, child: unknown) => (
      <Box key={key} flexDirection="column" width={textWidth} backgroundColor={C.appBg} paddingX={1} paddingY={1}>
        <Box flexDirection="row" width={textWidth - 2}>
          <Text color={color}>{`${icon} `}</Text>
          <Text color={color} bold>{label}</Text>
          <Text color={C.overlay1} wrap="truncate-end">{detail ? ` ${detail}` : ''}</Text>
        </Box>
        <Text color={C.panelBg} wrap="truncate-end">{'─'.repeat(Math.max(1, textWidth - 2))}</Text>
        <Box flexDirection="column" width={textWidth - 2}>
          {child as never}
        </Box>
      </Box>
    )
    const folderPath = path.slice(0, Math.max(0, path.length - current.title.length - 1))
    const folder = current.root && folderPath.startsWith(current.root)
      ? folderPath.slice(current.root.length + 1)
      : shortPath(folderPath, cwd, home)

    const newBlocks = () => {
      const drawnParts: unknown[] = []
      const partRows: number[] = []
      const partHeadings: string[] = []
      const note = (rows: number, heading = '') => {
        while (partRows.length < drawnParts.length) {
          partRows.push(rows)
          partHeadings.push(heading)
        }
      }
      return { drawnParts, partRows, partHeadings, note }
    }
    const settleBlocks = (drawnParts: unknown[], partRows: number[], partHeadings: string[]) => {
      for (let i = partRows.length; i < drawnParts.length; i++) {
        partRows.push(IMAGE_ROWS)
        partHeadings.push('')
      }
      blockStarts = []
      blockHeadings = []
      let running = 0
      let lastHeading = ''
      for (const [i, rows] of partRows.entries()) {
        blockStarts.push(running)
        lastHeading = partHeadings[i] || lastHeading
        blockHeadings.push(lastHeading)
        running += rows + 1
      }
      estimatedRows = Math.max(1, running)
      const topBlock = [...blockStarts.keys()].reverse().find(i => rowOf(i) <= offset + PAGE_TOP + 1) ?? 0
      topBlockKey = `block-${topBlock}`
      const heading = blockHeadings[topBlock] ?? ''
      const maxScroll = Math.max(0, contentRows - e.props.scroll.bodyRows)
      const percent = maxScroll > 0 ? Math.min(100, Math.round((offset / maxScroll) * 100)) : 100
      return {
        body: (
          <Box flexDirection="column" width={textWidth}>
            {drawnParts.map((part, blockIndex) => (
              <Box key={`block-${blockIndex}`} flexDirection="column" marginBottom={1}>
                {part as never}
              </Box>
            ))}
          </Box>
        ),
        jumps: blockJumps(drawnParts.length, 'block'),
        position: `${percent}%${heading ? ` · § ${heading}` : ''}`,
      }
    }

    let body: unknown = null
    let position = ''
    let jumps: { next: () => void; prev: () => void } = { next: () => {}, prev: () => {} }
    if (current.remote) {
      const remote = current.remote
      const record = remote.record
      const { drawnParts, partRows, partHeadings, note } = newBlocks()
      const sectionRule = (key: string, label: string, right = '') => {
        const head = `${label.toUpperCase()} `
        const tail = right ? ` ${right}` : ''
        drawnParts.push(
          <Text key={key} wrap="truncate-end">
            <Text color={C.accent} bold>{head}</Text>
            <Text color={C.surface1}>{'─'.repeat(Math.max(1, textWidth - head.length - tail.length))}</Text>
            <Text color={C.overlay0}>{tail}</Text>
          </Text>,
        )
        note(1, label)
      }
      const kindColor = (kind: string) => (isMenuOpen ? mute(colorFor(kind)) : colorFor(kind))
      const ghRef = record?.kind.startsWith('gh-') ? parseRef(record.address) : null
      const refs = refContext(ghRef?.owner && ghRef.repo ? `${ghRef.owner}/${ghRef.repo}` : undefined)
      const memoBase = `${current.href}|${remote.fetchedAt}|${textWidth}|${refs.teamKeys?.length}|${refs.workspace}`
      const markdownBlocks = (key: string, text: string, heading: string, indent = 0) => {
        const memoKey = `${memoBase}|${key}`
        let chunks = blockMemo.get(memoKey)
        if (!chunks) {
          if (blockMemo.size > MAX_BLOCK_MEMO) blockMemo.clear()
          chunks = chunkMarkdown(linkify(text, () => null, refs)).map(chunk => ({ chunk, rows: estimateRows(chunk, textWidth - indent) }))
          blockMemo.set(memoKey, chunks)
        }
        for (const [i, { chunk, rows }] of chunks.entries()) {
          drawnParts.push(
            <Box key={`${key}-${i}`} marginLeft={indent}>
              <Markdown dimColor={isMenuOpen} key={`${key}-md-${i}`} text={chunk} onLinkPress={link => void pressLink($, link.href)} />
            </Box>,
          )
          note(rows, heading)
        }
      }
      if (!record) {
        const message = failureText(remote.failure ?? 'offline')
        drawnParts.push(
          <Box key="remote-failure" flexDirection="column">
            <Text color={C.red} bold>{message.title}</Text>
            <Text color={C.subtext0}>{message.hint}</Text>
            <Text color={C.overlay0}>Press o to open it in the browser.</Text>
          </Box>,
        )
        note(3)
      } else {
        const favicon = remote.favicon && pixels.get(remote.favicon.file)
        drawnParts.push(
          <Box key="remote-title" flexDirection="row" width={textWidth}>
            {favicon && Image ? (
              <Box flexShrink={0} marginRight={1}>
                <Image key="remote-favicon" source={{ png: favicon }} columns={2} rows={1} alt={iconFor(record.kind)} />
              </Box>
            ) : (
              <Text color={kindColor(record.kind)}>{`${iconFor(record.kind)} `}</Text>
            )}
            <Box flexShrink={1}>
              <Text color={C.text} bold>{record.title}</Text>
            </Box>
          </Box>,
        )
        note(Math.ceil((record.title.length + 3) / textWidth), record.title)
        const labelWidth = Math.min(14, Math.max(0, ...record.meta.map(one => (META_ICON[one.label] ? 1 : one.label.length))) + 2)
        drawnParts.push(
          embed('remote-meta', iconFor(record.kind), 'DETAILS', record.status ?? '', kindColor(record.kind), (
            <Box flexDirection="column">
              {record.meta.map((one, i) => (
                <Text key={`meta-${i}`} wrap="truncate-end">
                  <Text color={C.overlay0}>{(META_ICON[one.label] ?? one.label).padEnd(labelWidth)}</Text>
                  <Text color={C.text}>{one.value}</Text>
                </Text>
              ))}
            </Box>
          )),
        )
        note(record.meta.length + 4, 'Details')
        if (record.stats) {
          const ci = record.stats.ci
          const ciColor = { bad: C.red, wait: C.yellow, ok: C.green, none: C.overlay1 }[record.stats.ciTone]
          drawnParts.push(
            embed('remote-stats', ICON['gh-pr'], 'CHANGES', `${record.stats.changedFiles} files`, C.green, (
              <Box flexDirection="column">
                <Text>
                  <Text color={C.green}>{`+${record.stats.additions}`}</Text>
                  <Text color={C.overlay0}>{'  '}</Text>
                  <Text color={C.red}>{`−${record.stats.deletions}`}</Text>
                  <Text color={C.overlay0}>{`  ·  ${record.stats.changedFiles} files changed`}</Text>
                </Text>
                <Text wrap="truncate-end">
                  <Text color={C.overlay0}>{'CI  '}</Text>
                  <Text color={ciColor}>{ci}</Text>
                </Text>
              </Box>
            )),
          )
          note(6, 'Changes')
        }
        const preview = remote.preview && pixels.get(remote.preview.file)
        if (record.og && (record.og.description || preview)) {
          drawnParts.push(
            embed('remote-preview', ICON.web, 'PREVIEW', record.og.siteName ?? '', C.peach, (
              <Box flexDirection="column">
                {preview && Image && remote.preview && (
                  <Image key="remote-preview-image" source={{ png: preview }} {...imageBox(remote.preview.width, remote.preview.height, textWidth - 4, IMAGE_ROWS - 2)} alt="preview image" />
                )}
                {record.og.description && <Text color={C.subtext0}>{record.og.description}</Text>}
              </Box>
            )),
          )
          note((preview ? IMAGE_ROWS : 0) + estimateRows(record.og.description ?? '', textWidth - 2) + 4, 'Preview')
        }
        const lists = () => {
          for (const [li, list] of (record.lists ?? []).entries()) {
            const more = list.total > list.items.length || list.isPartial
            sectionRule(`list-head-${li}`, list.heading, more ? `${list.items.length} of ${list.isPartial ? `${list.total}+` : list.total}` : `${list.total}`)
            drawnParts.push(
              <Box key={`list-${li}`} flexDirection="column" width={textWidth}>
                {list.items.length === 0 && <Text color={C.overlay0}>None open.</Text>}
                {list.items.map((item, i) => {
                  const meta = [item.status, item.meta].filter(Boolean).join(' · ')
                  return (
                    <Box key={`list-${li}-${i}`} flexDirection="row" justifyContent="space-between" width={textWidth} height={1} hover={{ backgroundColor: C.surface0 }}>
                      <Box flexShrink={1} overflow="hidden" height={1}>
                        <Button key={`list-item-${li}-${i}`} label={fitName(item.title, Math.max(8, textWidth - meta.length - 2))} plain onPress={() => void openFromPage($, item.href)} />
                      </Box>
                      <Box flexShrink={0}>
                        <Text color={C.overlay0}>{meta}</Text>
                      </Box>
                    </Box>
                  )
                })}
                {more && <Text color={C.overlay0}>{`showing ${list.items.length} of ${list.isPartial ? 'many' : list.total} · press o for the rest in the browser`}</Text>}
              </Box>,
            )
            note(Math.max(1, list.items.length) + (more ? 1 : 0), list.heading)
          }
        }
        const description = () => {
          if (!record.body?.trim()) return
          const label = record.kind === 'gh-repo' ? 'README' : record.kind === 'web' ? 'Page' : 'Description'
          sectionRule('body-head', label)
          markdownBlocks('body', record.body, label)
        }
        if (record.kind === 'gh-repo') {
          lists()
          description()
        } else {
          description()
          lists()
        }
        const comments = record.comments
        if (comments && comments.total > 0) {
          const shown = comments.shown.length
          const count = shown < comments.total ? `showing latest ${shown} of ${comments.total}` : `${comments.total}`
          sectionRule('comments-head', 'Comments', comments.inline ? `${count} · ${comments.inline} inline` : count)
          for (const [i, one] of comments.shown.entries()) {
            const indent = (one.depth ?? 0) * 2
            const when = Number.isNaN(Date.parse(one.at)) ? one.at : describeAge(Date.parse(one.at), now)
            drawnParts.push(
              <Box key={`comment-${i}`} marginLeft={indent}>
                <Text wrap="truncate-end">
                  <Text color={C.accent} bold>{one.author}</Text>
                  <Text color={C.overlay0}>{` · ${when}${one.isReview ? ' · review' : ''}`}</Text>
                </Text>
              </Box>,
            )
            note(1, 'Comments')
            markdownBlocks(`comment-${i}-body`, one.body || '*(empty)*', 'Comments', indent)
          }
        }
      }
      ;({ body, jumps, position } = settleBlocks(drawnParts, partRows, partHeadings))
    } else if (current.markdown !== undefined) {
      const source = fullText.get(current.href) ?? current.markdown
      const { drawnParts, partRows, partHeadings, note } = newBlocks()
      let index = 0
      for (const part of segmentsOf(source)) {
        index += 1
        if (part.kind === 'markdown') {
          for (const [chunkIndex, chunk] of chunkMarkdown(part.text).entries()) {
            drawnParts.push(
              <Markdown dimColor={isMenuOpen} key={`body-${index}-${chunkIndex}`} text={chunk} onLinkPress={link => void pressLink($, link.href)} />,
            )
            note(estimateRows(chunk, textWidth))
          }
          continue
        }
        if (part.kind === 'heading') {
          if (part.level === 1) {
            drawnParts.push(
              <Box key={`heading-${index}`} flexDirection="column">
                <Text color={C.accent} bold wrap="truncate-end">{part.text.toUpperCase()}</Text>
                <Text color={C.surface1} wrap="truncate-end">{'━'.repeat(textWidth)}</Text>
              </Box>,
            )
          } else if (part.level === 2) {
            const label = `${part.text.toUpperCase()} `
            drawnParts.push(
              <Box key={`heading-${index}`}>
                <Text wrap="truncate-end">
                  <Text color={C.accent} bold>{label}</Text>
                  <Text color={C.surface1}>{'─'.repeat(Math.max(1, textWidth - label.length))}</Text>
                </Text>
              </Box>,
            )
          } else {
            drawnParts.push(
              <Box key={`heading-${index}`}>
                <Text wrap="truncate-end">
                  {part.level === 3 && <Text color={C.accent}>▸ </Text>}
                  <Text color={part.level === 3 ? C.text : C.overlay1} bold>{part.text}</Text>
                </Text>
              </Box>,
            )
          }
          note(part.level === 1 ? 2 : 1, part.text)
          continue
        }
        if (part.kind === 'code') {
          if (part.lang === 'peek-diagram') {
            drawnParts.push(
              embed(`diagram-${index}`, ICON.mermaid, 'DIAGRAM', part.info, C.mauve, (
                <Text color={C.subtext0}>{part.text}</Text>
              )),
            )
          } else if (part.lang === 'mermaid') {
            drawnParts.push(
              embed(`diagram-${index}`, ICON.mermaid, 'DIAGRAM', `${diagramType(part.text)} · press o to see it rendered`, C.mauve, (
                isMenuOpen ? <Text color={C.overlay1}>{part.text}</Text> : <Code source={part.text} language="mermaid" wrap="truncate-end" />
              )),
            )
          } else {
            drawnParts.push(
              embed(`code-${index}`, ICON.text, 'CODE', part.lang || 'text', C.blue, (
                isMenuOpen ? <Text color={C.overlay1}>{part.text || ' '}</Text> : <Code source={part.text || ' '} language={part.lang || undefined} wrap="truncate-end" />
              )),
            )
          }
          note(part.text.split('\n').length + 4)
          continue
        }
        if (part.kind === 'tasks' && Client) {
          const rowCount = taskRows(part.items, textWidth).length
          drawnParts.push(
            <Client
              key={`tasks-${index}`}
              module="./tasks.tsx"
              props={{ muted: isMenuOpen, width: textWidth, items: part.items }}
              width={textWidth}
              height={rowCount}
            />,
          )
          note(rowCount)
          continue
        }
        if (part.kind === 'tasks') {
          drawnParts.push(
            <Box key={`tasks-${index}`} flexDirection="column" width={textWidth}>
              {part.items.map(item => {
                const toggle = () => void pressLink($, `${item.href}#task-${item.line}`)
                const scope = `task-${item.line}`
                return (
                  <Box key={`task-row-${item.line}`} flexDirection="row" marginLeft={item.depth * 2}>
                    <Button
                      key={`task-box-${item.line}`}
                      label={item.isDone ? '\u{f0135} ' : '\u{f0131} '}
                      plain
                      dimColor={item.isDone}
                      hover={{ scope, color: C.accent }}
                      onPress={toggle}
                    />
                    <Box flexShrink={1}>
                      <Button
                        key={`task-${item.line}`}
                        label={plainInline(item.text)}
                        plain
                        dimColor={item.isDone}
                        hover={{ scope, color: C.accent, strikethrough: !item.isDone }}
                        onPress={toggle}
                      />
                    </Box>
                  </Box>
                )
              })}
            </Box>,
          )
          note(part.items.reduce((rows, item) => rows + Math.max(1, Math.ceil(item.text.length / Math.max(10, textWidth - 2 - item.depth * 2))), 0))
          continue
        }
        if (part.kind === 'quote') {
          drawnParts.push(
            <Box key={`quote-${index}`} flexDirection="row" backgroundColor={C.surface0}>
              <Box width={1} backgroundColor={C.accent} />
              <Box flexDirection="column" paddingX={1} flexShrink={1}>
                <Markdown dimColor={isMenuOpen}
                  key={`quote-text-${index}`}
                  text={part.text
                    .split('\n')
                    .map(line => (line.trim() ? `*${line.trim()}*` : ''))
                    .join('\n')}
                  onLinkPress={link => void pressLink($, link.href)}
                />
              </Box>
            </Box>,
          )
          note(estimateRows(part.text, textWidth - 3))
          continue
        }
        const picture = await docImage($, part.src, path)
        const detail = part.alt || part.src
        if (picture?.png && Image) {
          drawnParts.push(
            embed(`image-${index}`, ICON.image, 'IMAGE', detail, C.teal, (
              <Image
                key={`doc-image-${index}`}
                source={{ png: picture.png }}
                {...imageBox(picture.width, picture.height, textWidth - 4, IMAGE_ROWS - 2)}
                alt={`${part.alt || 'image'} (this terminal cannot draw images)`}
              />
            )),
          )
        } else {
          const target = picture ? fileHref(picture.abs) : part.src
          drawnParts.push(
            embed(`image-${index}`, ICON.image, 'IMAGE', detail, C.teal, (
              <Markdown dimColor={isMenuOpen}
                key={`body-${index}`}
                text={picture ? `[open ${part.src}](${target})` : `*not found: ${part.src}*`}
                onLinkPress={link => void pressLink($, link.href)}
              />
            )),
          )
        }
      }
      ;({ body, jumps, position } = settleBlocks(drawnParts, partRows, partHeadings))
    } else if (current.table) {
      const table = current.table
      const widths = columnWidths([table.header, ...table.rows], textWidth)
      const line = (row: readonly string[]) => widths.map((w, c) => fitCell(row[c] ?? '', w)).join('  ')
      const chunks = Array.from({ length: Math.ceil(table.rows.length / LIST_CHUNK) }, (_, i) =>
        table.rows.slice(i * LIST_CHUNK, i * LIST_CHUNK + LIST_CHUNK),
      )
      blockStarts = chunks.map((_, i) => 2 + i * LIST_CHUNK)
      estimatedRows = Math.max(1, 2 + table.rows.length)
      body = (
        <Box flexDirection="column" width={textWidth}>
          <Text color={C.accent} bold wrap="truncate-end">{line(table.header)}</Text>
          <Text color={C.surface1} wrap="truncate-end">{widths.map(w => '─'.repeat(w)).join('  ')}</Text>
          {chunks.map((chunk, i) => (
            <Box key={`chunk-${i}`} flexDirection="column">
              {chunk.map((row, r) => (
                <Text
                  key={`table-row-${i * LIST_CHUNK + r}`}
                  color={C.text}
                  backgroundColor={(i * LIST_CHUNK + r) % 2 ? C.cardBg : undefined}
                  wrap="truncate-end"
                >
                  {line(row)}
                </Text>
              ))}
            </Box>
          ))}
          {table.total > table.rows.length && (
            <Text color={C.overlay0}>{`… ${table.total - table.rows.length} more rows. Press o to open the whole file.`}</Text>
          )}
        </Box>
      )
      jumps = blockJumps(chunks.length, 'chunk')
      const first = Math.max(1, Math.min(table.rows.length, offset - PAGE_TOP - 1))
      position = `row ${first} of ${table.total}`
    } else if (current.dir) {
      const folderPath = path
      const parent = folderPath.slice(0, Math.max(1, folderPath.lastIndexOf('/')))
      const items = [
        ...(folderPath !== '/' ? [{ href: fileHref(parent), icon: ICON.up, color: C.overlay1, name: '..', folder: '', meta: 'up', canStar: false }] : []),
        ...current.dir.map(one => {
          const kindOfEntry = one.isDir ? 'folder' : kindOf(one.name)
          return {
            href: fileHref(`${folderPath}/${one.name}`),
            icon: iconFor(kindOfEntry),
            color: colorFor(kindOfEntry),
            name: one.isDir ? `${one.name}/` : one.name,
            folder: '',
            meta: one.isDir ? describeAge(one.mtimeMs, now) : `${describeSize(one.size)} · ${describeAge(one.mtimeMs, now)}`,
          }
        }),
      ]
      const chunks = Array.from({ length: Math.ceil(items.length / LIST_CHUNK) }, (_, i) =>
        items.slice(i * LIST_CHUNK, i * LIST_CHUNK + LIST_CHUNK),
      )
      blockStarts = chunks.map((_, i) => i * LIST_CHUNK)
      estimatedRows = Math.max(1, items.length)
      body = (
        <Box flexDirection="column" width={textWidth}>
          {items.length === 0 && <Text color={C.overlay0}>Empty folder.</Text>}
          {Client &&
            chunks.map((chunk, i) => (
              <Client
                key={`rows-${i}`}
                module="./rows.tsx"
                props={{ muted: isMenuOpen, width: textWidth, rows: chunk }}
                width={textWidth}
                height={chunk.length}
              />
            ))}
        </Box>
      )
      jumps = blockJumps(chunks.length, 'rows')
    } else if (current.code) {
      const code = current.code
      const lines = code.source.split('\n')
      const chunk = 10
      const chunks = Array.from({ length: Math.ceil(lines.length / chunk) }, (_, i) => lines.slice(i * chunk, i * chunk + chunk))
      blockStarts = chunks.map((_, i) => i * chunk)
      estimatedRows = Math.max(1, lines.length)
      body = (
        <Box flexDirection="column" width={textWidth}>
          {chunks.map((part, i) => (
            <Box key={`chunk-${i}`} flexDirection="column">
              {isMenuOpen ? (
                <Text color={C.overlay1}>{part.join('\n') || ' '}</Text>
              ) : (
                <Code
                  source={part.join('\n') || ' '}
                  language={code.language}
                  startLine={code.startLine + i * chunk}
                  wrap="truncate-end"
                />
              )}
            </Box>
          ))}
        </Box>
      )
      jumps = blockJumps(chunks.length, 'chunk')
      const firstLine = code.startLine + Math.max(0, Math.min(lines.length - 1, offset))
      position = `line ${firstLine} of ${code.startLine + lines.length - 1}`
    } else if (current.image && Image && png) {
      blockStarts = []
      body = (
        <Image
          key="picture"
          source={{ png }}
          {...imageBox(current.image.width, current.image.height, textWidth, Math.max(4, e.props.scroll.bodyRows - PAGE_TOP - FOOTER_ROWS - 2))}
          alt={`${current.title} (this terminal cannot draw images: press o to open it)`}
        />
      )
    }
    const goNext = jumps.next
    const goPrev = jumps.prev
    const isStarred = (await read($, stars)).some(one => itemKey(remoteRef(one)?.address ?? one) === itemKey(current.href))
    const remote = current.remote
    const source = remote?.record ? sourceLine(remote, now) : ''
    const info = [isStarred ? '\u{f51a} starred' : '', source, position, current.summary, current.tasks].filter(Boolean).join(' · ')
    const remoteCrumbs = remote
      ? [
          ...(remote.record?.trail ?? []).map((label, index, all) => ({
            label: `${trailIcon(current.kind ?? 'web', index, all.length)} ${label}`,
            fg: C.subtext0 as string,
            bg: C.surface1 as string,
            canShrink: true,
          })),
          { label: `${iconFor(current.kind)} ${current.title}`, fg: C.appBg, bg: C.accent, bold: true },
        ]
      : null

    return frame(
      crumbs(remoteCrumbs ?? [
              ...(current.root
                ? [
                    {
                      label: `${current.isWorktree ? ICON.worktree : ICON.repo} ${current.root.split('/').pop() ?? ''}`,
                      fg: C.overlay1 as string,
                      bg: C.surface0 as string,
                    },
                  ]
                : []),
              ...(folder ? [{ label: `${ICON.folder} ${folder}`, fg: C.subtext0 as string, bg: C.surface1 as string, canShrink: true }] : []),
              { label: `${iconFor(kind)} ${current.title}`, fg: C.appBg, bg: C.accent, bold: true },
            ]),
      <Box flexDirection="column" width={textWidth}>
          {current.error && <Text color={C.red}>{current.error}</Text>}
          {body as never}
      </Box>,
      info,
      [
          ...modeKeys,
          { key: 'next', label: 'Down', hotkey: 'j', onPress: goNext },
          { key: 'prev', label: 'Up', hotkey: 'k', onPress: goPrev },
          { key: 'star', label: isStarred ? 'Unstar' : 'Star', hotkey: 'f', onPress: () => void setStar($, current.href) },
          { key: 'open', label: remote ? 'Open in browser' : 'Open', hotkey: 'o', onPress: () => void openExternally($, current) },
          ...(remote ? [{ key: 'refresh', label: 'Refresh', hotkey: 'u', onPress: () => void refresh($, current.href) }] : []),
          ...(backStack.length ? [{ key: 'back', label: 'Back', hotkey: 'b', onPress: () => void goBack($) }] : []),
          {
            key: 'copy',
            label: remote ? 'Copy link' : 'Copy path',
            hotkey: 'c',
            onPress: () => void $.ui.copy({ text: current.location }),
          },
          { key: 'close', label: 'Close', hotkey: 'x', onPress: () => void $.ui.close({ id: PANE }) },
      ],
    )
  })
}
