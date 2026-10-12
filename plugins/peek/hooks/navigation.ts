import type { EngineInterface, HttpInit, HttpResponse, PluginState, ProcessRunInit, ProcessRunResult } from 'claude-code'

import type { Group, GroupResult, Loaded, Mode, RemoteRecord, View } from '../types'
import { capturedLinearContext } from './capture'
import { describeAge } from './format'
import { noteMentions } from './gallery'
import type { GroupPlace, GroupWrite, GroupsIo } from './groups'
import { bootstrapLinear } from './linear'
import type { LinearBootstrap } from './linear'
import { markdownPage, mermaidFences, mermaidPage, toggleTaskLine } from './markdown'
import { kindOf, parseHref } from './paths'
import { IDLE_MS, cached, isCurrent, isTimed, refreshItem, tick, titleOf, withTitle } from './refresh'
import type { CacheEntry, TitleEntry } from './refresh'
import { familyOf, itemKey, parseRef } from './refs'
import type { Ref, RefContext } from './refs'
import { loadItem } from './remote'
import type { RemoteIo } from './remote'
import { ICON } from './theme'
import { remoteFileOf } from './web'

type PaneState = PluginState['peek']
type Ui = EngineInterface['ui']
type Fs = EngineInterface['fs']
type Model = EngineInterface['model']
type Without<T, K extends PropertyKey> = T extends unknown ? Omit<T, K> : never
type Picture = { file: string; width: number; height: number }

export type Cell<T> = { read: () => Promise<T>; update: (change: (value: T) => T) => Promise<T> }

export type NavIo = {
  view: Cell<PaneState['view']>
  mode: Cell<PaneState['mode']>
  page: Cell<PaneState['page']>
  mentions: Cell<PaneState['mentions']>
  openGroup: Cell<PaneState['openGroup']>
  stars: Cell<PaneState['stars']>
  cursor: Cell<PaneState['cursor']>
  menuOpen: Cell<PaneState['menuOpen']>
  menuFilter: Cell<PaneState['menuFilter']>
  now: () => Promise<number>
  every: (ms: number, fn: () => void) => void
  cwd: () => Promise<string>
  home: () => Promise<string | undefined>
  sessionId: () => Promise<string>
  sessionRoot: () => Promise<string>
  stat: (path: string) => ReturnType<Fs['stat']>
  exists: (path: string) => Promise<boolean>
  run: (argv: readonly string[], init?: ProcessRunInit) => Promise<ProcessRunResult>
  fetch: (url: string, init?: HttpInit) => Promise<HttpResponse>
  readFile: (path: string) => Promise<string>
  list: (path: string) => ReturnType<Fs['list']>
  writeFile: (path: string, text: string) => Promise<unknown>
  storeGet: (key: string) => Promise<unknown>
  storeSet: (key: string, value: unknown) => Promise<unknown>
  invalidate: () => void
  toast: (text: string) => void
  fork: (request: Parameters<Model['fork']>[0]) => ReturnType<Model['fork']>
  scroll: (options: Without<Parameters<Ui['scroll']>[0], 'in'>) => ReturnType<Ui['scroll']>
  open: (options: Without<Parameters<Ui['open']>[0], 'id'>) => ReturnType<Ui['open']>
  focus: (options: Without<Parameters<Ui['focus']>[0], 'requestId'>) => ReturnType<Ui['focus']>
  remoteIo: () => RemoteIo
  groupsIo: () => GroupsIo
  columns: () => number
  selectedNav: () => Promise<{ href: string } | undefined>
  shownGroups: (place: GroupPlace) => Promise<readonly Group[]>
  shownGroup: (place: GroupPlace, id: string) => Promise<Group | null>
  writeGroup: (place: GroupPlace, id: string, change: (current: Group | null) => GroupResult) => Promise<GroupWrite>
  openGroupRemotes: () => readonly string[]
  forgetPath: (path: string) => void
  loadFile: (href: string, path: string, line?: number) => Promise<View>
  loadUrl: (href: string) => Promise<View>
  withDrawnMermaid: (markdown: string) => Promise<string>
  drawMermaid: (source: string) => Promise<string | null>
  toPng: (abs: string, mtimeMs: number, edges?: readonly number[]) => Promise<Picture>
  remotePicture: (file: string | undefined) => Promise<Picture | undefined>
  mediaPictures: (media: RemoteRecord['media']) => Promise<Record<string, Picture> | undefined>
  avatarPictures: (avatars: RemoteRecord['avatars']) => Promise<Record<string, Picture> | undefined>
}

