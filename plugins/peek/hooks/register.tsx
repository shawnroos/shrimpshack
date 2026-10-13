import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Group, GroupItem, GroupOp, GroupOutcome, GroupResult, Loaded, Mention, Mode, Picture, RecipePage, RemoteComment, RemoteRecord, SectionLayout, View } from '../types'
import type { FileEntry, GallerySort, GalleryType, RoleFilter, Scope } from './lib'
import { C as BASE, MUTED, ICON, META_ICON, colorFor, iconFor, mute, ruleParts, speakerColor } from './theme'
import { capturedLinearContext, record } from './capture'
import type { CaptureIo } from './capture'
import { familyOf, itemKey, parseRef } from './refs'
import type { Ref, RefContext } from './refs'
import { loadItem } from './remote'
import { initials, whenLabel } from './slack'
import { downloadFile, remoteFileOf } from './web'
import type { RemoteIo } from './remote'
import { bootstrapLinear } from './linear'
import type { LinearBootstrap } from './linear'
import { failureText } from './sources'
import type { Page } from './page'
import { drawPage } from './page-view'
import { loadRecipes, recipesDir, routeOf } from './recipes'
import type { RecipesIo } from './recipes'
import { failureText as recipeFailureText, runRecipe } from './recipe-run'
import type { RunIo } from './recipe-run'
import { createLive, isWebUrl, liveStatusText, pagePoint, typedInput, wheelPoint } from './live'
import type { FrameGeometry, HelperInput, Live, LiveFailureKind, LiveIo, LiveState, TypedKey, Viewport } from './live'
import { IDLE_MS, cached, isCurrent, isTimed, refreshItem, tick, titleOf, withTitle } from './refresh'
import type { CacheEntry, TitleEntry } from './refresh'
import {
  applyGroupOps,
  createGroup,
  deleteGroup,
  fileOf,
  groupsDir,
  isGroupId,
  isScheme,
  layoutOf,
  listGroups,
  readGroup,
  refPath,
  refused,
  resolveProjectKey,
  shortId,
  starGroup,
  storedRef,
  writeGroup,
} from './groups'
import type { GroupPlace, GroupWrite, GroupsIo } from './groups'
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
  wrapLines,
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
const openGroup = atom({ plugin: 'peek', key: 'openGroup' } as const, null)
const NARROW = 60
const MIN_CPL = 30
const MAX_CPL = 104
const MODES: { id: Mode; label: string; icon: string; hotkey: string }[] = [
  { id: 'view', label: 'Peek', icon: '\u{f06e}', hotkey: 'p' },
  { id: 'recent', label: 'Recent', icon: '\u{f017}', hotkey: 'r' },
  { id: 'gallery', label: 'Gallery', icon: '\u{f0c6c}', hotkey: 'g' },
  { id: 'groups', label: 'Groups', icon: ICON.groups, hotkey: 'e' },
]
const scopeAtom = atom({ plugin: 'peek', key: 'scope' } as const, 'session')
const galleryType = atom({ plugin: 'peek', key: 'galleryType' } as const, 'all')
const gallerySort = atom({ plugin: 'peek', key: 'gallerySort' } as const, 'recent')
const galleryFilter = atom({ plugin: 'peek', key: 'galleryFilter' } as const, '')
const roleFilter = atom({ plugin: 'peek', key: 'roleFilter' } as const, 'all')
const stars = atom({ plugin: 'peek', key: 'stars' } as const, [])
const cursorAtom = atom({ plugin: 'peek', key: 'cursor' } as const, 0)
type NavItem = { href: string; key: string; line: number; col: number; group?: string }
type BlockSink = {
  drawnParts: unknown[]
  note: (rows: number, heading?: string) => void
  media: RemoteRecord['media']
  pictures: Awaited<ReturnType<typeof mediaPictures>>
  memoBase: string
  refs: RefContext
}
type ItemLook = { href: string; isStarred: boolean; favicon: string | undefined; icon: string; name: string; folder: string; detail: string }
type NavSink = { nav: NavItem[]; keys: string[]; starts: number[]; cursor: number; line: number; selected: number }
let navOrder: NavItem[] = []

type Direction = 'up' | 'down' | 'left' | 'right'

const clamp = (at: number, length: number) => Math.max(0, Math.min(length - 1, at))

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
  const rows = await groupPageRows($)
  if (rows) {
    if ((direction === 'up' || direction === 'down') && (await selectGroupRow($, rows, rows.selected + (direction === 'down' ? 1 : -1)))) {
      await focusGroupRow($, rows.selected)
    }
    return
  }
  let landed = 0
  await update($, cursorAtom, at => {
    landed = stepFrom(clamp(at, navOrder.length), direction)
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
  await openNav($, navOrder[index])
}

async function selectedNav($: EngineInterface): Promise<NavItem | undefined> {
  return navOrder[clamp(await read($, cursorAtom), navOrder.length)]
}

async function openNav($: EngineInterface, one: NavItem | undefined) {
  if (one?.group) await openGroupPage($, one.group)
  else if (one?.href) await openLink($, one.href)
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
const PINNED_GROUPS = 4
const GROUP_CARD_LINES = 3
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
// The engine refuses a whole pane whose Image sources pass 2097152 bytes; past this budget a picture shows as a link.
const IMAGE_TREE_BUDGET = 1_900_000

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
const MOVE_KEYS = new Set(['next', 'prev', 'left', 'right'])
const COMMAND_KEYS: Record<string, string> = {
  peek: 'mode-view',
  recent: 'mode-recent',
  gallery: 'mode-gallery',
  groups: 'mode-groups',
  'role-*': 'role',
  'scope-*': 'scope',
  open: 'open',
  refresh: 'refresh',
  live: 'live',
  'live-back': 'back',
  copy: 'copy',
  star: 'star',
  close: 'close',
}
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
async function toPng($: EngineInterface, abs: string, mtimeMs: number, edges: readonly number[] = [1600, 1000, 600]) {
  const cacheKey = `${abs}@${mtimeMs}@${edges.join(',')}`
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
  for (const edge of edges) {
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
async function loadRemoteFile($: EngineInterface, url: URL, file: { fetchUrl: string; ext: string }): Promise<View | null> {
  const got = await downloadFile(remoteIoOf($), file.fetchUrl, file.ext).catch(() => undefined)
  if (!got || /^text\/html/i.test(got.type ?? '')) return null
  const loaded = await loadFile($, url.href, got.file).catch(() => null)
  if (!loaded || loaded.error) return null
  return { ...loaded, title: urlName(url), location: url.href, root: undefined, isWorktree: undefined }
}

async function loadUrl($: EngineInterface, href: string): Promise<View> {
  const url = new URL(href)
  const file = remoteFileOf(href)
  if (file?.kind === 'video') return videoView(url, await $.clock.now())
  const fromFile = file ? await loadRemoteFile($, url, file) : null
  if (fromFile) return fromFile
  const kind = kindOf(url.pathname)
  const base: View = { href, title: url.hostname + url.pathname, location: href, kind: 'web', meta: url.hostname }
  if (kind === 'image' || kind === 'svg') {
    return { ...base, error: 'Remote images open in the browser. Press "Open externally".' }
  }
  const ref = parseRef(href)
  if (file && ref) return loadRemote($, ref)
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

// A pane is about 100 columns of 8 px, so 800 px is already sharper than it can show, and keeps each picture small.
const WEB_EDGES = [800, 600, 400]

async function remotePicture($: EngineInterface, file: string | undefined) {
  if (!file || failedPictures.has(file)) return undefined
  return toPng($, file, 0, WEB_EDGES).catch(() => {
    failedPictures.add(file)
    return undefined
  })
}

// A face draws 4 columns by 2 rows; WEB_EDGES would blow Slack's 72 px avatar up to 800 px.
const AVATAR_EDGES = [72]

async function avatarPictures($: EngineInterface, avatars: RemoteRecord['avatars']) {
  const found = await Promise.all(
    Object.entries(avatars ?? {}).map(async ([id, file]) => {
      if (failedPictures.has(file)) return [id, undefined] as const
      const picture = await toPng($, file, 0, AVATAR_EDGES).catch(() => {
        failedPictures.add(file)
        return undefined
      })
      return [id, picture] as const
    }),
  )
  const pictures = Object.fromEntries(found.filter((one): one is readonly [string, NonNullable<(typeof one)[1]>] => Boolean(one[1])))
  return Object.keys(pictures).length ? pictures : undefined
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
// viewOf runs on every refresh tick and redraw; each fence costs one mermaid-ascii process.
const drawnRecords = new Map<string, RemoteRecord>()
const MAX_DRAWN_RECORDS = 50

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
  await show($, href, true)
}

// b walks the page history first, so a link followed inside a group item comes back before the group does.
async function goBack($: EngineInterface) {
  if (groupBack && backStack.length <= groupBack.depth) {
    const target = groupBack
    groupBack = null
    await update($, openGroup, opened => (opened?.id === target.id ? opened : { id: target.id, item: null }))
    await update($, mode, () => 'groups')
    await update($, page, () => 0)
    return
  }
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

async function saveTitle($: EngineInterface, address: string, next: Omit<TitleEntry, 'updatedAt'>) {
  const { updatedAt: _, ...known } = titles[address] ?? { updatedAt: 0 }
  if (JSON.stringify(known) === JSON.stringify(next)) return
  titles = withTitle(titles, address, next, await $.clock.now())
  await $.store.set('titles', titles).catch(() => undefined)
}

async function noteTitle($: EngineInterface, entry: CacheEntry) {
  if (entry.record) await saveTitle($, entry.record.address, titleOf(entry.record))
}

async function notePageTitle($: EngineInterface, href: string, state: RecipePage) {
  if (state.page) await saveTitle($, href, { title: state.page.title, kind: 'web', trail: [state.name] })
}

function startTicking($: EngineInterface) {
  if (isTicking) return
  isTicking = true
  $.clock.every(15_000, () => void tickRemote($).catch(() => undefined))
}

async function loadRemote($: EngineInterface, ref: Ref, canReplay = false): Promise<View> {
  startTicking($)
  const known = cached(ref.address)
  if (known?.state === 'frozen') return viewOf($, ref, known)
  const entry = await refreshItem(ref.address, remoteLoader($, canReplay), await $.clock.now())
  await noteTitle($, entry)
  return viewOf($, ref, entry)
}

async function withRecordDiagrams($: EngineInterface, record: RemoteRecord, fetchedAt = 0): Promise<RemoteRecord> {
  const texts = [record.body ?? '', ...(record.comments?.shown ?? []).map(one => one.body)]
  if (!texts.some(text => mermaidFences(text).length)) return record
  const key = `${record.address}|${fetchedAt}|${paneColumns}`
  const known = drawnRecords.get(key)
  if (known) return known
  const [body, ...comments] = await Promise.all(texts.map(text => withDrawnMermaid($, text)))
  const drawn: RemoteRecord = {
    ...record,
    ...(record.body !== undefined ? { body } : {}),
    ...(record.comments ? { comments: { ...record.comments, shown: record.comments.shown.map((one, i) => ({ ...one, body: comments[i] ?? one.body })) } } : {}),
  }
  if (drawnRecords.size > MAX_DRAWN_RECORDS) drawnRecords.clear()
  drawnRecords.set(key, drawn)
  return drawn
}

async function viewOf($: EngineInterface, ref: Ref, entry: CacheEntry): Promise<View> {
  const base: View = { href: ref.address, title: ref.key ?? ref.address.replace(/^https:\/\//, ''), location: ref.address, kind: ref.kind }
  const record = entry.record && (await withRecordDiagrams($, entry.record, entry.fetchedAt))
  if (!record) return { ...base, remote: { failure: entry.failure ?? 'offline', failureDetail: entry.failureDetail } }
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
      pictures: await mediaPictures($, record.media),
      avatars: await avatarPictures($, record.avatars),
    },
  }
}

async function mediaPictures($: EngineInterface, media: RemoteRecord['media']) {
  const found = await Promise.all(Object.entries(media ?? {}).map(async ([key, one]) => [key, await remotePicture($, one.file)] as const))
  const pictures = Object.fromEntries(found.filter((one): one is readonly [string, NonNullable<(typeof one)[1]>] => Boolean(one[1])))
  return Object.keys(pictures).length ? pictures : undefined
}

function recipesIoOf($: EngineInterface): RecipesIo {
  return {
    home: () => $.env.get('HOME'),
    list: dir => $.fs.list(dir),
    read: path => $.fs.read(path, { as: 'bytes' }),
    // The runner refuses a script it cannot follow to a real path, so without resolve every script recipe fails.
    stat: path => $.fs.stat(path, { resolve: true }),
    storeGet: key => $.store.get(key),
  }
}

function runIoOf($: EngineInterface): RunIo {
  return {
    ...recipesIoOf($),
    envGet: async name => {
      if (name === 'HOME') return $.env.get('HOME')
      if (name === 'PATH') return $.env.get('PATH')
      if (name === 'LANG') return $.env.get('LANG')
      if (name === 'TMPDIR') return $.env.get('TMPDIR')
      // $.env.get takes only a literal name, so a name a recipe declares is read the way its script would see it.
      const ran = await $.process.run(['/usr/bin/printenv', name]).catch(() => null)
      return ran?.exitCode === 0 ? ran.stdout.replace(/\n$/, '') : undefined
    },
    run: (argv, init) => $.process.run(argv, init),
    mcpCall: (server, tool, args) => $.mcp.call(server, tool, args),
    toolCheck: check => $.tool.check(check),
    now: () => $.clock.now(),
    sleep: ms => $.clock.sleep(ms),
  }
}

const PAGE_PICTURES = 12
const PICTURE_LINES = /^\s*!\[[^\]]*\]\(([^)\s]+)\)\s*$/gm
const IMAGE_EXT = /\.(png|jpe?g|gif|webp|bmp|svg)$/i

function imageExt(url: string): string {
  try {
    return IMAGE_EXT.exec(new URL(url).pathname)?.[1]?.toLowerCase() ?? 'img'
  } catch {
    return 'img'
  }
}

async function pageMedia($: EngineInterface, page: Page): Promise<Pick<RecipePage, 'media' | 'pictures'>> {
  const media: Record<string, { file?: string; play?: string }> = {}
  const images: string[] = []
  const addImage = (url: string) => {
    if (url && !(url in media)) {
      media[url] = {}
      images.push(url)
    }
  }
  for (const { block } of page.sections) {
    if (block.type === 'media') for (const one of block.items) one.kind === 'video' ? (media[one.url] = { play: one.url }) : addImage(one.url)
    if (block.type === 'markdown') for (const found of block.text.matchAll(PICTURE_LINES)) addImage(found[1] ?? '')
    if (block.type === 'cards') for (const one of block.items) addImage(one.image ?? '')
  }
  if (Object.keys(media).length === 0) return {}
  const io = remoteIoOf($)
  const found = await Promise.all(
    images.slice(0, PAGE_PICTURES).map(async url => {
      const got = await downloadFile(io, url, imageExt(url)).catch(() => undefined)
      if (!got || /^text\//i.test(got.type ?? '')) return [url, undefined] as const
      media[url] = { file: got.file }
      return [url, await remotePicture($, got.file)] as const
    }),
  )
  const pictures = Object.fromEntries(found.filter((one): one is readonly [string, Picture] => Boolean(one[1])))
  return { media, ...(Object.keys(pictures).length ? { pictures } : {}) }
}

type PageLoad = { kind: 'none' } | { kind: 'conflict'; ids: string[] } | { kind: 'ran'; state: RecipePage }

const pageLoads = new Map<string, Promise<PageLoad>>()

// One load per link at a time: a second u press or open while the source runs waits for the same answer.
function loadPage($: EngineInterface, link: string, allowDraft: boolean, onRouted: (state: RecipePage) => Promise<void> = async () => undefined): Promise<PageLoad> {
  const key = `${allowDraft ? 'draft' : 'approved'}|${link}`
  const running = pageLoads.get(key)
  if (running) return running
  const loading = (async (): Promise<PageLoad> => {
    const ref = parseRef(link)
    if (!ref) return { kind: 'none' }
    // Every web link passes through here: a folder that cannot be read means no recipe, not a broken open.
    const { recipes, approvals } = await loadRecipes(recipesIoOf($)).catch(() => ({ recipes: [], approvals: {} }))
    const route = routeOf(ref, link, recipes, approvals, { allowDraft })
    if (route.kind === 'conflict') return { kind: 'conflict', ids: route.ids }
    if (route.kind !== 'recipe') return { kind: 'none' }
    const base: RecipePage = { id: route.id, name: route.recipe.name, link, isDraft: route.draft, digest: route.digest, refreshMinutes: route.recipe.refreshMinutes }
    await onRouted(base)
    try {
      const root = recipesDir((await $.env.get('HOME')) ?? '')
      const outcome = await runRecipe(runIoOf($), { root, id: route.id, digest: route.digest, draft: route.draft }, link)
      if (!outcome.ok) return { kind: 'ran', state: { ...base, failure: recipeFailureText(outcome), failureKind: outcome.kind } }
      return { kind: 'ran', state: { ...base, fetchedAt: outcome.ranAt, page: outcome.page, ...(await pageMedia($, outcome.page)) } }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      return { kind: 'ran', state: { ...base, failure: `Recipe "${base.name}" (${base.id}) could not run: ${message}`, failureKind: 'started-failed' } }
    }
  })().finally(() => pageLoads.delete(key))
  pageLoads.set(key, loading)
  return loading
}

const conflictText = (ids: readonly string[]) =>
  `Recipes ${ids.map(id => `"${id}"`).join(' and ')} both handle this link, so peek ran neither. Change one recipe's match so only one claims it.`

const pageView = (href: string, state: RecipePage): View => ({ href, title: state.page?.title ?? state.name, location: state.link, kind: 'recipe', page: state })

async function recipeView($: EngineInterface, href: string, raw: string, allowDraft: boolean, onRouted: (state: RecipePage) => Promise<void>): Promise<View | null> {
  const link = raw.trim()
  if (!/^https?:\/\//i.test(link)) return null
  const loaded = await loadPage($, link, allowDraft, onRouted)
  if (loaded.kind === 'none') return null
  const state: RecipePage =
    loaded.kind === 'ran'
      ? loaded.state
      : { id: '', name: 'Recipe conflict', link, isDraft: false, digest: '', refreshMinutes: 0, failure: conflictText(loaded.ids), failureKind: 'conflict' }
  await notePageTitle($, href, state)
  return pageView(href, state)
}

async function refreshPage($: EngineInterface, href: string, was: RecipePage) {
  if (!was.id) {
    await show($, was.link)
    return
  }
  const write = (state: RecipePage) => update($, view, now => (now?.href === href && now.page ? pageView(href, state) : now))
  const { isRefreshing: _, refreshFailure: __, ...kept } = was
  await write({ ...kept, isRefreshing: true })
  const loaded = await loadPage($, was.link, was.isDraft).catch((error: unknown) => ({ kind: 'error' as const, message: error instanceof Error ? error.message : String(error) }))
  const fresh = loaded.kind === 'ran' && loaded.state.id === was.id ? loaded.state : undefined
  if (fresh?.page) {
    await notePageTitle($, href, fresh)
    await write(fresh)
    return
  }
  const reason =
    fresh?.failure ??
    (loaded.kind === 'error'
      ? `Recipe "${was.name}" (${was.id}) could not be read: ${loaded.message}`
      : loaded.kind === 'conflict'
        ? conflictText(loaded.ids)
        : `Recipe "${was.name}" (${was.id}) no longer handles this link: it was edited, removed or replaced. Open the link again.`)
  await write(was.page ? { ...kept, refreshFailure: reason } : { ...kept, failure: reason, failureKind: fresh?.failureKind ?? 'route' })
}

function fetchedAge(fetchedAt: number | undefined, now: number): string {
  if (fetchedAt === undefined) return ''
  const seconds = Math.max(0, Math.round((now - fetchedAt) / 1000))
  return seconds < 60 ? `${seconds}s ago` : describeAge(fetchedAt, now)
}

function pageSourceLine(state: RecipePage, now: number): string {
  if (!state.id) return 'recipe conflict'
  const marker = state.isRefreshing ? 'refreshing…' : state.refreshFailure ? 'refresh failed' : ''
  return [`recipe ${state.id}`, state.isDraft ? 'draft' : 'approved', fetchedAge(state.fetchedAt, now), marker].filter(Boolean).join(' · ')
}

const paneHref = (href: string) => (href.startsWith('/') ? fileHref(href) : href)

async function isPageOnScreen($: EngineInterface): Promise<boolean> {
  return (await read($, mode)) === 'view' && Boolean((await read($, view))?.page)
}

// From a recipe page a link goes through openFromPage, so b comes back to the page.
async function openLink($: EngineInterface, href: string) {
  await ((await isPageOnScreen($)) ? openFromPage($, href) : show($, href))
}

function remoteRef(href: string, context: RefContext = {}): Ref | null {
  if (parseHref(href)) return null
  const ref = parseRef(href, context)
  if (!ref) return null
  return ref.kind === 'web' && remoteFileOf(ref.address) ? null : ref
}

async function show($: EngineInterface, raw: string, isFromGroupChain = false, options: { allowDraft?: boolean } = {}) {
  if (!isFromGroupChain) groupBack = null
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
    const onRouted = async (state: RecipePage) => {
      if (generation === showGeneration) await update($, view, () => pageView(href, state))
    }
    const recipe = file ? null : await recipeView($, href, raw, options.allowDraft === true, onRouted)
    next = recipe ?? (file ? await loadFile($, href, file.path, file.line) : ref ? await loadRemote($, ref) : await loadUrl($, href))
  } catch (error) {
    next = { ...loading, title: 'Could not open', error: error instanceof Error ? error.message : String(error) }
  }
  if (generation !== showGeneration) return
  if (next.page) await update($, cursorAtom, () => 0)
  await update($, view, () => next)
  void $.ui.open({ id: PANE, title: next.title })
}

async function openExternally($: EngineInterface, current: View) {
  if (current.page) {
    if (isWebUrl(current.page.link)) await $.process.run(['open', current.page.link])
    return
  }
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
  const urls = texts.flatMap(urlCandidates).map(url => (parseRef(url)?.kind === 'slack-thread' ? (parseRef(url)?.address ?? url) : url))
  const artifacts = [...(await toHrefs([...texts.flatMap(pathCandidates), ...created])), ...urls]
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
  const needsContext = /^(?:#\d+|[A-Z][A-Z0-9]{0,9}-\d+)$/i.test(cleaned)
  const ref = parseRef(cleaned, needsContext ? await sessionRefContext($) : {})
  if (ref) return ref.address
  const match = /^(.+?)(?::(\d+))?$/.exec(cleaned)
  const abs = resolvePath(match?.[1] ?? cleaned, await $.session.cwd(), (await $.env.get('HOME')) ?? '')
  exists.delete(abs)
  if (await pathExists($, abs)) return fileHref(abs, match?.[2] ? Number(match[2]) : undefined)
  return bareDomain(cleaned)
}

// `.md` and friends are real top-level domains, so a missing local file named like one goes to the guess, not the web.
const FILE_SUFFIX = /\.(?:md|mdx|ts|tsx|js|jsx|json|py|txt|png|jpe?g|gif|svg|pdf|csv|html?|ya?ml|toml|sh|swift|rs|go|css|lock|log)$/i

function bareDomain(text: string): string | null {
  const found = /^((?:[a-z0-9-]+\.)+[a-z]{2,})(:\d+)?([/?#]\S*)?$/i.exec(text)
  if (!found?.[1]) return null
  if (!found[3] && FILE_SUFFIX.test(found[1])) return null
  return `https://${text}`
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
      'If I name a website or online service that is not in this conversation (e.g. "the nytimes website"), reply with its homepage URL instead.',
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

const titlesByKey = () => new Map(Object.entries(titles).map(([address, entry]) => [itemKey(address), entry]))

async function sessionEntries($: EngineInterface, list: readonly Mention[]): Promise<FileEntry[]> {
  const out: FileEntry[] = []
  const remoteTitles = titlesByKey()
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
        name: label?.title ?? ref.key ?? (ref.number ? `#${ref.number}` : ref.channel ? `Thread in ${ref.channel}` : path.replace(/^https?:\/\/(www\.)?/, '')),
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

// e on an open group page goes back to the group list; from any other screen it keeps the open group.
async function switchMode($: EngineInterface, to: Mode) {
  if (to === 'groups' && (await read($, mode)) === 'groups') await update($, openGroup, () => null)
  await update($, mode, () => to)
  await update($, page, () => 0)
}

async function openGroupPage($: EngineInterface, id: string) {
  await update($, openGroup, () => ({ id, item: null }))
  await update($, mode, () => 'groups')
  await update($, page, () => 0)
}

async function personWrite(
  $: EngineInterface,
  id: string,
  failure: string,
  change: (current: Group, now: number) => GroupResult,
  onWritten: (write: Extract<GroupWrite, { ok: true }>) => void = () => undefined,
) {
  const home = await groupHome($)
  if (!home) {
    $.ui.toast(`${failure}: HOME is not set.`)
    return
  }
  const now = await $.clock.now()
  let isGone = false
  const write = await writeGroupHere(groupsIoOf($), home.place, id, current => {
    if (current) return change(current, now)
    isGone = true
    return { group: null, outcomes: [] }
  })
  if (!write.ok) $.ui.toast(`${failure}: ${write.error}.`)
  else if (isGone) {
    $.ui.toast('That group was deleted.')
    if ((await read($, openGroup))?.id === id) await update($, openGroup, () => null)
  } else onWritten(write)
  $.ui.invalidate('ui.render')
}

async function toggleGroupStar($: EngineInterface, id: string) {
  await personWrite($, id, 'Could not star the group', current => starGroup(current, !current.starred))
}

const starredFirst = (groups: readonly Group[]) => [...groups].sort((a, b) => Number(b.starred) - Number(a.starred))

// The tab re-sorts starred-first, so the cursor index is re-pointed at the group it was on;
// left on its old index, the next f would toggle a different card.
async function starInGroupsTab($: EngineInterface, id: string) {
  const kept = (await selectedNav($))?.href
  await toggleGroupStar($, id)
  const home = await groupHome($)
  if (!home || !kept) return
  const index = starredFirst(await shownGroups(groupsIoOf($), home.place)).findIndex(one => one.id === kept)
  if (index >= 0) await update($, cursorAtom, () => index)
  $.ui.invalidate('ui.render')
}

async function personGroupWrite($: EngineInterface, id: string, title: string, op: Extract<GroupOp, { op: 'addItem' | 'removeItem' }>) {
  const verb = op.op === 'addItem' ? 'add to' : 'remove from'
  await personWrite(
    $,
    id,
    `Could not ${verb} ${title}`,
    (current, now) => applyGroupOps(current, [op], { now, newId: () => shortId(Math.random), actor: 'person', others: [] }),
    write => {
      const outcome = write.outcomes[0]
      const name = write.group?.title ?? title
      if (outcome?.status === 'applied') $.ui.toast(op.op === 'addItem' ? `Added to ${name}` : `Removed from ${name}`)
      else if (outcome?.status === 'unchanged' && op.op === 'addItem') $.ui.toast(`Already in ${name}`)
      else $.ui.toast(outcome?.reason ?? `Could not ${verb} ${name}.`)
    },
  )
}

async function personGroupAdd($: EngineInterface, id: string, title: string, href: string) {
  const target = await groupTarget($, href, (await groupHome($))?.worktreeRoot, true)
  if ('error' in target) $.ui.toast(`Could not add to ${title}: ${target.error}.`)
  else await personGroupWrite($, id, title, { op: 'addItem', ref: target.ref })
}

type MenuCommand = { id: string; icon: string; label: string; hint: string; run: () => void; isGroupRow?: boolean; isFilteredOnly?: boolean }
type GroupMenuFor = { target?: string; group?: Group; selectedRef?: string; starHint?: string }

const GROUP_MENU_ROWS = 8

async function groupCommands($: EngineInterface, on: GroupMenuFor): Promise<MenuCommand[]> {
  const home = await groupHome($)
  if (!home) return []
  const open = on.group
  const own: MenuCommand[] = open
    ? [
        { id: 'group-star', icon: '\u{f51a}', label: `${open.starred ? 'Unstar' : 'Star'} this group`, hint: on.starHint ?? '', run: () => void toggleGroupStar($, open.id) },
        ...(on.selectedRef !== undefined
          ? [{ id: 'group-remove-here', icon: '\u{f068}', label: 'Remove from this group', hint: '', run: () => void personGroupWrite($, open.id, open.title, { op: 'removeItem', ref: on.selectedRef ?? '' }) }]
          : []),
      ]
    : []
  const href = on.target
  const target = href ? await groupTarget($, href, home.worktreeRoot, false) : null
  if (!href || !target || 'error' in target) return own.map(one => ({ ...one, isGroupRow: true }))
  const key = itemKey(target.ref)
  const groups = (await shownGroups(groupsIoOf($), home.place)).filter(one => one.id !== open?.id)
  const rows = groups.map((one, index): MenuCommand => {
    const held = one.items.find(item => itemKey(item.ref) === key)
    const isFilteredOnly = index >= GROUP_MENU_ROWS
    return held
      ? { id: `group-remove-${one.id}`, icon: '\u{f068}', label: `Remove from group: ${one.title}`, hint: '', isFilteredOnly, run: () => void personGroupWrite($, one.id, one.title, { op: 'removeItem', ref: held.ref }) }
      : { id: `group-add-${one.id}`, icon: '\u{f067}', label: `Add to group: ${one.title}`, hint: '', isFilteredOnly, run: () => void personGroupAdd($, one.id, one.title, href) }
  })
  return [...own, ...rows].map(one => ({ ...one, isGroupRow: true }))
}

type GroupRows = { id: string; title: string; keys: string[]; hrefs: string[]; selected: number }

// Drawing may not write state, so the page keeps what its handlers need here: the rows as last drawn, the
// back step to the group, and which deleted group was already reported.
let groupRows: GroupRows | null = null
let groupBack: { id: string; title: string; depth: number } | null = null
let goneGroupNotice = ''
let openGroupRemotes: string[] = []

async function groupPageRows($: EngineInterface): Promise<GroupRows | null> {
  if (!groupRows || (await read($, mode)) !== 'groups') return null
  return (await read($, openGroup))?.id === groupRows.id ? groupRows : null
}

async function selectGroupRow($: EngineInterface, rows: GroupRows, wanted: number): Promise<boolean> {
  const index = clamp(wanted, rows.keys.length)
  const key = rows.keys[index]
  if (key === undefined) return false
  rows.selected = index
  await update($, openGroup, opened => (opened?.id === rows.id ? { ...opened, item: key } : opened))
  await update($, cursorAtom, () => index)
  return true
}

async function focusGroupRow($: EngineInterface, index: number) {
  await $.ui.scroll({ in: PANE, to: { key: `group-row-${index}` }, block: 'center' }).catch(() => undefined)
  await $.ui.focus({ requestId: PANE, key: `item-${index}` }).catch(() => undefined)
}

async function openGroupItem($: EngineInterface, rows: GroupRows, index: number) {
  await selectGroupRow($, rows, index)
  await openGroupHref($, rows, rows.keys[rows.selected] ?? '', rows.hrefs[rows.selected] ?? '')
}

// Opening from a card sets openGroup too, so Back lands on the group page with this item selected.
async function openGroupHref($: EngineInterface, group: { id: string; title: string }, key: string, href: string) {
  const file = href ? parseHref(href) : null
  if (!href || (file && !(await $.fs.exists(file.path).catch(() => false)))) {
    $.ui.toast(`That file is gone: ${file?.path ?? key}`)
    return
  }
  await update($, openGroup, () => ({ id: group.id, item: key }))
  groupBack = { id: group.id, title: group.title, depth: backStack.length }
  await show($, href, true)
}

async function openCardItem($: EngineInterface, id: string, key: string, href: string) {
  const home = await groupHome($)
  const group = home ? await shownGroup(groupsIoOf($), home.place, id) : null
  if (group) await openGroupHref($, group, key, href)
  else $.ui.toast('That group was deleted.')
}

// Per pane and never saved. Only handlers change it: a draw may not write state.
const expandedGroups = new Set<string>()

function toggleExpanded($: EngineInterface, id: string) {
  if (!expandedGroups.delete(id)) expandedGroups.add(id)
  $.ui.invalidate('ui.render')
}

type GroupLook = { key: string; href: string; name: string; kind: string; where: string; state: ItemState; favicon?: string }

async function groupItemLook($: EngineInterface, item: GroupItem, worktreeRoot: string | undefined, known: ReadonlyMap<string, TitleEntry>): Promise<GroupLook> {
  const key = itemKey(item.ref)
  const file = refPath(item.ref, worktreeRoot)
  if (file) {
    const { state, stat } = await fileState($, file.path)
    const name = file.path.split('/').pop() || file.path
    const folder = file.path.slice(0, Math.max(0, file.path.length - name.length - 1))
    const where = worktreeRoot && folder.startsWith(worktreeRoot) ? folder.slice(worktreeRoot.length + 1) : folder
    return { key, href: fileHref(file.path, file.line), name: item.label ?? name, kind: stat?.kind === 'dir' ? 'folder' : kindOf(file.path), where, state }
  }
  const state = await itemState($, item.ref, worktreeRoot)
  if (!isScheme(item.ref)) return { key, href: '', name: item.label ?? item.ref, kind: kindOf(item.ref), where: '', state }
  const ref = remoteRef(item.ref)
  const address = ref?.address ?? item.ref
  const title = known.get(key)
  const fallback = ref?.key ?? (ref?.number ? `#${ref.number}` : address.replace(/^https?:\/\/(www\.)?/, ''))
  let host = ''
  try {
    host = new URL(address).hostname
  } catch {}
  return {
    key,
    href: address,
    name: title?.title ?? item.label ?? fallback,
    kind: title?.kind ?? ref?.kind ?? 'web',
    where: ref?.owner ? `${ref.owner}/${ref.repo}` : title?.trail?.join(' · ') || host,
    state,
    favicon: (await remotePicture($, title?.favicon))?.file,
  }
}

function loadGroupRemote($: EngineInterface, address: string) {
  startTicking($)
  void $.clock
    .now()
    .then(now => refreshItem(address, remoteLoader($, false), now))
    .then(entry => noteTitle($, entry))
    .then(() => $.ui.invalidate('ui.render'))
    .catch(() => undefined)
}

function groupsIoOf($: EngineInterface): GroupsIo {
  return {
    read: path => $.fs.read(path),
    write: (path, text) => $.fs.write(path, text),
    list: dir => $.fs.list(dir),
    stat: path => $.fs.stat(path).catch(() => null),
    run: argv => $.process.run(argv),
    now: () => $.clock.now(),
    sleep: ms => $.clock.sleep(ms),
  }
}

type GroupHome = { place: GroupPlace; worktreeRoot?: string }

// Render reads only: a write that decided from these could act on another session's stale group.
const groupLists = new Map<string, { mtimeMs: number | null; groups: readonly Group[] }>()
let openGroupFile: { file: string; projectKey: string; mtimeMs: number; group: Group | null } | null = null

async function shownGroups(io: GroupsIo, place: GroupPlace): Promise<readonly Group[]> {
  const mtimeMs = (await io.stat(place.dir))?.mtimeMs ?? null
  const key = `${place.dir}|${place.projectKey}`
  const known = groupLists.get(key)
  if (known && known.mtimeMs === mtimeMs) return known.groups
  const groups = await listGroups(io, place)
  groupLists.set(key, { mtimeMs, groups })
  return groups
}

async function shownGroup(io: GroupsIo, place: GroupPlace, id: string): Promise<Group | null> {
  const file = fileOf(place, id)
  const stat = isGroupId(id) ? await io.stat(file) : null
  const known = openGroupFile
  if (stat && known?.file === file && known.projectKey === place.projectKey && known.mtimeMs === stat.mtimeMs) return known.group
  const group = await readGroup(io, place, id)
  openGroupFile = stat ? { file, projectKey: place.projectKey, mtimeMs: stat.mtimeMs, group } : null
  return group
}

function writeGroupHere(io: GroupsIo, place: GroupPlace, id: string, change: (current: Group | null) => GroupResult): Promise<GroupWrite> {
  return writeGroup(io, place, id, change).then(write => {
    if (write.ok && write.isChanged) {
      groupLists.delete(`${place.dir}|${place.projectKey}`)
      openGroupFile = null
    }
    return write
  })
}

const groupHomes = new Map<string, Promise<GroupHome | null>>()

async function findGroupHome($: EngineInterface, root: string): Promise<GroupHome | null> {
  const homeDir = await $.env.get('HOME')
  if (!homeDir) return null
  const projectKey = await resolveProjectKey(argv => $.process.run(argv), root)
  const git = await gitRoot($, root)
  return { place: { dir: groupsDir(homeDir, projectKey), projectKey }, worktreeRoot: git?.root }
}

async function groupHome($: EngineInterface): Promise<GroupHome | null> {
  const root = await $.session.root()
  const key = `${await $.session.id()}|${root}`
  const known = groupHomes.get(key)
  if (known) return known
  const found = findGroupHome($, root)
  groupHomes.set(key, found)
  found.catch(() => {
    if (groupHomes.get(key) === found) groupHomes.delete(key)
  })
  return found
}

type GroupTarget = { raw: string; ref: string } | { raw: string; error: string }

async function groupTarget($: EngineInterface, raw: string, worktreeRoot: string | undefined, isAdd: boolean): Promise<GroupTarget> {
  const trimmed = raw.trim()
  const href = await toHref($, trimmed).catch(() => null)
  if (href) {
    const file = parseHref(href)
    if (isAdd && file && !(await $.fs.exists(file.path).catch(() => false))) return { raw: trimmed, error: `No file at ${file.path}` }
    return { raw: trimmed, ref: storedRef(remoteRef(href)?.address ?? href, worktreeRoot) }
  }
  if (isAdd || !trimmed) return { raw: trimmed, error: `No file or URL at ${trimmed}` }
  if (isScheme(trimmed)) return { raw: trimmed, ref: trimmed }
  const abs = resolvePath(trimmed.replace(/:\d+$/, ''), await $.session.cwd(), (await $.env.get('HOME')) ?? '')
  return { raw: trimmed, ref: storedRef(fileHref(abs), worktreeRoot) }
}

type ItemState = 'ok' | 'missing' | 'unavailable'

// stat rejects for a missing path and for any other failure, so only a failed stat asks exists which one it was.
async function fileState($: EngineInterface, path: string): Promise<{ state: ItemState; stat: { kind: string } | null }> {
  const stat = await $.fs.stat(path).catch(() => null)
  if (stat) return { state: 'ok', stat }
  const state = await $.fs.exists(path).then(
    (found): ItemState => (found ? 'ok' : 'missing'),
    (): ItemState => 'unavailable',
  )
  return { state, stat: null }
}

async function itemState($: EngineInterface, ref: string, worktreeRoot?: string): Promise<ItemState> {
  const file = refPath(ref, worktreeRoot)
  if (file) return (await fileState($, file.path)).state
  if (!isScheme(ref)) return 'missing'
  const entry = cached(ref)
  if (entry?.failure === 'gone') return 'missing'
  return entry?.state === 'failed' || entry?.state === 'stale-since' ? 'unavailable' : 'ok'
}

async function groupJson($: EngineInterface, group: Group, worktreeRoot?: string) {
  const known = titlesByKey()
  const items = await Promise.all(
    group.items.map(async one => ({
      ref: one.ref,
      title: known.get(itemKey(one.ref))?.title ?? null,
      label: one.label ?? null,
      section: one.section ?? null,
      addedBy: one.addedBy,
      state: await itemState($, one.ref, worktreeRoot),
    })),
  )
  return { id: group.id, title: group.title, description: group.description, starred: group.starred, sections: group.sections.map(one => ({ ...one, layout: layoutOf(one) })), items, removed: group.removed }
}

const sum = (values: readonly number[]) => values.reduce((total, one) => total + one, 0)

const plural = (count: number, word: string) => `${count} ${word}${count === 1 ? '' : 's'}`

function tally(outcomes: readonly GroupOutcome[]): string {
  const count = (status: GroupOutcome['status']) => outcomes.filter(one => one.status === status).length
  return `${count('applied')} applied, ${count('unchanged')} unchanged, ${count('refused')} refused`
}

const failedWrite = (verb: string, write: Extract<GroupWrite, { ok: false }>) => ({ result: `Could not ${verb}: ${write.error}. Nothing was changed.` })

type SaveInput = {
  id?: unknown
  title?: unknown
  description?: unknown
  sections?: unknown
  order?: unknown
  add?: unknown
  move?: unknown
  remove?: unknown
}

const isText = (value: unknown): value is string => typeof value === 'string'
const isGroupRef = (id: unknown): id is string => isText(id) && isGroupId(id)
const badId = (id: unknown) => ({ result: `${String(id)} is not a group id. Use an id from list_groups.` })
const listOf = (value: unknown): Record<string, unknown>[] | null =>
  value === undefined ? [] : Array.isArray(value) && value.every(one => one && typeof one === 'object') ? (value as Record<string, unknown>[]) : null

function sectionOps(value: unknown): GroupOp[] | string {
  const list = listOf(value)
  if (!list) return 'sections must be a list of { action, section, title }'
  const ops: GroupOp[] = []
  for (const one of list) {
    const isLaid = one.action === 'layout' || (one.action === 'add' && one.layout !== undefined)
    if (isLaid && one.layout !== 'cards' && one.layout !== 'list') return `A section layout is cards or list, not "${String(one.layout)}"`
    const layout = one.layout as SectionLayout
    if (one.action === 'add' && isText(one.title)) ops.push({ op: 'addSection', title: one.title, ...(isLaid ? { layout } : {}) })
    else if (one.action === 'layout' && isText(one.section)) ops.push({ op: 'setSectionLayout', section: one.section, layout })
    else if (one.action === 'rename' && isText(one.section) && isText(one.title)) ops.push({ op: 'renameSection', section: one.section, title: one.title })
    else if (one.action === 'remove' && isText(one.section)) ops.push({ op: 'removeSection', section: one.section })
    else return `Unreadable section change ${JSON.stringify(one)}`
  }
  return ops
}

async function saveGroup($: EngineInterface, input: SaveInput) {
  const home = await groupHome($)
  if (!home) return { result: 'Could not save the group: HOME is not set.' }
  const { place, worktreeRoot } = home
  const id = input.id
  if (id !== undefined && !isGroupRef(id)) return badId(id)
  if (input.title !== undefined && !isText(input.title)) return { result: 'title must be text.' }
  if (input.description !== undefined && !isText(input.description)) return { result: 'description must be text.' }
  if (id === undefined && !isText(input.title)) return { result: 'Give a title to create a group, or an id to change one.' }
  const sections = sectionOps(input.sections)
  if (typeof sections === 'string') return { result: sections }
  const order = input.order
  if (order !== undefined && !(Array.isArray(order) && order.every(isText))) return { result: 'order must be a list of section ids or titles.' }
  const adds = listOf(input.add)
  const moves = listOf(input.move)
  const removes = listOf(input.remove)
  if (!adds || !moves || !removes || [...adds, ...moves, ...removes].some(one => !isText(one.target))) {
    return { result: 'add, move and remove are lists of objects, each with a target.' }
  }

  const resolveAll = (list: Record<string, unknown>[], isAdd: boolean) => Promise.all(list.map(one => groupTarget($, String(one.target), worktreeRoot, isAdd)))
  const [added, moved, removed] = await Promise.all([resolveAll(adds, true), resolveAll(moves, false), resolveAll(removes, false)])
  const rejected: GroupOutcome[] = added.flatMap(one => ('error' in one ? [refused('addItem', one.error, { ref: one.raw })] : []))
  const optional = <T,>(value: unknown, wrap: (v: string) => T) => (isText(value) ? wrap(value) : {})
  const opsFor = (group: Group | null): GroupOp[] => {
    const pick = (target: Extract<GroupTarget, { ref: string }>) => {
      const exact = group?.items.find(one => itemKey(one.ref) === itemKey(target.raw))
      return exact ? exact.ref : target.ref
    }
    return [
      ...sections,
      ...(order ? [{ op: 'reorderSections' as const, order: order as string[] }] : []),
      ...added.flatMap((one, i) =>
        'error' in one
          ? []
          : [{ op: 'addItem' as const, ref: one.ref, ...optional(adds[i]?.section, section => ({ section })), ...optional(adds[i]?.label, label => ({ label })), ...(adds[i]?.force === true ? { force: true } : {}) }],
      ),
      ...moved.flatMap((one, i) => ('error' in one ? [] : [{ op: 'moveItem' as const, ref: pick(one), ...optional(moves[i]?.section, section => ({ section })) }])),
      ...removed.flatMap((one, i) => ('error' in one ? [] : [{ op: 'removeItem' as const, ref: pick(one), ...(removes[i]?.force === true ? { force: true } : {}) }])),
    ]
  }

  const io = groupsIoOf($)
  const isCreate = id === undefined
  const others = isCreate || isText(input.title) ? await listGroups(io, place) : []
  const ctx = { now: await $.clock.now(), newId: () => shortId(Math.random), actor: 'agent' as const }
  const target = isCreate ? freshId(others) : id
  const write = await writeGroupHere(io, place, target, current => {
    if (isCreate) {
      if (current) return { group: current, outcomes: [refused('create', 'That id is taken; try again')] }
      return createGroup(
        { projectKey: place.projectKey, id: target, title: String(input.title), ...optional(input.description, description => ({ description })) },
        opsFor(null),
        { ...ctx, others },
      )
    }
    if (!current) return { group: null, outcomes: [refused('setTitle', `No group ${target} in this project; it may have been deleted`)] }
    const head: GroupOp[] = [
      ...(isText(input.title) ? [{ op: 'setTitle' as const, title: input.title }] : []),
      ...(isText(input.description) ? [{ op: 'setDescription' as const, description: input.description }] : []),
    ]
    return applyGroupOps(current, [...head, ...opsFor(current)], { ...ctx, others: others.filter(one => one.id !== target) })
  })
  if (!write.ok) return failedWrite(isCreate ? 'create the group' : 'save the group', write)
  if (write.isChanged) $.ui.invalidate('ui.render')
  const outcomes = [...write.outcomes, ...rejected]
  const group = write.group
  if (isCreate && !write.isChanged) return { result: `Not created: ${outcomes[0]?.reason ?? 'refused'}.\n${JSON.stringify({ outcomes })}` }
  if (!group) return { result: `Not saved: ${outcomes[0]?.reason ?? 'unknown group'}.\n${JSON.stringify({ outcomes })}` }
  const line = `${isCreate ? 'Created' : 'Saved'} group "${group.title}" (${group.id}): ${tally(isCreate ? outcomes.slice(1) : outcomes)}.`
  return { result: `${line}\n${JSON.stringify({ ...(await groupJson($, group, worktreeRoot)), outcomes })}` }
}

const TARGET_HELP = 'A file path (absolute, or relative to the session folder), a URL, a GitHub owner/repo#N, or a Linear key'

const GROUP_TOOLS = [
  {
    name: 'list_groups',
    description:
      'List the peek groups in this project: titled bundles of related files and links (a collection) shown in the peek side pane. Returns each group id, title, description, star and counts. Call before save_group to reuse a group rather than make a near-duplicate.',
    inputSchema: { type: 'object', properties: {} },
  },
  {
    name: 'read_group',
    description:
      'Read one peek group (a collection or bundle of files and links) in full: title, description, sections, and every item (file or link) with its title (null until peek has fetched it), label, section id, who added it (agent or person) and state (ok, missing, unavailable). Read before you change a group: the person may have added or removed items.',
    inputSchema: { type: 'object', properties: { id: { type: 'string', description: 'The group id from list_groups' } }, required: ['id'] },
  },
  {
    name: 'save_group',
    description:
      'Create or change a peek group: a titled, described bundle of files and links with sections, kept per project in the peek side pane so the person can come back to it. Without id it creates a group (title required); with id it applies the given changes. Changes are edits, never a replace: items the person added stay unless you remove one by name with force, and an item the person removed is only re-added with force. Sections are named by id or title, so one call can add a section and fill it. A section shows its items as cards (the default) or as a list of lines; set it with layout on add, or with the layout action.',
    inputSchema: {
      type: 'object',
      properties: {
        id: { type: 'string', description: 'The group to change; leave out to create one' },
        title: { type: 'string' },
        description: { type: 'string', description: 'Up to 500 characters' },
        sections: {
          type: 'array',
          description: 'Section changes, applied in order before item changes',
          items: {
            type: 'object',
            properties: {
              action: { type: 'string', enum: ['add', 'rename', 'remove', 'layout'] },
              section: { type: 'string', description: 'Section id or title, for rename, remove and layout' },
              title: { type: 'string', description: 'New title, for add and rename' },
              layout: { type: 'string', enum: ['cards', 'list'], description: 'How the section shows its items, for add and layout: cards (the default) or list' },
            },
            required: ['action'],
          },
        },
        order: { type: 'array', items: { type: 'string' }, description: 'Every section, by id or title, in the new order' },
        add: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              target: { type: 'string', description: TARGET_HELP },
              section: { type: 'string', description: 'Section id or title; leave out for the top block' },
              label: { type: 'string', description: 'A short note shown with the item, up to 200 characters' },
              force: { type: 'boolean', description: 'Re-add an item the person removed' },
            },
            required: ['target'],
          },
        },
        move: {
          type: 'array',
          items: {
            type: 'object',
            properties: { target: { type: 'string' }, section: { type: 'string', description: 'Leave out to move to the top block' } },
            required: ['target'],
          },
        },
        remove: {
          type: 'array',
          items: {
            type: 'object',
            properties: { target: { type: 'string' }, force: { type: 'boolean', description: 'Remove an item the person added' } },
            required: ['target'],
          },
        },
      },
    },
  },
  {
    name: 'delete_group',
    description:
      'Delete a peek group: a collection or bundle of files and links. A group the person starred, or one holding items the person added, needs force; without it you are told what would be lost.',
    inputSchema: {
      type: 'object',
      properties: { id: { type: 'string' }, force: { type: 'boolean', description: 'Delete even a starred group or one with items the person added' } },
      required: ['id'],
    },
  },
]

async function listGroupsTool($: EngineInterface) {
  const home = await groupHome($)
  if (!home) return { result: 'Could not list groups: HOME is not set.' }
  const groups = await listGroups(groupsIoOf($), home.place)
  const summaries = groups.map(one => ({
    id: one.id,
    title: one.title,
    description: one.description,
    starred: one.starred,
    sections: one.sections.length,
    items: one.items.length,
    updatedAt: one.updatedAt,
  }))
  const line = groups.length ? `${plural(groups.length, 'group')} in this project.` : 'No groups in this project yet.'
  return { result: `${line}\n${JSON.stringify(summaries)}` }
}

async function readGroupTool($: EngineInterface, id: unknown) {
  if (!isGroupRef(id)) return badId(id)
  const home = await groupHome($)
  if (!home) return { result: 'Could not read the group: HOME is not set.' }
  const group = await readGroup(groupsIoOf($), home.place, id)
  if (!group) return { result: `No group ${id} in this project.` }
  const line = `Group "${group.title}" (${group.id}): ${plural(group.items.length, 'item')} in ${plural(group.sections.length, 'section')}.`
  return { result: `${line}\n${JSON.stringify(await groupJson($, group, home.worktreeRoot))}` }
}

async function deleteGroupTool($: EngineInterface, id: unknown, force: boolean) {
  if (!isGroupRef(id)) return badId(id)
  const home = await groupHome($)
  if (!home) return { result: 'Could not delete the group: HOME is not set.' }
  let title = ''
  const write = await writeGroupHere(groupsIoOf($), home.place, id, current => {
    if (!current) return { group: null, outcomes: [refused('delete', `No group ${id} in this project`)] }
    title = current.title
    return deleteGroup(current, force)
  })
  if (!write.ok) return failedWrite('delete the group', write)
  const [outcome] = write.outcomes
  if (!write.isChanged) return { result: outcome?.reason.startsWith('Not deleted') ? outcome.reason : `Not deleted: ${outcome?.reason ?? 'refused'}.` }
  $.ui.invalidate('ui.render')
  return { result: `Deleted group "${title}" (${id}).` }
}

function freshId(others: readonly Group[]): string {
  const taken = new Set(others.map(one => one.id))
  let id = shortId(Math.random)
  while (taken.has(id)) id = shortId(Math.random)
  return id
}

async function refresh($: EngineInterface, href: string) {
  const current = await read($, view)
  if (current?.page && current.href === href) {
    await refreshPage($, href, current.page)
    return
  }
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
  if (family === 'slack') return index === 0 ? ICON['slack-thread'] : '\u{f086}'
  return '\u{f0ac}'
}

const TIER_NAMES: Record<string, string> = { 'gh-cli': 'via gh', 'web-cli': 'via curl', 'web-api': 'via web fetch', 'linear-api': 'via Linear API', 'slack-mcp': 'via Slack MCP', 'slack-cli': 'via slack' }

function sourceLine(remote: NonNullable<View['remote']>, now: number): string {
  const { tier, fetchedAt, staleSince } = remote
  const family = familyOf(remote.record?.kind ?? 'web')
  const name = tier === 'session' ? 'from this session' : (TIER_NAMES[`${family}-${tier}`] ?? `via ${tier ?? '?'}`)
  const age = fetchedAge(fetchedAt, now)
  const stale = staleSince === undefined ? '' : ` · stale since ${describeAge(staleSince, now)}`
  return `${name}${age ? ` · ${age}` : ''}${stale}`
}

async function redrawIfCurrent($: EngineInterface, address: string) {
  const current = await read($, view)
  // A background load of an overridden link must not turn the recipe page on screen back into the built-in page.
  if (current?.page) return
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
  const hrefs = [...(await read($, mentions)).map(one => one.href), ...(await read($, stars)), ...((await read($, openGroup)) ? openGroupRemotes : [])]
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
  await openFromPage($, current?.page ? paneHref(href) : href)
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

const LIVE_FRAME = 'live-frame'
// No API reports a cell's pixel size; 8 CSS px a column keeps text near its normal size at the 1 MB/s frame budget.
const LIVE_PX_PER_COLUMN = 8
const CELL_ASPECT = 2.1
let live: Live | null = null
let liveHref: string | null = null
let liveViewport: Viewport | null = null
let isLiveFrameDrawn = false
let liveNotice: { href: string; kind: LiveFailureKind } | null = null
let isTyping = false
let lastInputSeq = 0
let liveGeom: FrameGeometry | null = null
const LINE_SCROLL_PX = 80
const WHEEL_SCROLL_PX = 60

function liveIoOf($: EngineInterface): LiveIo {
  return {
    root: $.plugin.root,
    home: () => $.env.get('HOME'),
    read: path => $.fs.read(path),
    exists: path => $.fs.exists(path),
    run: (argv, init) => $.process.run(argv, init),
    spawn: argv => $.process.spawn({ argv }),
    post: async (socket, path, body) => {
      const init = body === undefined ? {} : { body: JSON.stringify(body), headers: { 'content-type': 'application/json' } }
      const answer = await $.http.fetch(`http://peek-web/${path}`, { method: 'POST', socketPath: socket, ...init })
      return answer.ok
    },
    after: (ms, fn) => $.clock.after(ms, fn),
    removeDir: async dir => {
      // Only the helper's own mkdtemp directory: a malformed `ready` must never aim rm at anything else.
      if (/\/peek-web\.[A-Za-z0-9]{6}$/.test(dir)) await $.process.run(['rm', '-rf', dir])
    },
  }
}

function onLiveChange($: EngineInterface, state: LiveState, event?: { t: string }) {
  if (state.failure && liveHref) {
    liveNotice = { href: liveHref, kind: state.failure.kind }
    liveHref = null
    isLiveFrameDrawn = false
  }
  if (event?.t === 'frame' && isLiveFrameDrawn && liveHref && state.frame) {
    const { path, id } = state.frame
    // A refused blit (Image not mounted yet, or mid-resize) is answered with { deny }, not a rejection; a redraw draws the newest frame instead.
    void $.ui.blit({ requestId: PANE, key: LIVE_FRAME, source: { file: path, format: 'png', generation: id } }).then(
      result => {
        if (result.deny) $.ui.invalidate('ui.render')
      },
      () => $.ui.invalidate('ui.render'),
    )
    return
  }
  if (event?.t === 'focus') isTyping = liveHref !== null && state.isEditable
  // A new document has no focused field yet; typing resumes only when the next click lands on one.
  if (event?.t === 'nav' || (event?.t === 'load' && state.load === 'loading')) isTyping = false
  if (event?.t === 'cookies') return
  $.ui.invalidate('ui.render')
}

function sendInput(events: HelperInput[]) {
  if (events.length > 0) void live?.command('input', { events }).catch(() => undefined)
}

function scrollLive(dy: number, at?: { x: number; y: number }) {
  const viewport = liveViewport
  if (!viewport) return
  const point = at ?? { x: Math.floor(viewport.width / 2), y: Math.floor(viewport.height / 2) }
  sendInput([{ type: 'scroll', ...point, dy }])
}

async function liveBack($: EngineInterface) {
  if (live?.state().canBack) await live.command('back')
  else {
    await leaveLive()
    await goBack($)
  }
}

async function liveKey($: EngineInterface, key: string) {
  const height = liveViewport?.height ?? 400
  const url = live?.state().url
  const current = key === 'o' || key === 'c' || key === 'f' ? await read($, view) : null
  switch (key) {
    case 'j':
    case 'down':
      return scrollLive(LINE_SCROLL_PX)
    case 'k':
    case 'up':
      return scrollLive(-LINE_SCROLL_PX)
    case ' ':
    case 'pagedown':
      return scrollLive(Math.round(height * 0.8))
    case 'pageup':
      return scrollLive(-Math.round(height * 0.8))
    case 'b':
      return liveBack($)
    case 'u':
      return void live?.command('reload')
    case 'v':
      return leaveLive().then(() => $.ui.invalidate('ui.render'))
    case 'o':
      return url && isWebUrl(url) ? void $.process.run(['open', url]).catch(() => undefined) : current ? openExternally($, current) : undefined
    case 'c':
      return void $.ui.copy({ text: url ?? current?.location ?? '' })
    case 'f':
      return url || current ? void setStar($, url ?? current?.href ?? '') : undefined
  }
}

type LiveInputEvent = { seq: number; type: 'click'; x: number; y: number } | ({ seq: number; type: 'key' } & TypedKey)

async function onLiveInput($: EngineInterface, events: readonly LiveInputEvent[]) {
  const fresh = events.filter(one => one.seq > lastInputSeq).sort((a, b) => a.seq - b.seq)
  let typed: TypedKey[] = []
  const flush = () => {
    sendInput(typedInput(typed))
    typed = []
  }
  for (const one of fresh) {
    lastInputSeq = one.seq
    if (one.type === 'click') {
      flush()
      if (liveGeom && liveViewport) sendInput([{ type: 'click', ...pagePoint(one, liveGeom, liveViewport) }])
    } else if (isTyping) typed.push(one)
    else {
      flush()
      await liveKey($, one.key)
    }
  }
  flush()
}

function liveOf($: EngineInterface): Live {
  live ??= createLive(liveIoOf($), (state, event) => onLiveChange($, state, event))
  return live
}

function liveBox(columns: number, rows: number): Viewport {
  const width = Math.round(Math.max(320, Math.min(900, columns * LIVE_PX_PER_COLUMN)))
  return { width, height: Math.round((width * rows * CELL_ASPECT) / columns) }
}

async function toggleLive($: EngineInterface, current: View, viewport: Viewport) {
  if (liveHref === current.href) {
    await leaveLive()
    return
  }
  liveNotice = null
  liveHref = current.href
  liveViewport = viewport
  isLiveFrameDrawn = false
  const url = current.remote?.record?.address ?? current.location
  if (!(await liveOf($).start(url, viewport))) liveHref = null
  $.ui.invalidate('ui.render')
}

async function leaveLive() {
  liveHref = null
  isLiveFrameDrawn = false
  isTyping = false
  await live?.leave().catch(() => undefined)
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
          'Star or unstar a file path or URL in the peek side pane, so it sorts first in Recent and Gallery. Star the things the user should look at: a plan, a report, a diagram you made. Use sparingly. For several related files and links, make a peek group instead (save_group).',
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
    for (const spec of GROUP_TOOLS) await $.tool.register(spec).catch(() => undefined)
    void groupHome($).catch(() => undefined)
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
      const rows = await groupPageRows($).catch(() => null)
      if (rows) await selectGroupRow($, rows, index).catch(() => undefined)
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
    await leaveLive()
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
  on('tool.call', { tool: /^mcp__peek__list_groups$/ }, async $ => listGroupsTool($))

  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc; the validator checks this hook
  on('tool.call', { tool: /^mcp__peek__read_group$/ }, async ($, e) => readGroupTool($, (e as unknown as { id?: unknown }).id))

  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc; the validator checks this hook
  on('tool.call', { tool: /^mcp__peek__save_group$/ }, async ($, e) => saveGroup($, e as unknown as SaveInput))

  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc; the validator checks this hook
  on('tool.call', { tool: /^mcp__peek__delete_group$/ }, async ($, e) => {
    const input = e as unknown as { id?: unknown; force?: unknown }
    return deleteGroupTool($, input.id, input.force === true)
  })

  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc; the validator checks this hook
  on('tool.call', { tool: /^(?:Bash$|WebFetch$|mcp__(?!peek__))/ }, async ($, e, next) => {
    const answer = await next(e)
    await noteCapture($, e as unknown as Record<string, unknown>, answer).catch(() => undefined)
    return answer
  })

  on('ui.message', async ($, e, next) => {
    const input = e.data as { liveInput?: unknown } | null
    if (e.requestId === PANE && input && Array.isArray(input.liveInput)) {
      await onLiveInput($, input.liveInput as LiveInputEvent[]).catch(() => undefined)
      return { props: { width: liveGeom?.columns ?? 1, height: liveGeom?.rows ?? 1, acked: lastInputSeq } }
    }
    const starring = e.data as { star?: unknown } | null
    if (e.requestId === PANE && starring && typeof starring.star === 'string') {
      if (starring.star) await setStar($, starring.star).catch(() => undefined)
      return {}
    }
    const data = e.data as { toggle?: unknown } | null
    if (e.requestId === PANE && data && typeof data.toggle === 'string') {
      await pressLink($, data.toggle).catch(() => undefined)
      return {}
    }
    const switching = e.data as { mode?: unknown } | null
    const target = MODES.find(one => one.id === switching?.mode)?.id
    if (e.requestId === PANE && target) {
      await switchMode($, target).catch(() => undefined)
      void $.ui.scroll({ in: PANE, to: 'start' }).catch(() => undefined)
      return {}
    }
    const group = e.data as { openGroup?: unknown; starGroup?: unknown } | null
    if (e.requestId === PANE && group && typeof group.openGroup === 'string') {
      await openGroupPage($, group.openGroup).catch(() => undefined)
      return {}
    }
    if (e.requestId === PANE && group && typeof group.starGroup === 'string') {
      const isGroupsTab = (await read($, mode)) === 'groups' && !(await read($, openGroup))
      await (isGroupsTab ? starInGroupsTab($, group.starGroup) : toggleGroupStar($, group.starGroup)).catch(() => undefined)
      return {}
    }
    const opening = e.data as { open?: unknown; inGroup?: unknown; key?: unknown } | null
    if (e.requestId === PANE && opening && typeof opening.open === 'string' && typeof opening.inGroup === 'string') {
      await openCardItem($, opening.inGroup, String(opening.key ?? ''), opening.open).catch(() => undefined)
      return {}
    }
    if (e.requestId === PANE && opening && typeof opening.open === 'string') {
      if (!opening.open) return {}
      const rows = await groupPageRows($).catch(() => null)
      const at = rows ? rows.hrefs.indexOf(opening.open) : -1
      await (rows && at >= 0 ? openGroupItem($, rows, at) : openLink($, opening.open)).catch(() => undefined)
      return {}
    }
    return next(e)
  })

  on('ui.scroll', { component: 'Pane', requestId: PANE }, async ($, e, next) => {
    if (liveHref && liveGeom && liveViewport && e.pointer) {
      const at = wheelPoint(e.pointer, liveGeom, liveViewport)
      if (at) {
        scrollLive(e.by * WHEEL_SCROLL_PX, at)
        return {}
      }
    }
    const shown = await read($, view).catch(() => null)
    const isList = (await read($, mode).catch(() => 'view')) !== 'view' || !shown || (Boolean(shown.page?.page) && navOrder.length > 0)
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
    const isNarrow = e.props.bodyColumns < NARROW
    const textWidth = isNarrow ? columns : Math.min(MAX_CPL, Math.max(MIN_CPL, columns - 6))
    const pageWidth = isNarrow ? columns : textWidth + 4
    const rows = Math.max(4, e.props.scroll.bodyRows - 4)
    const turn = (to: number) => void update($, page, () => Math.max(0, to))
    if (liveHref && (chosen !== 'view' || current?.href !== liveHref)) void leaveLive()

    const chip = (label: string, isOn: boolean) => (
      <Text color={isOn ? C.appBg : C.overlay0} backgroundColor={isOn ? C.accent : C.panelBg} bold={isOn}>
        {label}
      </Text>
    )
    // crumbs() sets this and header() reads it, so a screen builds its crumb before frame() draws the header.
    let isTabCompact = false
    const chipOf = (id: Mode) => {
      const one = MODES.find(each => each.id === id)
      if (!one) return ''
      return isTabCompact && id !== chosen ? ` ${one.icon} ` : ` ${one.icon} ${one.label.toUpperCase()} `
    }
    const crumbs = (parts: { label: string; fg: string; bg: string; bold?: boolean; canShrink?: boolean }[]) => {
      const width = (label: string) => label.length + 2
      const tabsWidth = () => MODES.reduce((sum, one) => sum + chipOf(one.id).length, 0)
      const fullTabs = MODES.reduce((sum, one) => sum + ` ${one.icon} ${one.label} `.length, 0)
      isTabCompact = !isNarrow && 2 + parts.reduce((sum, one) => sum + width(one.label), 0) > columns - fullTabs - 4
      const room = Math.max(8, isNarrow ? columns - 2 : columns - tabsWidth() - 4)
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
          {tabStrip('tabs-left', [{ id: 'view', label: chipOf('view'), isOn: chosen === 'view' }])}
          {middle as never}
          {tabStrip('tabs-right', [
            { id: 'recent', label: chipOf('recent'), isOn: chosen === 'recent' },
            { id: 'gallery', label: chipOf('gallery'), isOn: chosen === 'gallery' },
            { id: 'groups', label: chipOf('groups'), isOn: chosen === 'groups' },
          ])}
        </Box>
      )

    type Key = { key: string; label: string; hotkey: string; onPress: () => void; menu?: string }
    const footer = (info: string, keys: Key[]) => (
      <Box flexDirection="row" flexWrap="wrap" columnGap={2} justifyContent="center" width={columns}>
        {info && <Text color={C.overlay1}>{info}</Text>}
        {!isNarrow && info && <Text color={C.surface1}>│</Text>}
        <Text color={C.accent}>⌃k menu</Text>
        {/* Hidden, yet the hotkeys still press: the Pane arms every Button in its drawn tree regardless of display (seen in engine 2.1.295, not promised by the types). Tab still visits them. */}
        <Box key="footer-keys" display="none">
          {keys.map(one => (
            <Button key={one.key} label={one.label} hotkey={one.hotkey} plain onPress={one.onPress} />
          ))}
        </Box>
      </Box>
    )
    const modeKeys: Key[] = MODES.map(one => ({
      key: `mode-${one.id}`,
      label: one.label,
      hotkey: one.hotkey,
      onPress: () => void switchMode($, one.id),
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
    const isPageError = Boolean(current?.page && !current.page.page)
    const commands: MenuCommand[] = [
      ...(current
        ? [
            { id: 'peek', icon: ICON.peek, label: 'Peek: show the open file', hint: 'p', run: () => void update($, mode, () => 'view') },
          ]
        : []),
      { id: 'recent', icon: ICON.recent, label: 'Recent: files by last use', hint: 'r', run: () => void update($, mode, () => 'recent') },
      { id: 'gallery', icon: ICON.gallery, label: 'Gallery: files as cards by type', hint: 'g', run: () => void update($, mode, () => 'gallery') },
      { id: 'groups', icon: ICON.groups, label: 'Groups: files and links the agent bundled', hint: 'e', run: () => void switchMode($, 'groups') },
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
            ...(current.remote || current.page
              ? [{ id: 'refresh', icon: '\u{f021}', label: 'Refresh this page', hint: 'u', run: () => void refresh($, current.href) }]
              : []),
            ...(e.surface === 'terminal' && Image && current.remote && parseRef(current.href)?.kind === 'web'
              ? [{ id: 'live', icon: '\u{f0ac}', label: liveHref === current.href ? 'Reader view: leave the live page' : 'Live view: the real page, clickable', hint: 'v', run: () => void toggleLive($, current, liveViewport ?? { width: 600, height: 400 }) }]
              : []),
            ...(liveHref === current.href && live?.state().canBack
              ? [{ id: 'live-back', icon: '\u{f060}', label: 'Back in the live page', hint: 'b', run: () => void liveKey($, 'b') }]
              : []),
            { id: 'copy', icon: '\u{f0c5}', label: current.remote || current.page ? 'Copy link' : 'Copy path', hint: 'c', run: () => void $.ui.copy({ text: current.location }) },
            ...(isPageError ? [] : [{ id: 'star', icon: '\u{f51a}', label: 'Star or unstar this file', hint: 'f', run: () => void setStar($, current.href) }]),
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
    const runCommand = (one: (typeof commands)[number] | undefined) => {
      if (!one) return
      closeMenu()
      one.run()
    }
    const Input = 'Input' in elements ? elements.Input : undefined
    const menuWidth = Math.max(24, Math.min(64, columns - 8))
    const menuFor = (keys: Key[], groupMenu: MenuCommand[]) => {
      const fromKeys = keys.flatMap(one => (one.menu ? [{ id: `key-${one.key}`, icon: '\u{f11c}', label: one.menu, hint: one.hotkey, run: one.onPress }] : []))
      const closeAt = commands.findIndex(one => one.id === 'close')
      const keyed = commands.map(one => {
        const owner = COMMAND_KEYS[one.id.replace(/-[^-]+$/, '-*')] ?? COMMAND_KEYS[one.id]
        return owner ? { ...one, hint: keys.find(key => key.key === owner)?.hotkey ?? '' } : one
      })
      const all: MenuCommand[] = [...keyed.slice(0, closeAt), ...fromKeys, ...groupMenu, ...keyed.slice(closeAt)]
      let others = 0
      // Group rows sit outside the 20-row cap, so every one of the first eight shows however long the rest of the menu is.
      const matches = all.filter(
        one => (words.length > 0 || !one.isFilteredOnly) && words.every(word => one.label.toLowerCase().includes(word)) && (one.isGroupRow || others++ < 20),
      )
      const moves = keys.filter(one => MOVE_KEYS.has(one.key)).map(one => one.hotkey)
      return (
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
          {matches.map(one => (
            <Box key={`menu-row-${one.id}`} flexDirection="row" justifyContent="space-between" width={menuWidth}>
              <Box flexDirection="row" flexShrink={1}>
                <Text color={BASE.accent}>{`${one.icon}  `}</Text>
                <Button key={`menu-${one.id}`} label={one.label} plain onPress={() => runCommand(one)} />
              </Box>
              <Text color={BASE.overlay0}>{one.hint}</Text>
            </Box>
          ))}
          {moves.length > 0 && <Text color={BASE.overlay0}>{`${moves.join(' ')} move`}</Text>}
          <Button key="menu-close" label="Close menu" plain dimColor onPress={closeMenu} />
        </Box>
      )
    }

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
    const frame = async (middle: unknown, content: unknown, info: string, keys: Key[], { pageBg = C.panelBg, menuOn = {} }: { pageBg?: string; menuOn?: GroupMenuFor } = {}) => {
      // A group home that cannot resolve leaves the menu without group rows rather than failing the whole pane.
      const groupMenu = isMenuOpen ? await groupCommands($, menuOn).catch(() => []) : []
      return (
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
              {menuFor(keys, groupMenu) as never}
            </Box>
          )}
        </Box>
      )
    }
    const selectKeys: Key[] = [
      { key: 'next', label: 'Down', hotkey: 'j', onPress: () => void moveSelection($, 'down') },
      { key: 'prev', label: 'Up', hotkey: 'k', onPress: () => void moveSelection($, 'up') },
      { key: 'left', label: 'Left', hotkey: 'h', onPress: () => void moveSelection($, 'left') },
      { key: 'right', label: 'Right', hotkey: 'l', onPress: () => void moveSelection($, 'right') },
      {
        key: 'open-selected',
        label: '⏎ Open',
        hotkey: 'o',
        menu: 'Open the selected file',
        onPress: () => void selectedNav($).then(one => openNav($, one)),
      },
      {
        key: 'star-selected',
        label: 'Star',
        hotkey: 'f',
        menu: 'Star or unstar the selected file',
        onPress: () =>
          void selectedNav($).then(one => {
            if (one?.group) return toggleGroupStar($, one.group)
            return one?.href ? setStar($, one.href).then(() => undefined) : undefined
          }),
      },
    ]
    const closeKey: Key = { key: 'close', label: 'Close', hotkey: 'x', onPress: () => void $.ui.close({ id: PANE }) }
    const expandKey: Key = {
      key: 'expand-selected',
      label: 'More',
      hotkey: 'm',
      menu: 'Expand/Collapse group',
      onPress: () => void selectedNav($).then(one => {
        const id = one?.group ?? (one && chosen === 'groups' ? one.href : undefined)
        if (id) toggleExpanded($, id)
      }),
    }

    const groupCards = async (groups: readonly Group[], prefix: string, firstIndex: number, selected: number) => {
      const inner = Math.max(8, textWidth - 4)
      const perRow = Math.min(2, gridColumns(inner, CARD_MIN, CARD_GAP))
      const itemWidth = Math.floor((inner - (perRow - 1) * CARD_GAP) / perRow)
      const starKeys = new Set((await read($, stars)).map(one => itemKey(remoteRef(one)?.address ?? one)))
      const worktreeRoot = (await groupHome($))?.worktreeRoot
      const known = titlesByKey()
      const drawn = await Promise.all(
        groups.map(async (group, i) => {
          const index = firstIndex + i
          const isSelected = index === selected
          const isExpanded = expandedGroups.has(group.id)
          const sectionIds = new Set(group.sections.map(one => one.id))
          const loose = group.items.filter(one => !one.section || !sectionIds.has(one.section))
          let first = 0
          const blocks = [
            ...(loose.length ? [{ section: -1, title: '', layout: 'cards' as SectionLayout, items: loose }] : []),
            ...group.sections.map((one, section) => ({ section, title: one.title, layout: layoutOf(one), items: group.items.filter(item => item.section === one.id) })),
          ].map(block => {
            const numbered = { ...block, first }
            first += block.items.length
            return numbered
          })
          const description = wrapLines(group.description, inner, Number.POSITIVE_INFINITY)
          const canExpand = description.length > GROUP_CARD_LINES || blocks.length > 1 || (blocks[0]?.items.length ?? 0) > perRow
          const lines = isExpanded ? description : wrapLines(group.description, inner, GROUP_CARD_LINES)
          const shown = isExpanded ? blocks : blocks.slice(0, 1).map(block => ({ ...block, items: block.items.slice(0, perRow) }))
          const looks = await Promise.all(shown.map(block => Promise.all(block.items.map(one => groupItemLook($, one, worktreeRoot, known)))))
          for (const one of looks.flat()) if (one.href && !parseHref(one.href) && remoteRef(one.href) && !cached(one.href)) loadGroupRemote($, one.href)
          const open = (look: GroupLook) => void update($, cursorAtom, () => index).then(() => openGroupHref($, group, look.key, look.href))
          let layers = 0
          const layer = (kind: 'rows' | 'cards', height: number, row: GroupLook[]) =>
            Client && (
              <Box position="absolute" top={0} left={0} width={inner} height={height}>
                <Client
                  key={`hover-${prefix}-items-${i}-${layers++}`}
                  module="./hover-layer.tsx"
                  props={{ kind, width: inner, height, cardWidth: itemWidth, cardHeight: CARD_ROWS, gap: CARD_GAP, starX: kind === 'cards' ? 2 : 0, starY: kind === 'cards' ? 1 : 0, items: row.map(one => ({ href: one.href, isStarred: starKeys.has(one.key), inGroup: group.id, key: one.key })) }}
                  width={inner}
                  height={height}
                />
              </Box>
            )
          const icon = (look: GroupLook, n: number) => {
            const isStarred = starKeys.has(look.key)
            const favicon = look.favicon && Image && !isStarred ? pixels.get(look.favicon) : undefined
            return [
              favicon && Image && (
                <Box key={`${prefix}-fav-${i}-${n}`} flexShrink={0}>
                  <Image key={`${prefix}-favicon-${i}-${n}`} source={{ png: favicon }} columns={2} rows={1} alt={iconFor(look.kind)} />
                </Box>
              ),
              <Box key={`${prefix}-icon-${i}-${n}`} flexShrink={0}>
                <Button key={`${prefix}-it-${i}-${n}`} label={isStarred ? '\u{f51a}' : favicon ? ' ' : iconFor(look.kind)} plain onPress={() => open(look)} />
              </Box>,
            ]
          }
          const itemCard = (look: GroupLook, n: number) => (
            <Box key={`${prefix}-card-${i}-${n}`} flexDirection="column" width={itemWidth} height={CARD_ROWS} paddingX={2} paddingY={1} backgroundColor={C.appBg} hover={{ backgroundColor: C.surface0 }}>
              <Box flexDirection="row" height={1} overflow="hidden">
                {icon(look, n)}
                <Box key={`${prefix}-itname-${i}-${n}`} flexShrink={1}>
                  <Text color={look.state === 'missing' ? C.overlay0 : C.text} bold hover={{ color: C.accent }} wrap="truncate-end">{` ${look.name}`}</Text>
                </Box>
              </Box>
              <Text color={C.overlay0} wrap="truncate-start">{look.where || ' '}</Text>
              <Text color={look.state === 'missing' ? C.red : C.overlay0} wrap="truncate-end">{look.state === 'ok' ? kindLabel(look.kind).label : look.state}</Text>
            </Box>
          )
          const line = (look: GroupLook, n: number) => (
            <Box key={`${prefix}-line-${i}-${n}`} height={1} flexDirection="row" width={inner} overflow="hidden" hover={{ backgroundColor: C.surface0 }}>
              {icon(look, n)}
              <Box key={`${prefix}-itname-${i}-${n}`} flexShrink={0}>
                <Text color={look.state === 'missing' ? C.overlay0 : C.text} hover={{ color: C.accent }} wrap="truncate-end">{`  ${fitName(look.name, Math.max(8, inner - 6))}`}</Text>
              </Box>
              <Box flexShrink={1} flexGrow={1} overflow="hidden">
                <Text color={C.overlay0} wrap="truncate-middle">{look.where ? `  ${look.where}` : ''}</Text>
              </Box>
              <Box flexShrink={0}>
                <Text color={look.state === 'missing' ? C.red : C.overlay1}>{look.state === 'ok' ? '' : ` ${look.state}`}</Text>
              </Box>
            </Box>
          )
          let height = 2 + 1 + (lines.length ? 1 + lines.length : 0) + (canExpand ? 1 : 0) + 1
          const parts = shown.map((block, b) => {
            const blockLooks = looks[b] ?? []
            const rows = Array.from({ length: Math.ceil(blockLooks.length / perRow) }, (_, r) => blockLooks.slice(r * perRow, r * perRow + perRow))
            const body = !blockLooks.length
              ? [<Text key={`${prefix}-empty-${i}-${b}`} color={C.overlay0}>empty</Text>]
              : block.layout === 'list'
                ? [
                    <Box key={`${prefix}-lines-${i}-${b}`} flexDirection="column" width={inner}>
                      {layer('rows', blockLooks.length, blockLooks)}
                      {blockLooks.map((look, j) => line(look, block.first + j))}
                    </Box>,
                  ]
                : rows.map((row, r) => (
                    <Box key={`${prefix}-irow-${i}-${b}-${r}`} flexDirection="row" columnGap={CARD_GAP} marginTop={r ? 1 : 0}>
                      {layer('cards', CARD_ROWS, row)}
                      {row.map((look, c) => itemCard(look, block.first + r * perRow + c))}
                    </Box>
                  ))
            height += 1 + (block.title ? 2 : 0) + (!blockLooks.length ? 1 : block.layout === 'list' ? blockLooks.length : rows.length * (CARD_ROWS + 1) - 1)
            return (
              <Box key={`${prefix}-block-${i}-${b}`} flexDirection="column" width={inner} marginTop={1}>
                {block.title ? (
                  <Box key={`${prefix}-sec-${i}-${block.section}`} flexDirection="column" width={inner}>
                    <Text color={C.text} bold wrap="truncate-end">{block.title}</Text>
                    <Text color={C.surface1}>{'─'.repeat(inner)}</Text>
                  </Box>
                ) : null}
                {body}
              </Box>
            )
          })
          if (!blocks.length) height += 2
          const barLabel = isExpanded ? 'LESS ▲' : 'MORE ▼'
          const barPad = Math.max(0, inner - barLabel.length)
          const node = (
            <Box
              key={`${prefix}-${i}`}
              flexDirection="column"
              width={textWidth}
              paddingX={2}
              paddingY={1}
              marginBottom={1}
              backgroundColor={isSelected ? C.surface0 : C.panelBg}
            >
              <Box flexDirection="row" width={inner} height={1}>
                {Client && (
                  <Box position="absolute" top={0} left={0} width={inner} height={1}>
                    <Client
                      key={`hover-${prefix}-${i}`}
                      module="./hover-layer.tsx"
                      props={{ kind: 'rows', width: inner, height: 1, starX: 0, starY: 0, items: [{ group: group.id, isStarred: group.starred }] }}
                      width={inner}
                      height={1}
                    />
                  </Box>
                )}
                <Box flexShrink={0}>
                  <Button
                    key={`item-${index}`}
                    label={group.starred ? '\u{f51a}' : ICON.groups}
                    plain
                    autoFocus={isSelected ? true : undefined}
                    onPress={() => void update($, cursorAtom, () => index).then(() => openGroupPage($, group.id))}
                  />
                </Box>
                <Box key={`group-name-${index}`} flexGrow={1} flexShrink={1} overflow="hidden">
                  <Text color={isSelected ? C.accent : C.text} bold hover={{ color: C.accent }} wrap="truncate-end">{` ${group.title.toUpperCase()}`}</Text>
                </Box>
                <Box flexShrink={0} marginLeft={1}>
                  <Text color={isSelected ? C.overlay1 : C.overlay0}>{`${plural(group.items.length, 'item')} · ${describeAge(group.updatedAt, now)}`}</Text>
                </Box>
              </Box>
              {lines.length > 0 && <Box height={1} />}
              {lines.map((text, k) => (
                <Text key={`${prefix}-desc-${i}-${k}`} color={C.subtext0}>{text}</Text>
              ))}
              {parts}
              {!blocks.length && (
                <Box marginTop={1}>
                  <Text color={C.overlay0}>No items</Text>
                </Box>
              )}
              {canExpand && (
                <Box key={`${prefix}-morebar-${i}`} width={inner} height={1} backgroundColor={C.accent}>
                  <Button
                    key={`${prefix}-more-${i}`}
                    label={`${' '.repeat(Math.floor(barPad / 2))}${barLabel}${' '.repeat(Math.ceil(barPad / 2))}`}
                    plain
                    onPress={() => void update($, cursorAtom, () => index).then(() => toggleExpanded($, group.id))}
                  />
                </Box>
              )}
            </Box>
          )
          return { node, height }
        }),
      )
      return { cards: drawn.map(one => one.node), heights: drawn.map(one => one.height) }
    }

    if (chosen === 'groups') {
      const home = await groupHome($)
      const io = groupsIoOf($)
      const opened = await read($, openGroup)
      const shown = opened && home ? await shownGroup(io, home.place, opened.id) : null
      if (opened && !shown && goneGroupNotice !== opened.id) {
        goneGroupNotice = opened.id
        $.ui.toast('That group was deleted.')
      }
      const project = (home?.worktreeRoot ?? cwd).split('/').filter(Boolean).pop() ?? 'project'
      if (opened && shown) {
        goneGroupNotice = ''
        const worktreeRoot = home?.worktreeRoot
        const known = titlesByKey()
        const sectionIds = new Set(shown.sections.map(one => one.id))
        const blocks = [
          { title: '', items: shown.items.filter(one => !one.section || !sectionIds.has(one.section)) },
          ...shown.sections.map(one => ({ title: one.title, items: shown.items.filter(item => item.section === one.id) })),
        ]
        const looks = await Promise.all(blocks.flatMap(block => block.items).map(one => groupItemLook($, one, worktreeRoot, known)))
        const remotes = looks.filter(one => one.href && !parseHref(one.href) && remoteRef(one.href))
        for (const one of remotes) if (!cached(one.href)) loadGroupRemote($, one.href)
        openGroupRemotes = remotes.map(one => one.href).filter(isTimed)
        const keys = looks.map(one => one.key)
        const found = opened.item === null ? 0 : keys.indexOf(opened.item)
        const previous = groupRows?.id === shown.id ? groupRows.selected : 0
        const selected = clamp(found >= 0 ? found : previous, keys.length)
        const refs = blocks.flatMap(block => block.items).map(one => one.ref)
        const rows: GroupRows = { id: shown.id, title: shown.title, keys, hrefs: looks.map(one => one.href), selected }
        groupRows = rows
        navOrder = keys.map((key, index) => ({ href: key, key: `group-row-${index}`, line: index, col: 0 }))
        blockStarts = []
        const starList = await read($, stars)
        const starKeys = new Set(starList.map(one => itemKey(remoteRef(one)?.address ?? one)))
        const missing = looks.filter(one => one.state === 'missing').length
        const sectionRule = (label: string, right: string) => (
          <Text wrap="truncate-end">
            <Text color={C.accent} bold>{`${label} `}</Text>
            <Text color={C.surface1}>{'─'.repeat(Math.max(1, textWidth - label.length - right.length - 2))}</Text>
            <Text color={C.overlay0}>{right ? ` ${right}` : ''}</Text>
          </Text>
        )
        const row = (one: GroupLook, index: number) => {
          const isSelected = index === selected
          const isStarred = starKeys.has(one.key)
          const favicon = one.favicon && Image ? pixels.get(one.favicon) : undefined
          const meta = one.state === 'ok' ? '' : one.state
          const leftWidth = Math.max(4, textWidth - meta.length - 1)
          const nameRoom = Math.max(8, Math.floor((leftWidth - 3) * 0.6))
          return (
            <Box
              key={`group-row-${index}`}
              height={1}
              flexDirection="row"
              justifyContent="space-between"
              width={textWidth}
              backgroundColor={isSelected ? C.surface0 : undefined}
              hover={{ backgroundColor: C.surface0 }}
            >
              <Box flexDirection="row" width={leftWidth} height={1} overflow="hidden">
                {favicon && !isStarred && Image && (
                  <Box flexShrink={0}>
                    <Image key={`favicon-${index}`} source={{ png: favicon }} columns={2} rows={1} alt={iconFor(one.kind)} />
                  </Box>
                )}
                <Box flexShrink={0}>
                  <Button
                    key={`item-${index}`}
                    label={isStarred ? '\u{f51a}' : favicon ? ' ' : iconFor(one.kind)}
                    plain
                    autoFocus={isSelected ? true : undefined}
                    onPress={() => void openGroupItem($, rows, index)}
                  />
                </Box>
                <Box key={`group-item-${index}`} flexShrink={0}>
                  <Text color={one.state === 'missing' ? C.overlay0 : isSelected ? C.accent : C.text} bold={isSelected} hover={{ color: C.accent }} wrap="truncate-end">{`  ${fitName(one.name, nameRoom)}`}</Text>
                </Box>
                <Box flexShrink={1} flexGrow={1} overflow="hidden">
                  <Text color={C.overlay0} wrap="truncate-middle">{one.where ? `  ${one.where}` : ''}</Text>
                </Box>
              </Box>
              <Box key={`group-meta-${index}`} flexShrink={0} height={1}>
                <Text color={one.state === 'missing' ? C.red : C.overlay1}>{meta}</Text>
              </Box>
            </Box>
          )
        }
        let next = 0
        const drawn = blocks.map((block, b) => {
          const first = next
          next += block.items.length
          const blockLooks = looks.slice(first, next)
          const list = blockLooks.length > 0 && (
            <Box key={`group-block-${b}`} flexDirection="column" width={textWidth}>
              {Client && (
                <Box position="absolute" top={0} left={0} width={textWidth} height={blockLooks.length}>
                  <Client
                    key={`hover-group-${b}`}
                    module="./hover-layer.tsx"
                    props={{ kind: 'rows', width: textWidth, height: blockLooks.length, starX: 0, starY: 0, items: blockLooks.map(one => ({ href: one.href, isStarred: starKeys.has(one.key) })) }}
                    width={textWidth}
                    height={blockLooks.length}
                  />
                </Box>
              )}
              {blockLooks.map((one, j) => row(one, first + j))}
            </Box>
          )
          if (b === 0) return list ? <Box key="group-top" flexDirection="column" width={textWidth} marginBottom={1}>{list}</Box> : null
          return (
            <Box key={`group-part-${b}`} flexDirection="column" width={textWidth} marginBottom={1}>
              <Box key={`group-section-${b - 1}`}>{sectionRule(block.title.toUpperCase(), `${block.items.length}`)}</Box>
              {list || (
                <Box key={`group-empty-${b - 1}`}>
                  <Text color={C.overlay0}>empty</Text>
                </Box>
              )}
            </Box>
          )
        })
        estimatedRows = Math.max(1, looks.length + blocks.length * 2 + 3)
        const content = (
          <Box flexDirection="column" width={textWidth}>
            <Box key="group-page-title">
              <Text color={C.accent} bold>{`${shown.starred ? '\u{f51a}' : ICON.groups} ${shown.title}`}</Text>
            </Box>
            {shown.description ? <Text color={C.subtext0}>{shown.description}</Text> : null}
            <Box height={1} />
            {shown.items.length === 0 && (
              <Box key="group-no-items" marginBottom={1}>
                <Text color={C.overlay0}>No items</Text>
              </Box>
            )}
            {drawn}
          </Box>
        )
        const crumb = crumbs([
          { label: `${ICON.groups} ${project}`, fg: C.overlay1, bg: C.surface0, canShrink: true },
          { label: `${shown.starred ? '\u{f51a}' : ICON.groups} ${shown.title}`, fg: C.appBg, bg: C.accent, bold: true, canShrink: true },
        ])
        return frame(
          crumb,
          content,
          `${shown.title} · ${plural(looks.length, 'item')} · ${missing} missing`,
          [
            ...modeKeys,
            { key: 'next', label: 'Down', hotkey: 'j', onPress: () => void moveSelection($, 'down') },
            { key: 'prev', label: 'Up', hotkey: 'k', onPress: () => void moveSelection($, 'up') },
            {
              key: 'open-selected',
              label: '⏎ Open',
              hotkey: 'o',
              menu: 'Open the selected item',
              onPress: () => void groupPageRows($).then(now => (now ? openGroupItem($, now, now.selected) : undefined)),
            },
            {
              key: 'star-selected',
              label: 'Star',
              hotkey: 'f',
              menu: 'Star or unstar the selected item',
              onPress: () => void groupPageRows($).then(now => {
                const href = now?.hrefs[now.selected]
                return href ? setStar($, href).then(() => $.ui.invalidate('ui.render')) : undefined
              }),
            },
            closeKey,
          ],
          { pageBg: C.appBg, menuOn: { target: rows.hrefs[selected] || undefined, group: shown, selectedRef: refs[selected] } },
        )
      }
      groupRows = null
      openGroupRemotes = []
      const groups = home ? starredFirst(await shownGroups(io, home.place)) : []
      const starredCount = groups.filter(one => one.starred).length
      const crumb = crumbs([{ label: `${ICON.groups} ${project}`, fg: C.appBg, bg: C.accent, bold: true, canShrink: true }])
      const selected = await read($, cursorAtom)
      const { cards, heights } = await groupCards(groups, 'groups', 0, selected)
      navOrder = groups.map((one, i) => ({ href: one.id, key: `groups-${i}`, line: i, col: 0 }))
      blockStarts = heights.map((_, i) => sum(heights.slice(0, i)))
      estimatedRows = Math.max(1, sum(heights))
      const selectedGroup = () => read($, cursorAtom).then(at => navOrder[clamp(at, navOrder.length)]?.href)
      const content = (
        <Box flexDirection="column" width={textWidth}>
          {groups.length === 0 && <Text color={C.overlay0}>No groups yet. The agent makes groups: ask it to group related files and links.</Text>}
          {cards}
        </Box>
      )
      return frame(
        crumb,
        content,
        `${plural(groups.length, 'group')} · ${starredCount} starred`,
        [
          ...modeKeys,
          ...selectKeys.filter(one => MOVE_KEYS.has(one.key)),
          {
            key: 'open-selected',
            label: '⏎ Open',
            hotkey: 'o',
            menu: 'Open the selected group',
            onPress: () => void selectedGroup().then(id => (id ? openGroupPage($, id) : undefined)),
          },
          {
            key: 'star-selected',
            label: 'Star',
            hotkey: 'f',
            menu: 'Star or unstar the selected group',
            onPress: () => void selectedGroup().then(id => (id ? starInGroupsTab($, id) : undefined)),
          },
          expandKey,
          closeKey,
        ],
        { pageBg: C.appBg, menuOn: { group: groups[clamp(selected, groups.length)], starHint: 'f' } },
      )
    }

    const cardGridOf = <T,>(sink: NavSink, lookOf: (one: T) => ItemLook) => (list: readonly T[], prefix: string) => {
      const perRow = gridColumns(textWidth, CARD_MIN, CARD_GAP)
      const cardWidth = Math.floor((textWidth - (perRow - 1) * CARD_GAP) / perRow)
      const looks = list.map(lookOf)
      const rowsOfCards = Array.from({ length: Math.ceil(looks.length / perRow) }, (_, r) => looks.slice(r * perRow, r * perRow + perRow))
      const firstNav = sink.nav.length
      rowsOfCards.forEach((cards, r) => {
        sink.keys.push(`${prefix}-${r}`)
        sink.starts.push(sink.cursor + r * (CARD_ROWS + 1))
        const line = sink.line++
        cards.forEach((look, col) => sink.nav.push({ href: look.href, key: `${prefix}-${r}`, line, col }))
      })
      sink.cursor += rowsOfCards.length * (CARD_ROWS + 1)
      return rowsOfCards.map((cards, r) => (
        <Box key={`${prefix}-${r}`} flexDirection="row" columnGap={CARD_GAP} marginBottom={1}>
          {Client && (
            <Box position="absolute" top={0} left={0} width={textWidth} height={CARD_ROWS}>
              <Client
                key={`hover-${prefix}-${r}`}
                module="./hover-layer.tsx"
                props={{ kind: 'cards', width: textWidth, height: CARD_ROWS, cardWidth, cardHeight: CARD_ROWS, gap: CARD_GAP, starX: 2, starY: 1, items: cards.map(look => ({ href: look.href, isStarred: look.isStarred })) }}
                width={textWidth}
                height={CARD_ROWS}
              />
            </Box>
          )}
          {cards.map((look, c) => {
            const index = firstNav + r * perRow + c
            const isSelected = index === sink.selected
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
                <Text color={isSelected ? C.overlay1 : C.overlay0} wrap="truncate-end">{look.detail}</Text>
              </Box>
            )
          })}
        </Box>
      ))
    }
    const rowListOf = <T,>(sink: NavSink, lookOf: (one: T) => ItemLook) => (items: readonly T[], prefix: string) => {
      const looks = items.map(lookOf)
      const chunks = Array.from({ length: Math.ceil(looks.length / LIST_CHUNK) }, (_, i) =>
        looks.slice(i * LIST_CHUNK, i * LIST_CHUNK + LIST_CHUNK),
      )
      const firstNav = sink.nav.length
      chunks.forEach((chunk, i) => {
        sink.keys.push(`${prefix}-${i}`)
        sink.starts.push(sink.cursor)
        sink.cursor += chunk.length
        for (const look of chunk) sink.nav.push({ href: look.href, key: `${prefix}-${i}`, line: sink.line++, col: 0 })
      })
      return chunks.map((chunk, i) => (
        <Box key={`${prefix}-${i}`} flexDirection="column" width={textWidth}>
          {Client && (
            <Box position="absolute" top={0} left={0} width={textWidth} height={chunk.length}>
              <Client
                key={`hover-${prefix}-${i}`}
                module="./hover-layer.tsx"
                props={{ kind: 'rows', width: textWidth, height: chunk.length, starX: 0, starY: 0, items: chunk.map(look => ({ href: look.href, isStarred: look.isStarred })) }}
                width={textWidth}
                height={chunk.length}
              />
            </Box>
          )}
          {chunk.map((look, j) => {
            const index = firstNav + i * LIST_CHUNK + j
            const isSelected = index === sink.selected
            const leftWidth = Math.max(4, textWidth - look.detail.length - 1)
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
                  <Text color={C.overlay0}>{look.detail}</Text>
                </Box>
              </Box>
            )
          })}
        </Box>
      ))
    }

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
      const section = (label: string, right: string) => (
        <Text wrap="truncate-end">
          <Text color={C.accent} bold>{`${label} `}</Text>
          <Text color={C.surface1}>{'─'.repeat(Math.max(1, textWidth - label.length - right.length - 2))}</Text>
          <Text color={C.overlay0}>{right ? ` ${right}` : ''}</Text>
        </Text>
      )
      const selected = await read($, cursorAtom)
      const sink: NavSink = { nav: [], keys: [], starts: [], cursor: 0, line: 0, selected }
      const { nav, keys, starts } = sink
      navOrder = nav
      const cardGrid = cardGridOf(sink, (one: FileEntry) => {
        const { where, age } = describe(one)
        return { ...looks(one), detail: `${where}${age} · ${one.status ?? describeSize(one.size)}` }
      })
      const favouritesBlock = (shownFavs: readonly FileEntry[]) => {
        if (!shownFavs.length) return null
        sink.cursor += 2
        const grid = cardGrid(shownFavs, 'favs')
        sink.cursor += 1
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
        sink.cursor = 2
        const favBlock = favouritesBlock(favs)
        const groups = groupsOf(picked).map(group => {
          sink.cursor += 2
          const grid = cardGrid(group.items, group.id)
          sink.cursor += 1
          return { ...group, grid }
        })
        blockStarts = starts
        estimatedRows = Math.max(1, sink.cursor)
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
            { key: 'type', label: 'Type', hotkey: 't', menu: `Next file type (now ${type})`, onPress: () => void update($, galleryType, one => nextOf(TYPES, one)) },
            { key: 'sort', label: 'Sort', hotkey: 'n', menu: `Next sort order (now ${sort})`, onPress: () => void update($, gallerySort, one => nextOf(SORTS, one)) },
            ...selectKeys,
            closeKey,
          ],
          { pageBg: C.appBg, menuOn: { target: nav[clamp(selected, nav.length)]?.href } },
        )
      }

      const favs = selectEntries(favourites, 'all', '', 'recent')
      const recentList = rest ? selectEntries(rest, 'all', '', 'recent').slice(0, 300) : []
      sink.cursor = 0
      const starredGroups = await groupHome($)
        .then(found => (found ? shownGroups(groupsIoOf($), found.place) : []))
        .then(all => all.filter(one => one.starred))
        .catch(() => [])
      const pinned = starredGroups.slice(0, PINNED_GROUPS)
      const pinnedBlock = await (async () => {
        if (!pinned.length) return null
        sink.cursor += 2
        const { cards: grid, heights } = await groupCards(pinned, 'starred', nav.length, selected)
        pinned.forEach((one, i) => {
          keys.push(`starred-${i}`)
          starts.push(sink.cursor)
          sink.cursor += heights[i] ?? 0
          nav.push({ href: '', group: one.id, key: `starred-${i}`, line: sink.line++, col: 0 })
        })
        sink.cursor += 1
        const count = starredGroups.length > pinned.length ? `${pinned.length} of ${starredGroups.length} · e for all` : `${pinned.length}`
        return (
          <Box flexDirection="column" width={textWidth}>
            {section('STARRED GROUPS', count)}
            <Box height={1} />
            {grid}
          </Box>
        )
      })()
      const favBlock = favouritesBlock(favs)
      const rowList = rowListOf(sink, (one: FileEntry) => {
        const { where, age } = describe(one)
        const count = one.mentions > 1 ? `${one.mentions}× · ` : ''
        return { ...looks(one), detail: `${one.status ? `${one.status} · ` : ''}${where}${count}${age}` }
      })
      const groups = groupsOf(recentList).map(group => {
        sink.cursor += 2
        const list = rowList(group.items, group.id)
        sink.cursor += 1
        return { ...group, list }
      })
      blockStarts = starts
      estimatedRows = Math.max(1, sink.cursor)
      const jumps = keyJumps(keys)
      const pinnedId = nav[clamp(selected, nav.length)]?.group
      const pinnedOn = pinned.find(one => one.id === pinnedId)
      const content = (
        <Box flexDirection="column" width={textWidth}>
          {pinnedBlock}
          {favBlock}
          {!rest && waiting}
          {rest && recentList.length === 0 && favs.length === 0 && pinned.length === 0 && (
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
          ...selectKeys.map(one => {
            if (!pinnedOn) return one
            if (one.key === 'open-selected') return { ...one, menu: 'Open the selected group' }
            return one.key === 'star-selected' ? { ...one, menu: 'Unstar the selected group' } : one
          }),
          ...(pinned.length ? [expandKey] : []),
          closeKey,
        ],
        { pageBg: C.appBg, menuOn: pinnedOn ? { group: pinnedOn, starHint: 'f' } : { target: nav[clamp(selected, nav.length)]?.href } },
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
    // An embed's content is textWidth - 2 wide; height follows the picture, capped so it fits on screen.
    const fullWidth = (width: number, height: number) => imageBox(width, height, textWidth - 2, Math.max(IMAGE_ROWS, e.props.scroll.bodyRows - PAGE_TOP - FOOTER_ROWS - 6))
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
    const diagramEmbed = (key: string, info: string, text: string) =>
      embed(key, ICON.mermaid, 'DIAGRAM', info, C.mauve, (
        <Text color={C.subtext0}>{text}</Text>
      ))
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

    const blockWriters = ({ drawnParts, note, media, pictures, memoBase, refs }: BlockSink) => {
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
      let imageBytes = 0
      const fitsPane = (png: string) => {
        if (imageBytes + png.length > IMAGE_TREE_BUDGET) return false
        imageBytes += png.length
        return true
      }
      const mediaBlock = (index: number, alt: string, url: string, heading: string) => {
        const key = `media-${index}`
        const one = media?.[url]
        const picture = pictures?.[url]
        const loadedPng = picture && pixels.get(picture.file)
        const png = loadedPng && fitsPane(loadedPng) ? loadedPng : undefined
        const host = (() => {
          try {
            return new URL(url).host
          } catch {
            return url
          }
        })()
        drawnParts.push(
          embed(key, one?.play ? '\u{f03d}' : ICON.image, one?.play ? 'VIDEO' : 'IMAGE', alt || host, C.teal, (
            <Box flexDirection="column">
              {png && Image && picture ? (
                <Image key={`${key}-image`} source={{ png }} {...fullWidth(picture.width, picture.height)} alt={alt || 'image'} />
              ) : (
                !one?.play && <Markdown dimColor={isMenuOpen} key={`${key}-link`} text={`[open image](${url})`} onLinkPress={link => void pressLink($, link.href)} />
              )}
              {one?.play && (
                <Button key={`media-play-${index}`} label="\u{f04b} Play video" plain onPress={() => void (isWebUrl(url) && $.process.run(['open', url]).catch(() => undefined))} />
              )}
            </Box>
          )),
        )
        note(png && picture ? fullWidth(picture.width, picture.height).rows + 4 : 4, heading)
      }
      let mediaCount = 0
      // Splits out picture lines and drawn diagrams; a fence's contents stay in the text around them.
      const markdownBlocks = (key: string, text: string, heading: string, indent = 0) => {
        if (!media && !text.includes('```peek-diagram')) return markdownChunks(key, text, heading, indent)
        let pending = ''
        let segment = 0
        let fence = ''
        let diagram: { info: string; lines: string[] } | null = null
        const flush = () => {
          if (pending.trim()) markdownChunks(`${key}-${segment++}`, pending, heading, indent)
          pending = ''
        }
        for (const line of text.split('\n')) {
          if (diagram) {
            if (/^\s*```\s*$/.test(line)) {
              drawnParts.push(diagramEmbed(`${key}-diagram-${segment++}`, diagram.info, diagram.lines.join('\n')))
              note(diagram.lines.length + 4, heading)
              diagram = null
            } else diagram.lines.push(line)
            continue
          }
          const marker = /^\s*(```|~~~)/.exec(line)?.[1]
          const drawn = !fence && /^```peek-diagram\s*(.*)$/.exec(line)
          if (drawn) {
            flush()
            diagram = { info: drawn[1] ?? '', lines: [] }
            continue
          }
          if (marker && (!fence || marker === fence)) fence = fence ? '' : marker
          const found = !fence && !marker && /^!\[([^\]]*)\]\(([^)\s]+)\)\s*$/.exec(line.trim())
          if (found && media?.[found[2] ?? '']) {
            flush()
            mediaBlock(mediaCount++, found[1] ?? '', found[2] ?? '', heading)
          } else pending += `${line}\n`
        }
        if (diagram) pending += ['```text', ...diagram.lines, '```'].join('\n')
        flush()
      }
      const markdownChunks = (key: string, text: string, heading: string, indent = 0) => {
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
      return { sectionRule, fitsPane, mediaBlock, markdownBlocks, markdownChunks }
    }

    let body: unknown = null
    let position = ''
    let jumps: { next: () => void; prev: () => void } = { next: () => {}, prev: () => {} }
    let pageKeys: Key[] = []
    if (current.page) {
      const state = current.page
      const shownPage = state.page
      if (shownPage) {
        const pictures = state.pictures
        const starKeys = new Set((await read($, stars)).map(one => itemKey(remoteRef(one)?.address ?? one)))
        const memoBase = `${current.href}|${state.fetchedAt}|${textWidth}`
        const drawn = drawPage(
          {
            elements: { Box, Text, Button, ...(Client ? { Client } : {}) },
            colors: C,
            blocks: sink => blockWriters({ ...sink, media: state.media, pictures, memoBase, refs: refContext() }),
            cards: cardGridOf,
            rows: rowListOf,
            isStarred: href => starKeys.has(itemKey(remoteRef(href)?.address ?? href)),
            link: paneHref,
            picture: url => {
              const one = pictures?.[url]
              return one ? pixels.get(one.file) : undefined
            },
            pick: index => void selectAndOpen($, index),
            open: href => void openFromPage($, paneHref(href)),
            copy: text => void $.ui.copy({ text }),
            notice: text => $.ui.toast(text),
          },
          shownPage,
          { width: textWidth, selected: await read($, cursorAtom) },
        )
        navOrder = drawn.nav
        pageKeys = drawn.keys
        ;({ body, jumps, position } = settleBlocks(drawn.parts, drawn.rows, drawn.headings))
      } else {
        navOrder = []
        const { drawnParts, partRows, partHeadings, note } = newBlocks()
        if (state.failure) {
          drawnParts.push(
            <Box key="page-failure" flexDirection="column">
              <Text color={C.red} bold>Recipe page failed</Text>
              <Text color={C.subtext0}>{state.failure}</Text>
              <Text color={C.overlay0}>Press u to try again, or o to open the link in the browser.</Text>
            </Box>,
          )
          note(estimateRows(state.failure, textWidth) + 2)
        } else {
          drawnParts.push(
            <Box key="page-loading" flexDirection="column">
              <Text color={C.overlay1}>{`Running ${state.name}…`}</Text>
              <Text color={C.overlay0} wrap="truncate-end">{state.link}</Text>
            </Box>,
          )
          note(2)
        }
        ;({ body, jumps, position } = settleBlocks(drawnParts, partRows, partHeadings))
      }
    } else if (current.remote) {
      const remote = current.remote
      const record = remote.record
      const { drawnParts, partRows, partHeadings, note } = newBlocks()
      const kindColor = (kind: string) => (isMenuOpen ? mute(colorFor(kind)) : colorFor(kind))
      const ghRef = record?.kind.startsWith('gh-') ? parseRef(record.address) : null
      const refs = refContext(ghRef?.owner && ghRef.repo ? `${ghRef.owner}/${ghRef.repo}` : undefined)
      const memoBase = `${current.href}|${remote.fetchedAt}|${textWidth}|${refs.teamKeys?.length}|${refs.workspace}`
      const { sectionRule, fitsPane, markdownBlocks } = blockWriters({ drawnParts, note, media: record?.media, pictures: remote.pictures, memoBase, refs })
      if (!record) {
        const message = failureText(remote.failure ?? 'offline')
        drawnParts.push(
          <Box key="remote-failure" flexDirection="column">
            <Text color={C.red} bold>{message.title}</Text>
            {remote.failureDetail && <Text color={C.overlay1}>{remote.failureDetail}</Text>}
            <Text color={C.subtext0}>{message.hint}</Text>
            <Text color={C.overlay0}>Press o to open it in the browser.</Text>
          </Box>,
        )
        note(remote.failureDetail ? 4 : 3)
      } else {
        const faviconPng = remote.favicon && pixels.get(remote.favicon.file)
        const favicon = faviconPng && fitsPane(faviconPng) ? faviconPng : undefined
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
        const previewPng = remote.preview && pixels.get(remote.preview.file)
        const preview = previewPng && fitsPane(previewPng) ? previewPng : undefined
        const previewBox = preview && Image && remote.preview ? fullWidth(remote.preview.width, remote.preview.height) : null
        const ogDescription = record.og?.description
        drawnParts.push(
          embed('remote-meta', iconFor(record.kind), 'DETAILS', record.status ?? '', kindColor(record.kind), (
            <Box flexDirection="column">
              {previewBox && preview && Image && <Image key="remote-preview-image" source={{ png: preview }} {...previewBox} alt="preview image" />}
              {ogDescription && (
                <Box marginTop={previewBox ? 1 : 0} marginBottom={1}>
                  <Text color={C.subtext0}>{ogDescription}</Text>
                </Box>
              )}
              {record.meta.map((one, i) => (
                <Text key={`meta-${i}`} wrap="truncate-end">
                  <Text color={C.overlay0}>{(META_ICON[one.label] ?? one.label).padEnd(labelWidth)}</Text>
                  <Text color={C.text}>{one.value}</Text>
                </Text>
              ))}
            </Box>
          )),
        )
        note(record.meta.length + 4 + (previewBox?.rows ?? 0) + (ogDescription ? estimateRows(ogDescription, textWidth - 2) + 1 : 0), 'Details')
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
          const label = record.kind === 'gh-repo' ? 'README' : record.kind === 'web' ? 'Page' : record.kind === 'slack-thread' ? 'Message' : 'Description'
          sectionRule('body-head', label)
          markdownBlocks('body', record.body, label)
        }
        const openInSlack = (href: string | undefined) => void (href && isWebUrl(href) && $.process.run(['open', href]).catch(() => undefined))
        const slackFiles = (key: string, one: RemoteComment, width: number) => {
          const rows: unknown[] = []
          let height = 0
          for (const [fi, file] of (one.files ?? []).entries()) {
            const picture = remote.pictures?.[`slack-file:${file.id}`]
            const loaded = picture && pixels.get(picture.file)
            const png = loaded && Image && fitsPane(loaded) ? loaded : undefined
            if (png && picture && Image) {
              const box = imageBox(picture.width, picture.height, width, Math.max(IMAGE_ROWS, e.props.scroll.bodyRows - PAGE_TOP - FOOTER_ROWS - 6))
              rows.push(<Image key={`${key}-${fi}`} source={{ png }} {...box} alt={file.name} />)
              height += box.rows
              continue
            }
            rows.push(
              <Box key={`${key}-${fi}`} flexDirection="row" width={width}>
                <Text color={C.teal}>{`${file.type.startsWith('image/') ? ICON.image : ICON.file} `}</Text>
                <Box flexShrink={1}>
                  <Text color={C.subtext0} wrap="truncate-end">{[file.name, file.type, file.size].filter(Boolean).join(' · ')}</Text>
                </Box>
                {one.href && (
                  <Box flexShrink={0} marginLeft={2}>
                    <Markdown dimColor={isMenuOpen} key={`${key}-${fi}-open`} text={`[open in Slack](${one.href})`} onLinkPress={link => openInSlack(link.href)} />
                  </Box>
                )}
              </Box>,
            )
            height += 1
          }
          return { rows, height }
        }
        const slackMessage = (index: number, one: RemoteComment, isReply: boolean) => {
          const key = `slack-msg-${index}`
          const width = textWidth - (isReply ? 4 : 0)
          const color = isMenuOpen ? mute(speakerColor(one.authorId ?? one.author)) : speakerColor(one.authorId ?? one.author)
          const avatar = one.authorId ? remote.avatars?.[one.authorId] : undefined
          const avatarPng = avatar && pixels.get(avatar.file)
          const face = avatarPng && Image && fitsPane(avatarPng) ? avatarPng : undefined
          const when = whenLabel(one.at, now)
          const bodyParts: unknown[] = []
          let bodyRows = 0
          let pending: string[] = []
          const flush = () => {
            const chunk = pending.join('\n')
            pending = []
            if (!chunk.trim()) return
            bodyParts.push(<Markdown dimColor={isMenuOpen} key={`${key}-md-${bodyParts.length}`} text={chunk} onLinkPress={link => void pressLink($, link.href)} />)
            bodyRows += estimateRows(chunk, width)
          }
          for (const line of linkify(one.body || '*(empty)*', () => null, refs).split('\n')) {
            const found = /^\s*!\[([^\]]*)\]\(([^)\s]+)\)\s*$/.exec(line)
            if (!found) {
              pending.push(line)
              continue
            }
            const [, alt = '', url = ''] = found
            const picture = remote.pictures?.[url]
            const loaded = picture && pixels.get(picture.file)
            const png = loaded && Image && fitsPane(loaded) ? loaded : undefined
            if (!png || !picture || !Image) {
              pending.push(`[${alt || 'open image'}](${url})`)
              continue
            }
            flush()
            const box = imageBox(picture.width, picture.height, width, Math.max(IMAGE_ROWS, e.props.scroll.bodyRows - PAGE_TOP - FOOTER_ROWS - 6))
            bodyParts.push(<Image key={`${key}-picture-${bodyParts.length}`} source={{ png }} {...box} alt={alt || 'image'} />)
            bodyRows += box.rows
          }
          flush()
          const files = slackFiles(`slack-file-${index}`, one, width)
          const rows = 2 + bodyRows + files.height
          const content = (
            <Box flexDirection="column" width={width}>
              <Box flexDirection="row" height={2}>
                <Box flexShrink={0} width={4} marginRight={1}>
                  {face && Image ? (
                    <Image key={`slack-avatar-${index}`} source={{ png: face }} columns={4} rows={2} alt={one.author} />
                  ) : (
                    <Text backgroundColor={color} color={C.appBg} bold>{` ${initials(one.author)} `}</Text>
                  )}
                </Box>
                <Box flexDirection="column" flexShrink={1}>
                  <Text color={color} bold wrap="truncate-end">{one.author}</Text>
                  {one.href ? <Button key={`slack-time-${index}`} label={when} plain onPress={() => openInSlack(one.href)} /> : <Text color={C.overlay0}>{when}</Text>}
                </Box>
              </Box>
              {bodyParts as never}
              {files.rows as never}
            </Box>
          )
          drawnParts.push(
            isReply ? (
              <Box key={key} flexDirection="row" marginLeft={1}>
                <Box flexShrink={0} width={3}>
                  <Text color={C.surface1}>{Array.from({ length: rows }, () => '│').join('\n')}</Text>
                </Box>
                {content}
              </Box>
            ) : (
              <Box key={key}>{content}</Box>
            ),
          )
          note(rows, 'Thread')
        }
        const lead = record.kind === 'slack-thread' ? record.lead : undefined
        if (lead) {
          sectionRule('thread-head', 'Thread', record.status ?? '')
          slackMessage(0, lead, false)
          for (const [i, one] of (record.comments?.shown ?? []).entries()) slackMessage(i + 1, one, true)
        } else if (record.kind === 'gh-repo' || record.kind === 'linear-issue') {
          lists()
          description()
        } else {
          description()
          lists()
        }
        const comments = lead ? undefined : record.comments
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
            drawnParts.push(diagramEmbed(`diagram-${index}`, part.info, part.text))
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
    const liveState = live?.state()
    const canLive = e.surface === 'terminal' && Boolean(Image) && current.remote !== undefined && parseRef(current.href)?.kind === 'web'
    const liveRows = Math.max(4, e.props.scroll.bodyRows - PAGE_TOP - FOOTER_ROWS - 2)
    const viewport = liveBox(textWidth, liveRows)
    const isLiveHere = canLive && liveHref === current.href && liveState !== undefined && liveState.phase !== 'off'
    const liveFrame = isLiveHere ? liveState.frame : undefined
    if (liveFrame && Image) {
      isLiveFrameDrawn = true
      if (liveViewport && (liveViewport.width !== viewport.width || liveViewport.height !== viewport.height)) {
        liveViewport = viewport
        void live?.command('resize', viewport)
      }
      liveGeom = { left: Math.floor((e.props.bodyColumns - pageWidth) / 2) + (isNarrow ? 0 : 2), top: HEADER_ROWS + 1 - offset, columns: textWidth, rows: liveRows }
      body = (
        <Box width={textWidth} height={liveRows}>
          <Image
            key={LIVE_FRAME}
            source={{ file: liveFrame.path, format: 'png', generation: liveFrame.id }}
            columns={textWidth}
            rows={liveRows}
            alt={`${current.title} (the live view cannot draw here: press v for the reader page)`}
          />
          {Client && (
            <Box position="absolute" top={0} left={0} width={textWidth} height={liveRows}>
              <Client key="live-input" module="./live-input.tsx" props={{ width: textWidth, height: liveRows, acked: lastInputSeq }} width={textWidth} height={liveRows} />
            </Box>
          )}
        </Box>
      )
      position = ''
    }
    const liveStatus = isLiveHere ? liveStatusText(liveState, current.location) : ''
    const notice = liveNotice?.href === current.href ? failureText(liveNotice.kind) : null
    const goNext = jumps.next
    const goPrev = jumps.prev
    const starTarget = (liveFrame && liveState?.url) || current.href
    const isStarred = (await read($, stars)).some(one => itemKey(remoteRef(one)?.address ?? one) === itemKey(starTarget))
    const remote = current.remote
    const source = remote?.record ? sourceLine(remote, now) : current.page ? pageSourceLine(current.page, now) : ''
    const info = liveFrame
      ? [isStarred ? '\u{f51a} starred' : '', liveStatus].filter(Boolean).join(' · ')
      : [liveStatus, isStarred ? '\u{f51a} starred' : '', source, position, current.summary, current.tasks].filter(Boolean).join(' · ')
    const remoteCrumbs = remote
      ? [
          ...(remote.record?.trail ?? []).map((label, index, all) => ({
            label: `${trailIcon(current.kind ?? 'web', index, all.length)} ${label}`,
            fg: C.subtext0 as string,
            bg: C.surface1 as string,
            canShrink: true,
          })),
          { label: `${iconFor(current.kind)} ${liveFrame && liveState?.title ? liveState.title : current.title}`, fg: C.appBg, bg: C.accent, bold: true },
        ]
      : current.page
        ? [
            { label: `${ICON.recipe} ${current.page.name}`, fg: C.subtext0 as string, bg: C.surface1 as string, canShrink: true },
            { label: `${ICON.web} ${current.title}`, fg: C.appBg, bg: C.accent, bold: true },
          ]
        : null
    const pageNotice = current.page?.isRefreshing ? (
      <Box key="page-refreshing" marginBottom={1}>
        <Text color={C.overlay1}>Refreshing…</Text>
      </Box>
    ) : current.page?.refreshFailure ? (
      <Box key="page-refresh-failed" marginBottom={1}>
        <Text color={C.red}>{`Refresh failed: ${current.page.refreshFailure}`}</Text>
      </Box>
    ) : null
    const isPageNav = Boolean(current.page?.page) && navOrder.length > 0
    const sideKeys = isPageNav ? selectKeys.filter(one => one.key === 'left' || one.key === 'right') : []

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
          {notice && (
            <Box key="live-notice" flexDirection="column" marginBottom={1}>
              <Text color={C.red} bold>{notice.title}</Text>
              <Text color={C.subtext0}>{notice.hint}</Text>
            </Box>
          )}
          {pageNotice}
          {body as never}
      </Box>,
      info,
      [
          ...modeKeys,
          ...(canLive
            ? [{ key: 'live', label: liveHref === current.href ? 'Reader' : 'Live', hotkey: 'v', onPress: () => void toggleLive($, current, viewport) }]
            : []),
          ...(liveFrame && isTyping
            ? [{ key: 'done-typing', label: 'Done typing', hotkey: 'd', menu: 'Done typing: give the keys back to peek', onPress: () => { isTyping = false; $.ui.invalidate('ui.render') } }]
            : []),
          { key: 'next', label: 'Down', hotkey: 'j', onPress: liveFrame ? () => scrollLive(LINE_SCROLL_PX) : isPageNav ? () => void moveSelection($, 'down') : goNext },
          { key: 'prev', label: 'Up', hotkey: 'k', onPress: liveFrame ? () => scrollLive(-LINE_SCROLL_PX) : isPageNav ? () => void moveSelection($, 'up') : goPrev },
          ...sideKeys,
          ...(isPageError ? [] : [{ key: 'star', label: isStarred ? 'Unstar' : 'Star', hotkey: 'f', onPress: liveFrame ? () => void liveKey($, 'f') : () => void setStar($, current.href) }]),
          { key: 'open', label: remote || current.page ? 'Open in browser' : 'Open', hotkey: 'o', onPress: liveFrame ? () => void liveKey($, 'o') : () => void openExternally($, current) },
          ...(remote || current.page
            ? [{ key: 'refresh', label: liveFrame ? 'Reload' : isPageError ? 'Retry' : 'Refresh', hotkey: 'u', onPress: liveFrame ? () => void liveKey($, 'u') : () => void refresh($, current.href) }]
            : []),
          ...(liveFrame || backStack.length || groupBack
            ? [{ key: 'back', label: 'Back', hotkey: 'b', menu: liveFrame ? undefined : groupBack && backStack.length <= groupBack.depth ? `Back to ${groupBack.title}` : 'Back to the previous page', onPress: liveFrame ? () => void liveKey($, 'b') : () => void goBack($) }]
            : []),
          {
            key: 'copy',
            label: remote || current.page ? 'Copy link' : 'Copy path',
            hotkey: 'c',
            onPress: liveFrame ? () => void liveKey($, 'c') : () => void $.ui.copy({ text: current.location }),
          },
          { key: 'close', label: 'Close', hotkey: 'x', onPress: () => void $.ui.close({ id: PANE }) },
          ...pageKeys,
      ].map(one => (isTyping ? { ...one, onPress: () => { isTyping = false; one.onPress() } } : one)),
      { menuOn: { target: current.error || (remote?.failure && !remote.record) || isPageError || isLiveHere ? undefined : current.href } },
    )
  })
}