export const SCRATCH = '/tmp/claude-peek'
const LINEAR_BOOT_TTL_MS = 24 * 3600_000
// viewOf runs on every refresh tick and redraw; each fence costs one mermaid-ascii process.
const drawnRecords = new Map<string, RemoteRecord>()
const MAX_DRAWN_RECORDS = 50
const repoContexts = new Map<string, string | null>()
let isTicking = false
let linearBoot: Omit<LinearBootstrap, 'ok'> | null = null
let showGeneration = 0

export const clamp = (at: number, length: number) => Math.max(0, Math.min(length - 1, at))

export const nav = {
  lastActivity: 0,
  titles: {} as Record<string, TitleEntry>,
  topBlockKey: 'block-0',
  backStack: [] as { view: View; key: string }[],
  groupBack: null as { id: string; title: string; depth: number } | null,
}

export async function repoContext(io: NavIo, cwd: string): Promise<string | undefined> {
  if (!repoContexts.has(cwd)) {
    let found: string | null = null
    for (const remote of ['upstream', 'origin']) {
      const ran = await io.run(['git', '-C', cwd, 'remote', 'get-url', remote]).catch(() => null)
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

export function refContext(repo?: string): RefContext {
  const captured = capturedLinearContext()
  return {
    teamKeys: [...new Set([...(linearBoot?.teamKeys ?? []), ...captured.teamKeys])],
    workspace: linearBoot?.workspace ?? captured.workspace,
    repo,
  }
}

export async function sessionRefContext(io: NavIo): Promise<RefContext> {
  return refContext(await repoContext(io, await io.cwd()))
}

export async function bootLinear(io: NavIo) {
  const now = await io.now()
  const saved = (await io.storeGet('linear').catch(() => undefined)) as typeof linearBoot | undefined
  if (saved && typeof saved.workspace === 'string' && Array.isArray(saved.teamKeys) && now - saved.fetchedAt < LINEAR_BOOT_TTL_MS) {
    linearBoot = saved
    return
  }
  const boot = await bootstrapLinear(io.remoteIo(), now)
  if (!boot.ok) return
  linearBoot = { workspace: boot.workspace, teamKeys: boot.teamKeys, fetchedAt: boot.fetchedAt }
  await io.storeSet('linear', linearBoot).catch(() => undefined)
  io.invalidate()
}

export async function openFromPage(io: NavIo, href: string) {
  const current = await io.view.read()
  if (current && (await io.mode.read()) === 'view') {
    nav.backStack.push({ view: current, key: nav.topBlockKey })
    if (nav.backStack.length > 20) nav.backStack.shift()
  }
  await show(io, href, true)
}

// b walks the page history first, so a link followed inside a group item comes back before the group does.
export async function goBack(io: NavIo) {
  if (nav.groupBack && nav.backStack.length <= nav.groupBack.depth) {
    const target = nav.groupBack
    nav.groupBack = null
    await io.openGroup.update(opened => (opened?.id === target.id ? opened : { id: target.id, item: null }))
    await io.mode.update(() => 'groups')
    await io.page.update(() => 0)
    return
  }
  const last = nav.backStack.pop()
  if (!last) return
  await io.view.update(() => last.view)
  await io.mode.update(() => 'view')
  void io.scroll({ to: { key: last.key }, block: 'start' }).catch(() => undefined)
}

export function remoteLoader(io: NavIo, canReplay: boolean) {
  return async (address: string): Promise<Loaded> => {
    const ref = parseRef(address)
    if (!ref) return { ok: false, failure: 'query-bug' }
    return loadItem(io.remoteIo(), ref, await io.now(), { canReplay })
  }
}

export async function noteTitle(io: NavIo, entry: CacheEntry) {
  if (!entry.record) return
  const next = titleOf(entry.record)
  const { updatedAt: _, ...known } = nav.titles[entry.record.address] ?? { updatedAt: 0 }
  if (JSON.stringify(known) === JSON.stringify(next)) return
  nav.titles = withTitle(nav.titles, entry.record.address, next, await io.now())
  await io.storeSet('titles', nav.titles).catch(() => undefined)
}

export const titlesByKey = () => new Map(Object.entries(nav.titles).map(([address, entry]) => [itemKey(address), entry]))

export function startTicking(io: NavIo) {
  if (isTicking) return
  isTicking = true
  io.every(15_000, () => void tickRemote(io).catch(() => undefined))
}

export async function loadRemote(io: NavIo, ref: Ref, canReplay = false): Promise<View> {
  startTicking(io)
  const known = cached(ref.address)
  if (known?.state === 'frozen') return viewOf(io, ref, known)
  const entry = await refreshItem(ref.address, remoteLoader(io, canReplay), await io.now())
  await noteTitle(io, entry)
  return viewOf(io, ref, entry)
}

async function withRecordDiagrams(io: NavIo, record: RemoteRecord, fetchedAt = 0): Promise<RemoteRecord> {
  const texts = [record.body ?? '', ...(record.comments?.shown ?? []).map(one => one.body)]
  if (!texts.some(text => mermaidFences(text).length)) return record
  const key = `${record.address}|${fetchedAt}|${io.columns()}`
  const known = drawnRecords.get(key)
  if (known) return known
  const [body, ...comments] = await Promise.all(texts.map(text => io.withDrawnMermaid(text)))
  const drawn: RemoteRecord = {
    ...record,
    ...(record.body !== undefined ? { body } : {}),
    ...(record.comments ? { comments: { ...record.comments, shown: record.comments.shown.map((one, i) => ({ ...one, body: comments[i] ?? one.body })) } } : {}),
  }
  if (drawnRecords.size > MAX_DRAWN_RECORDS) drawnRecords.clear()
  drawnRecords.set(key, drawn)
  return drawn
}

async function viewOf(io: NavIo, ref: Ref, entry: CacheEntry): Promise<View> {
  const base: View = { href: ref.address, title: ref.key ?? ref.address.replace(/^https:\/\//, ''), location: ref.address, kind: ref.kind }
  const record = entry.record && (await withRecordDiagrams(io, entry.record, entry.fetchedAt))
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
      favicon: await io.remotePicture(record.favicon),
      preview: await io.remotePicture(record.og?.image),
      pictures: await io.mediaPictures(record.media),
      avatars: await io.avatarPictures(record.avatars),
    },
  }
}

export function remoteRef(href: string, context: RefContext = {}): Ref | null {
  if (parseHref(href)) return null
  const ref = parseRef(href, context)
  if (!ref) return null
  return ref.kind === 'web' && remoteFileOf(ref.address) ? null : ref
}

export const starKeyOf = (raw: string) => itemKey(remoteRef(raw)?.address ?? raw)

export async function show(io: NavIo, raw: string, isFromGroupChain = false) {
  if (!isFromGroupChain) nav.groupBack = null
  const generation = ++showGeneration
  const ref = remoteRef(raw)
  const href = ref?.address ?? raw
  const file = parseHref(href)
  const loading: View = { href, title: 'Loading…', location: file?.path ?? href }
  await io.view.update(() => loading)
  const at = await io.now()
  await io.mentions.update(list => noteMentions(list, [href], at))
  await io.page.update(() => 0)
  await io.mode.update(() => 'view')
  void io.scroll({ to: 'start' }).catch(() => undefined)
  void io.open({ title: 'Peek' })
  let next: View
  try {
    next = file ? await io.loadFile(href, file.path, file.line) : ref ? await loadRemote(io, ref) : await io.loadUrl(href)
  } catch (error) {
    next = { ...loading, title: 'Could not open', error: error instanceof Error ? error.message : String(error) }
  }
  if (generation !== showGeneration) return
  await io.view.update(() => next)
  void io.open({ title: next.title })
}

export async function openExternally(io: NavIo, current: View) {
  const file = parseHref(current.href)
  if (!file) {
    await io.run(['open', current.href])
    return
  }
  const kind = kindOf(file.path)
  if (kind !== 'markdown' && kind !== 'mermaid') {
    await io.run(['open', file.path])
    return
  }
  const source = await io.readFile(file.path)
  const page = kind === 'mermaid' ? mermaidPage(current.title, source) : markdownPage(current.title, source)
  const out = `${SCRATCH}/${current.title.replace(/[^\w.-]/g, '_')}.html`
  await io.writeFile(out, page)
  await io.run(['open', out])
}

// e on an open group page goes back to the group list; from any other screen it keeps the open group.
export async function switchMode(io: NavIo, to: Mode) {
  if (to === 'groups' && (await io.mode.read()) === 'groups') await io.openGroup.update(() => null)
  await io.mode.update(() => to)
  await io.page.update(() => 0)
}

export async function refresh(io: NavIo, href: string) {
  const ref = remoteRef(href)
  if (ref) {
    const entry = await refreshItem(ref.address, remoteLoader(io, true), await io.now())
    await noteTitle(io, entry)
    await redrawIfCurrent(io, entry.address)
    return
  }
  const file = parseHref(href)
  if (!file) return
  io.forgetPath(file.path)
  const next = await io.loadFile(href, file.path, file.line).catch(() => null)
  if (next) await io.view.update(() => next)
}

// The header shortens a crumb by keeping its first two characters as the icon,
// so every trail piece needs one.
export function trailIcon(kind: string, index: number, count: number): string {
  const family = familyOf(kind)
  if (family === 'gh') return index === 0 && count > 1 ? '\u{f09b}' : ICON['gh-repo']
  if (family === 'linear') return index === 0 ? '\u{f0c0}' : ICON['linear-project']
  if (family === 'slack') return index === 0 ? ICON['slack-thread'] : '\u{f086}'
  return '\u{f0ac}'
}

const TIER_NAMES: Record<string, string> = { 'gh-cli': 'via gh', 'web-cli': 'via curl', 'web-api': 'via web fetch', 'linear-api': 'via Linear API', 'slack-mcp': 'via Slack MCP', 'slack-cli': 'via slack' }

export function sourceLine(remote: NonNullable<View['remote']>, now: number): string {
  const { tier, fetchedAt, staleSince } = remote
  const family = familyOf(remote.record?.kind ?? 'web')
  const name = tier === 'session' ? 'from this session' : (TIER_NAMES[`${family}-${tier}`] ?? `via ${tier ?? '?'}`)
  const seconds = fetchedAt === undefined ? 0 : Math.max(0, Math.round((now - fetchedAt) / 1000))
  const age = fetchedAt === undefined ? '' : seconds < 60 ? `${seconds}s ago` : describeAge(fetchedAt, now)
  const stale = staleSince === undefined ? '' : ` · stale since ${describeAge(staleSince, now)}`
  return `${name}${age ? ` · ${age}` : ''}${stale}`
}

async function redrawIfCurrent(io: NavIo, address: string) {
  const current = await io.view.read()
  const ref = current && remoteRef(current.href)
  const entry = cached(address)
  if (!current || !ref || !entry || !isCurrent(current.href, address)) return
  const next = await viewOf(io, ref, entry)
  if ((await io.view.read())?.href === current.href) await io.view.update(() => next)
}

async function tickRemote(io: NavIo) {
  if ((await io.now()) - nav.lastActivity >= IDLE_MS) return
  const current = await io.view.read()
  const onScreen = current?.remote && (await io.mode.read()) === 'view' ? current.href : undefined
  const hrefs = [...(await io.mentions.read()).map(one => one.href), ...(await io.stars.read()), ...((await io.openGroup.read()) ? io.openGroupRemotes() : [])]
  const background = [...new Set(hrefs)].filter(href => remoteRef(href) && isTimed(href))
  const changed = await tick({ onScreen, background, now: await io.now(), lastActivity: nav.lastActivity, load: remoteLoader(io, true) })
  for (const address of changed) {
    const entry = cached(address)
    if (entry) await noteTitle(io, entry)
    await redrawIfCurrent(io, address)
  }
}

export async function pressLink(io: NavIo, href: string) {
  const task = /#task-(\d+)$/.exec(href)
  const current = await io.view.read()
  const file = parseHref(href)
  if (task && file && current && parseHref(current.href)?.path === file.path) {
    const source = await io.readFile(file.path)
    const toggled = toggleTaskLine(source, Number(task[1]))
    if (toggled !== null) {
      await io.writeFile(file.path, toggled)
      await refresh(io, current.href)
      return
    }
  }
  await openFromPage(io, href)
}

// Esc closes a pane only while it is opened with closeOnEscape, so the menu
// turns that on and the ui.close hook turns the close into closing the menu.
export async function setMenu(io: NavIo, isOpen: boolean) {
  await io.menuFilter.update(() => '')
  await io.menuOpen.update(() => isOpen)
  await io.open(isOpen ? { title: 'Peek', focus: true, closeOnEscape: true } : { title: 'Peek' })
}
