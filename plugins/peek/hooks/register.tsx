import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Group, Mode, RemoteComment, SectionLayout } from '../types'
import type { FileEntry, GallerySort, GalleryType, RoleFilter, Scope } from './gallery'
import { C as BASE, MUTED, ICON, META_ICON, mute, speakerColor } from './theme'
import { record } from './capture'
import type { CaptureIo } from './capture'
import { itemKey, parseRef } from './refs'
import { initials, whenLabel } from './slack'
import type { RemoteIo } from './remote'
import { failureText } from './sources'
import { isWebUrl, liveStatusText, wheelPoint } from './live'
import type { Live, LiveIo } from './live'
import { cached, isTimed } from './refresh'
import type { TitleEntry } from './refresh'
import { layoutOf } from './groups'
import type { GroupsIo } from './groups'
import { describeAge, describeSize, plural } from './format'
import { classifyBlocks, filterRole, gridColumns, nextOf, selectEntries } from './gallery'
import { colorFor, iconFor, kindLabel } from './kinds'
import { diagramType, linkify, pathCandidates, plainInline, segmentsOf } from './markdown'
import { IMAGE_ROWS, chunkMarkdown, estimateRows, fitName, imageBox, taskRows, wrapLines } from './measure'
import { fileHref, kindOf, parseHref, resolvePath, shortPath } from './paths'
import { columnWidths, fitCell } from './tabular'
import type { PictureBudget, WidgetCtx } from './pane/types'
import { type ItemLook, lookOf } from './pane/look'
import { HoverLayer, ItemCard, ItemIcon, ItemRow, SectionRule, fitPicture, type IconSlot } from './pane/widgets'
import { bootLinear, clamp, goBack, nav, openExternally, openFromPage, pressLink, refContext, refresh, remoteRef, repoContext, setMenu, show, sourceLine, starKeyOf, switchMode, titlesByKey, trailIcon } from './navigation'
import type { NavIo } from './navigation'
import { TOOLS } from './group-tools'
import { createGroupStore } from './groups-store'
import { fullText, loadFile, loadUrl } from './loaders'
import { docImage, pixels, toPng } from './images'
import { LINE_SCROLL_PX, LIVE_FRAME, WHEEL_SCROLL_PX, leaveLive, liveBox, liveKey, liveSession, onLiveInput, scrollLive, toggleLive } from './live-pane'
import type { LiveInputEvent } from './live-pane'
import { UiGallery } from './ui-gallery'
import { expandedGroups, focusGroupRow, groupCommands, groupHome, groupItemLook, groupPage, groupPageRows, loadGroupRemote, openCardItem, openGroupHref, openGroupItem, openGroupPage, selectGroupRow, setStar, starInGroupsTab, starredFirst, toggleExpanded, toggleGroupStar } from './groups-session'
import type { GroupMenuFor, GroupRows, MenuCommand } from './groups-session'
import { forgetPath, guess, noteCapture, pathExists, remember, scopeEntries, sessionEntries, toHref, withMentions } from './entries'

const C = BASE

const PANE = 'peek'
const view = atom({ plugin: 'peek', key: 'view' } as const, null)
const mentions = atom({ plugin: 'peek', key: 'mentions' } as const, [])
const mode = atom({ plugin: 'peek', key: 'mode' } as const, 'view')
const page = atom({ plugin: 'peek', key: 'page' } as const, 0)
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
  const rows = await groupPageRows(navIoOf($))
  if (rows) {
    if ((direction === 'up' || direction === 'down') && (await selectGroupRow(navIoOf($), rows, rows.selected + (direction === 'down' ? 1 : -1)))) {
      await focusGroupRow(navIoOf($), rows.selected)
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
  if (one?.group) await openGroupPage(navIoOf($), one.group)
  else if (one?.href) await show(navIoOf($), one.href)
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
const GALLERY = 'peek-ui'
const presses = atom({ plugin: 'peek', key: 'galleryPresses' } as const, 0)
const typed = atom({ plugin: 'peek', key: 'galleryText' } as const, '')
const picked = atom({ plugin: 'peek', key: 'galleryPick' } as const, 'round')

let paneColumns = 100
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

const MAX_BLOCK_MEMO = 400
const blockMemo = new Map<string, { chunk: string; rows: number }[]>()

function navIoOf($: EngineInterface): NavIo {
  const io: NavIo = {
    view: { read: () => read($, view), update: change => update($, view, change) },
    mode: { read: () => read($, mode), update: change => update($, mode, change) },
    page: { read: () => read($, page), update: change => update($, page, change) },
    mentions: { read: () => read($, mentions), update: change => update($, mentions, change) },
    openGroup: { read: () => read($, openGroup), update: change => update($, openGroup, change) },
    stars: { read: () => read($, stars), update: change => update($, stars, change) },
    cursor: { read: () => read($, cursorAtom), update: change => update($, cursorAtom, change) },
    menuOpen: { read: () => read($, menuOpen), update: change => update($, menuOpen, change) },
    menuFilter: { read: () => read($, menuFilter), update: change => update($, menuFilter, change) },
    now: () => $.clock.now(),
    every: (ms, fn) => $.clock.every(ms, fn),
    cwd: () => $.session.cwd(),
    home: () => $.env.get('HOME'),
    sessionId: () => $.session.id(),
    sessionRoot: () => $.session.root(),
    stat: path => $.fs.stat(path),
    exists: path => $.fs.exists(path),
    run: (argv, init) => $.process.run(argv, init),
    fetch: (url, init) => $.http.fetch(url, init),
    readFile: path => $.fs.read(path),
    readBytes: path => $.fs.read(path, { as: 'bytes' }),
    list: path => $.fs.list(path),
    writeFile: (path, text) => $.fs.write(path, text),
    storeGet: key => $.store.get(key),
    storeSet: (key, value) => $.store.set(key, value),
    invalidate: () => $.ui.invalidate('ui.render'),
    blit: options => $.ui.blit({ requestId: PANE, ...options }),
    copy: options => $.ui.copy(options),
    toast: text => $.ui.toast(text),
    fork: request => $.model.fork(request),
    scroll: options => $.ui.scroll({ in: PANE, ...options }),
    open: options => $.ui.open({ id: PANE, ...options }),
    focus: options => $.ui.focus({ requestId: PANE, ...options }),
    remoteIo: () => remoteIoOf($),
    liveIo: () => liveIoOf($),
    groupsIo: () => groupsIoOf($),
    columns: () => paneColumns,
    selectedNav: () => selectedNav($),
    shownGroups: place => groupStore.shown(groupsIoOf($), place),
    shownGroup: (place, id) => groupStore.shownOne(groupsIoOf($), place, id),
    writeGroup: (place, id, change) => groupStore.write(groupsIoOf($), place, id, change),
    openGroupRemotes: () => groupPage.remotes,
    forgetPath,
    loadFile: (href, path, line) => loadFile(io, href, path, line),
    loadUrl: href => loadUrl(io, href),
  }
  return io
}

function captureIoOf($: EngineInterface): CaptureIo {
  return {
    mcpCall: (server, tool, args) => $.mcp.call(server, tool, args),
    now: () => $.clock.now(),
  }
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

const groupStore = createGroupStore()

const sum = (values: readonly number[]) => values.reduce((total, one) => total + one, 0)

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

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    nav.lastActivity = await $.clock.now()
    const savedTitles = await $.store.get('titles').catch(() => undefined)
    if (savedTitles && typeof savedTitles === 'object' && !Array.isArray(savedTitles)) nav.titles = savedTitles as Record<string, TitleEntry>
    void bootLinear(navIoOf($)).catch(() => undefined)
    const saved = await $.store.get('stars').catch(() => undefined)
    if (Array.isArray(saved)) await update($, stars, () => saved.filter((one): one is string => typeof one === 'string'))
    for (const tool of Object.values(TOOLS)) await $.tool.register(tool.spec).catch(() => undefined)
    void groupHome(navIoOf($)).catch(() => undefined)
    await $.command.register({ name: 'peek-menu', description: 'Open the peek command menu (ctrl+k in the peek pane)' })
    await $.command.register({ name: 'peek-ui', description: 'Show every Claude Code UI element a mod can draw, live' })
    await $.command.register({ name: 'peek', description: 'Peek at a file, folder or URL in the side pane: a path, a description ("the export diagram"), or nothing for the last one' })
    return next(e)
  })

  on('session.append', async ($, e, next) => {
    const stored = await next(e)
    nav.lastActivity = await $.clock.now()
    if (e.message.type !== 'assistant' || e.agentId) return stored
    const { texts, created, touched } = classifyBlocks(e.message.content)
    await remember(navIoOf($), texts, created, touched).catch(() => undefined)
    return stored
  })

  on('command.run', { command: 'peek-menu' }, async $ => {
    await setMenu(navIoOf($), !(await read($, menuOpen)))
    return { text: '' }
  })

  on('ui.focus', { component: 'Pane', requestId: PANE }, async ($, e, next) => {
    const picked = /^item-(\d+)$/.exec(e.element ?? '')
    if (picked && e.origin.kind === 'person') {
      const index = Number(picked[1])
      const rows = await groupPageRows(navIoOf($)).catch(() => null)
      if (rows) await selectGroupRow(navIoOf($), rows, index).catch(() => undefined)
      await update($, cursorAtom, () => index).catch(() => undefined)
      const key = navOrder[index]?.key
      if (key) void $.ui.scroll({ in: PANE, to: { key }, block: 'center' }).catch(() => undefined)
    }
    return next(e)
  })

  on('ui.close', { id: PANE }, async ($, e, next) => {
    if (e.origin.kind === 'person' && (await read($, menuOpen).catch(() => false))) {
      await setMenu(navIoOf($), false).catch(() => undefined)
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
    const Image = 'Image' in elements ? elements.Image : undefined
    const width = Math.max(20, e.props.bodyColumns - 2)
    const count = await read($, presses)
    const text = await read($, typed)
    const border = await read($, picked)
    let png: string | undefined
    if (Image) {
      const image = await toPng(navIoOf($), `${$.plugin.root}/assets/sample.png`, 0).catch(() => undefined)
      png = image ? pixels.get(image.file) : undefined
    }
    return UiGallery(
      {
        ...elements,
        Input: 'Input' in elements ? elements.Input : undefined,
        Select: 'Select' in elements ? elements.Select : undefined,
        Image,
        Raster: 'Raster' in elements ? elements.Raster : undefined,
        Client: 'Client' in elements ? elements.Client : undefined,
      },
      { surface: e.surface, width, count, text, border, png },
      {
        press: () => void update($, presses, n => n + 1),
        reset: () => void update($, presses, () => 0),
        type: value => void update($, typed, () => value),
        pick: value => void update($, picked, () => value),
      },
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
      await show(navIoOf($), last)
      return { text: `Peeking at ${parseHref(last)?.path ?? last}` }
    }
    const href = (await toHref(navIoOf($), arg)) ?? (await guess(navIoOf($), arg))
    if (!href) {
      const latest = (await read($, mentions)).slice(-5).reverse().map(one => one.href)
      const hint = latest.length ? `\nRecent: ${latest.map(one => parseHref(one)?.path ?? one).join(', ')}` : ''
      return { text: `Could not tell which file "${arg}" means.${hint}` }
    }
    await show(navIoOf($), href)
    return { text: `Peeking at ${parseHref(href)?.path ?? href}` }
  })

  on('ui.render', { component: 'AssistantMessage' }, async ($, e, next) => {
    const { Box, Text, Markdown } = $.ui.resolve(e)
    const cwd = await $.session.cwd()
    const home = (await $.env.get('HOME')) ?? ''
    const real = new Map<string, string>()
    for (const raw of pathCandidates(e.props.text)) {
      const abs = resolvePath(raw, cwd, home)
      if (await pathExists(navIoOf($), abs)) real.set(raw, abs)
    }
    const linked = linkify(
      e.props.text,
      (raw, line) => {
        const abs = real.get(raw)
        return abs ? fileHref(abs, line) : null
      },
      refContext(await repoContext(navIoOf($), cwd)),
    )
    const text = linked.length <= 10000 ? linked : e.props.text
    if (text.length > 10000) return next(e)

    const body = <Markdown key="reply" text={text} onLinkPress={link => void show(navIoOf($), link.href)} />
    if (!e.props.isFirstOfReply) return body

    return (
      <Box flexDirection="row">
        <Text>⏺ </Text>
        {body}
      </Box>
    )
  })

  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc; the validator checks this hook
  on('tool.call', { tool: /^mcp__peek__star$/ }, async ($, e) => TOOLS.star.run(navIoOf($), e))

  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc; the validator checks this hook
  on('tool.call', { tool: /^mcp__peek__list_groups$/ }, async ($, e) => TOOLS.list_groups.run(navIoOf($), e))

  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc; the validator checks this hook
  on('tool.call', { tool: /^mcp__peek__read_group$/ }, async ($, e) => TOOLS.read_group.run(navIoOf($), e))

  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc; the validator checks this hook
  on('tool.call', { tool: /^mcp__peek__save_group$/ }, async ($, e) => TOOLS.save_group.run(navIoOf($), e))

  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc; the validator checks this hook
  on('tool.call', { tool: /^mcp__peek__delete_group$/ }, async ($, e) => TOOLS.delete_group.run(navIoOf($), e))

  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc; the validator checks this hook
  on('tool.call', { tool: /^(?:Bash$|WebFetch$|mcp__(?!peek__))/ }, async ($, e, next) => {
    const answer = await next(e)
    await noteCapture(navIoOf($), e as unknown as Record<string, unknown>, answer).catch(() => undefined)
    return answer
  })

  on('ui.message', async ($, e, next) => {
    const input = e.data as { liveInput?: unknown } | null
    if (e.requestId === PANE && input && Array.isArray(input.liveInput)) {
      await onLiveInput(navIoOf($), input.liveInput as LiveInputEvent[]).catch(() => undefined)
      return { props: { width: liveSession.geom?.columns ?? 1, height: liveSession.geom?.rows ?? 1, acked: liveSession.lastInputSeq } }
    }
    const starring = e.data as { star?: unknown } | null
    if (e.requestId === PANE && starring && typeof starring.star === 'string') {
      await setStar(navIoOf($), starring.star).catch(() => undefined)
      return {}
    }
    const data = e.data as { toggle?: unknown } | null
    if (e.requestId === PANE && data && typeof data.toggle === 'string') {
      await pressLink(navIoOf($), data.toggle).catch(() => undefined)
      return {}
    }
    const switching = e.data as { mode?: unknown } | null
    const target = MODES.find(one => one.id === switching?.mode)?.id
    if (e.requestId === PANE && target) {
      await switchMode(navIoOf($), target).catch(() => undefined)
      void $.ui.scroll({ in: PANE, to: 'start' }).catch(() => undefined)
      return {}
    }
    const group = e.data as { openGroup?: unknown; starGroup?: unknown } | null
    if (e.requestId === PANE && group && typeof group.openGroup === 'string') {
      await openGroupPage(navIoOf($), group.openGroup).catch(() => undefined)
      return {}
    }
    if (e.requestId === PANE && group && typeof group.starGroup === 'string') {
      const isGroupsTab = (await read($, mode)) === 'groups' && !(await read($, openGroup))
      await (isGroupsTab ? starInGroupsTab(navIoOf($), group.starGroup) : toggleGroupStar(navIoOf($), group.starGroup)).catch(() => undefined)
      return {}
    }
    const opening = e.data as { open?: unknown; inGroup?: unknown; key?: unknown } | null
    if (e.requestId === PANE && opening && typeof opening.open === 'string' && typeof opening.inGroup === 'string') {
      await openCardItem(navIoOf($), opening.inGroup, String(opening.key ?? ''), opening.open).catch(() => undefined)
      return {}
    }
    if (e.requestId === PANE && opening && typeof opening.open === 'string') {
      const rows = await groupPageRows(navIoOf($)).catch(() => null)
      const at = rows ? rows.hrefs.indexOf(opening.open) : -1
      await (rows && at >= 0 ? openGroupItem(navIoOf($), rows, at) : show(navIoOf($), opening.open)).catch(() => undefined)
      return {}
    }
    return next(e)
  })

  on('ui.scroll', { component: 'Pane', requestId: PANE }, async ($, e, next) => {
    if (liveSession.href && liveSession.geom && liveSession.viewport && e.pointer) {
      const at = wheelPoint(e.pointer, liveSession.geom, liveSession.viewport)
      if (at) {
        scrollLive(e.by * WHEEL_SCROLL_PX, at)
        return {}
      }
    }
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
    const w: WidgetCtx = { Box, Text, Button, Image, Client, C }
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
    if (liveSession.href && (chosen !== 'view' || current?.href !== liveSession.href)) void leaveLive()

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
      onPress: () => void switchMode(navIoOf($), one.id),
    }))

    const filter = await read($, menuFilter)
    const closeMenu = () => void setMenu(navIoOf($), false)
    const commands: MenuCommand[] = [
      ...(current
        ? [
            { id: 'peek', icon: ICON.peek, label: 'Peek: show the open file', hint: 'p', run: () => void update($, mode, () => 'view') },
          ]
        : []),
      { id: 'recent', icon: ICON.recent, label: 'Recent: files by last use', hint: 'r', run: () => void update($, mode, () => 'recent') },
      { id: 'gallery', icon: ICON.gallery, label: 'Gallery: files as cards by type', hint: 'g', run: () => void update($, mode, () => 'gallery') },
      { id: 'groups', icon: ICON.groups, label: 'Groups: files and links the agent bundled', hint: 'e', run: () => void switchMode(navIoOf($), 'groups') },
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
            { id: 'open', icon: '\u{f08e}', label: 'Open in its own app', hint: 'o', run: () => void openExternally(navIoOf($), current) },
            ...(current.remote
              ? [{ id: 'refresh', icon: '\u{f021}', label: 'Refresh this page', hint: 'u', run: () => void refresh(navIoOf($), current.href) }]
              : []),
            ...(e.surface === 'terminal' && Image && current.remote && parseRef(current.href)?.kind === 'web'
              ? [{ id: 'live', icon: '\u{f0ac}', label: liveSession.href === current.href ? 'Reader view: leave the live page' : 'Live view: the real page, clickable', hint: 'v', run: () => void toggleLive(navIoOf($), current, liveSession.viewport ?? { width: 600, height: 400 }) }]
              : []),
            ...(liveSession.href === current.href && liveSession.live?.state().canBack
              ? [{ id: 'live-back', icon: '\u{f060}', label: 'Back in the live page', hint: 'b', run: () => void liveKey(navIoOf($), 'b') }]
              : []),
            { id: 'copy', icon: '\u{f0c5}', label: current.remote ? 'Copy link' : 'Copy path', hint: 'c', run: () => void $.ui.copy({ text: current.location }) },
            { id: 'star', icon: '\u{f51a}', label: 'Star or unstar this file', hint: 'f', run: () => void setStar(navIoOf($), current.href) },
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
            run: () => void show(navIoOf($), one.href),
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
      const groupMenu = isMenuOpen ? await groupCommands(navIoOf($), menuOn).catch(() => []) : []
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
            if (one?.group) return toggleGroupStar(navIoOf($), one.group)
            return one?.href ? setStar(navIoOf($), one.href).then(() => undefined) : undefined
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
        if (id) toggleExpanded(navIoOf($), id)
      }),
    }

    const groupCards = async (groups: readonly Group[], prefix: string, firstIndex: number, selected: number) => {
      const inner = Math.max(8, textWidth - 4)
      const perRow = Math.min(2, gridColumns(inner, CARD_MIN, CARD_GAP))
      const itemWidth = Math.floor((inner - (perRow - 1) * CARD_GAP) / perRow)
      const starKeys = new Set((await read($, stars)).map(starKeyOf))
      const worktreeRoot = (await groupHome(navIoOf($)))?.worktreeRoot
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
          const looks = await Promise.all(shown.map(block => Promise.all(block.items.map(one => groupItemLook(navIoOf($), one, worktreeRoot, known)))))
          for (const one of looks.flat()) if (one.href && !parseHref(one.href) && remoteRef(one.href) && !cached(one.href)) loadGroupRemote(navIoOf($), one.href)
          const open = (look: ItemLook) => void update($, cursorAtom, () => index).then(() => openGroupHref(navIoOf($), group, look.key, look.href))
          let layers = 0
          const layer = (kind: 'rows' | 'cards', height: number, row: ItemLook[]) =>
            HoverLayer(w, `hover-${prefix}-items-${i}-${layers++}`, { kind, width: inner, height, cardWidth: itemWidth, cardHeight: CARD_ROWS, gap: CARD_GAP, starX: kind === 'cards' ? 2 : 0, starY: kind === 'cards' ? 1 : 0, items: row.map(one => ({ href: one.href, isStarred: starKeys.has(one.key), inGroup: group.id, key: one.key })) })
          const iconSlot = (look: ItemLook, n: number): IconSlot => {
            const isStarred = starKeys.has(look.key)
            return {
              isStarred,
              png: look.favicon && Image && !isStarred ? pixels.get(look.favicon) : undefined,
              icon: iconFor(look.kind),
              imageKey: `${prefix}-favicon-${i}-${n}`,
              buttonKey: `${prefix}-it-${i}-${n}`,
              onPress: () => open(look),
              boxes: { image: `${prefix}-fav-${i}-${n}`, button: `${prefix}-icon-${i}-${n}` },
            }
          }
          const itemCard = (look: ItemLook, n: number) =>
            ItemCard(w, look, {
              key: `${prefix}-card-${i}-${n}`,
              width: itemWidth,
              height: CARD_ROWS,
              background: C.appBg,
              clip: true,
              icon: iconSlot(look, n),
              nameKey: `${prefix}-itname-${i}-${n}`,
              nameColor: look.state === 'missing' ? C.overlay0 : C.text,
              meta: look.state === 'ok' ? kindLabel(look.kind).label : look.state,
              metaColor: look.state === 'missing' ? C.red : C.overlay0,
            })
          const line = (look: ItemLook, n: number) => (
            <Box key={`${prefix}-line-${i}-${n}`} height={1} flexDirection="row" width={inner} overflow="hidden" hover={{ backgroundColor: C.surface0 }}>
              {ItemIcon(w, iconSlot(look, n))}
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
          let height = 2 + 1 + (lines.length ? 1 + lines.length : 0) + (canExpand ? 2 : 0) + 1
          const parts = shown.map((block, b) => {
            const blockLooks = looks[b] ?? []
            const rows = Array.from({ length: Math.ceil(blockLooks.length / perRow) }, (_, r) => blockLooks.slice(r * perRow, r * perRow + perRow))
            const body = !blockLooks.length
              ? [<Text key={`${prefix}-empty-${i}-${b}`} color={C.overlay0}>empty</Text>]
              : block.layout === 'list'
                ? [
                    <Box key={`${prefix}-lines-${i}-${b}`} flexDirection="column" width={inner}>
                      {blockLooks.map((look, j) => line(look, block.first + j))}
                      {layer('rows', blockLooks.length, blockLooks)}
                    </Box>,
                  ]
                : rows.map((row, r) => (
                    <Box key={`${prefix}-irow-${i}-${b}-${r}`} flexDirection="row" columnGap={CARD_GAP} marginTop={r ? 1 : 0}>
                      {row.map((look, c) => itemCard(look, block.first + r * perRow + c))}
                      {layer('cards', CARD_ROWS, row)}
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
                <Box flexShrink={0}>
                  <Button
                    key={`item-${index}`}
                    label={group.starred ? '\u{f51a}' : ICON.groups}
                    plain
                    autoFocus={isSelected ? true : undefined}
                    onPress={() => void update($, cursorAtom, () => index).then(() => openGroupPage(navIoOf($), group.id))}
                  />
                </Box>
                <Box key={`group-name-${index}`} flexGrow={1} flexShrink={1} overflow="hidden">
                  <Text color={isSelected ? C.accent : C.text} bold hover={{ color: C.accent }} wrap="truncate-end">{` ${group.title.toUpperCase()}`}</Text>
                </Box>
                <Box flexShrink={0} marginLeft={1}>
                  <Text color={isSelected ? C.overlay1 : C.overlay0}>{`${plural(group.items.length, 'item')} · ${describeAge(group.updatedAt, now)}`}</Text>
                </Box>
                {HoverLayer(w, `hover-${prefix}-${i}`, { kind: 'rows', width: inner, height: 1, starX: 0, starY: 0, items: [{ group: group.id, isStarred: group.starred }] })}
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
              {canExpand && <Box key={`${prefix}-moregap-${i}`} height={1} />}
              {canExpand && (
                <Box key={`${prefix}-morebar-${i}`} width={inner} height={1} backgroundColor={isSelected ? C.surface1 : C.surface0}>
                  <Button
                    key={`${prefix}-more-${i}`}
                    label={`${' '.repeat(Math.floor(barPad / 2))}${barLabel}${' '.repeat(Math.ceil(barPad / 2))}`}
                    plain
                    dimColor
                    hover={{ color: C.accent }}
                    onPress={() => void update($, cursorAtom, () => index).then(() => toggleExpanded(navIoOf($), group.id))}
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
      const home = await groupHome(navIoOf($))
      const io = groupsIoOf($)
      const opened = await read($, openGroup)
      const shown = opened && home ? await groupStore.shownOne(io, home.place, opened.id) : null
      if (opened && !shown && groupPage.goneNotice !== opened.id) {
        groupPage.goneNotice = opened.id
        $.ui.toast('That group was deleted.')
      }
      const project = (home?.worktreeRoot ?? cwd).split('/').filter(Boolean).pop() ?? 'project'
      if (opened && shown) {
        groupPage.goneNotice = ''
        const worktreeRoot = home?.worktreeRoot
        const known = titlesByKey()
        const sectionIds = new Set(shown.sections.map(one => one.id))
        const blocks = [
          { title: '', items: shown.items.filter(one => !one.section || !sectionIds.has(one.section)) },
          ...shown.sections.map(one => ({ title: one.title, items: shown.items.filter(item => item.section === one.id) })),
        ]
        const looks = await Promise.all(blocks.flatMap(block => block.items).map(one => groupItemLook(navIoOf($), one, worktreeRoot, known)))
        const remotes = looks.filter(one => one.href && !parseHref(one.href) && remoteRef(one.href))
        for (const one of remotes) if (!cached(one.href)) loadGroupRemote(navIoOf($), one.href)
        groupPage.remotes = remotes.map(one => one.href).filter(isTimed)
        const keys = looks.map(one => one.key)
        const found = opened.item === null ? 0 : keys.indexOf(opened.item)
        const previous = groupPage.rows?.id === shown.id ? groupPage.rows.selected : 0
        const selected = clamp(found >= 0 ? found : previous, keys.length)
        const refs = blocks.flatMap(block => block.items).map(one => one.ref)
        const rows: GroupRows = { id: shown.id, title: shown.title, keys, hrefs: looks.map(one => one.href), selected }
        groupPage.rows = rows
        navOrder = keys.map((key, index) => ({ href: key, key: `group-row-${index}`, line: index, col: 0 }))
        blockStarts = []
        const starList = await read($, stars)
        const starKeys = new Set(starList.map(starKeyOf))
        const missing = looks.filter(one => one.state === 'missing').length
        const row = (one: ItemLook, index: number) => {
          const isSelected = index === selected
          return ItemRow(w, one, {
            key: `group-row-${index}`,
            width: textWidth,
            isSelected,
            icon: {
              isStarred: starKeys.has(one.key),
              png: one.favicon && Image ? pixels.get(one.favicon) : undefined,
              icon: iconFor(one.kind),
              imageKey: `favicon-${index}`,
              buttonKey: `item-${index}`,
              autoFocus: isSelected ? true : undefined,
              onPress: () => void openGroupItem(navIoOf($), rows, index),
              boxes: {},
            },
            nameKey: `group-item-${index}`,
            nameColor: one.state === 'missing' ? C.overlay0 : isSelected ? C.accent : C.text,
            meta: one.state === 'ok' ? '' : one.state,
            metaColor: one.state === 'missing' ? C.red : C.overlay1,
            metaKey: `group-meta-${index}`,
          })
        }
        let next = 0
        const drawn = blocks.map((block, b) => {
          const first = next
          next += block.items.length
          const blockLooks = looks.slice(first, next)
          const list = blockLooks.length > 0 && (
            <Box key={`group-block-${b}`} flexDirection="column" width={textWidth}>
              {blockLooks.map((one, j) => row(one, first + j))}
              {HoverLayer(w, `hover-group-${b}`, { kind: 'rows', width: textWidth, height: blockLooks.length, starX: 0, starY: 0, items: blockLooks.map(one => ({ href: one.href, isStarred: starKeys.has(one.key) })) })}
            </Box>
          )
          if (b === 0) return list ? <Box key="group-top" flexDirection="column" width={textWidth} marginBottom={1}>{list}</Box> : null
          return (
            <Box key={`group-part-${b}`} flexDirection="column" width={textWidth} marginBottom={1}>
              <Box key={`group-section-${b - 1}`}>{SectionRule(w, block.title.toUpperCase(), `${block.items.length}`, textWidth)}</Box>
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
              onPress: () => void groupPageRows(navIoOf($)).then(now => (now ? openGroupItem(navIoOf($), now, now.selected) : undefined)),
            },
            {
              key: 'star-selected',
              label: 'Star',
              hotkey: 'f',
              menu: 'Star or unstar the selected item',
              onPress: () => void groupPageRows(navIoOf($)).then(now => {
                const href = now?.hrefs[now.selected]
                return href ? setStar(navIoOf($), href).then(() => $.ui.invalidate('ui.render')) : undefined
              }),
            },
            closeKey,
          ],
          { pageBg: C.appBg, menuOn: { target: rows.hrefs[selected] || undefined, group: shown, selectedRef: refs[selected] } },
        )
      }
      groupPage.rows = null
      groupPage.remotes = []
      const groups = home ? starredFirst(await groupStore.shown(io, home.place)) : []
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
            onPress: () => void selectedGroup().then(id => (id ? openGroupPage(navIoOf($), id) : undefined)),
          },
          {
            key: 'star-selected',
            label: 'Star',
            hotkey: 'f',
            menu: 'Star or unstar the selected group',
            onPress: () => void selectedGroup().then(id => (id ? starInGroupsTab(navIoOf($), id) : undefined)),
          },
          expandKey,
          closeKey,
        ],
        { pageBg: C.appBg, menuOn: { group: groups[clamp(selected, groups.length)], starHint: 'f' } },
      )
    }

    if (chosen !== 'view' || !current) {
      const scope = await read($, scopeAtom)
      const role = await read($, roleFilter)
      const starList = await read($, stars)
      const starSet = new Set(starList)
      const raw = scope === 'session' ? await sessionEntries(navIoOf($), list) : scopeEntries(navIoOf($), scope, cwd, now)
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
        look: lookOf(one, scope === 'session' ? shortPath(one.folder, cwd, home) : one.folder),
        isStarred: starSet.has(one.href),
        png: one.favicon && Image ? pixels.get(one.favicon) : undefined,
      })
      const scopeCrumb = crumbs([
        { label: `${SCOPE_ICON[scope]} ${scope}`, fg: C.appBg, bg: C.accent, bold: true },
      ])
      const waiting = <Text color={C.overlay0}>Loading files…</Text>

      const favMentions = starList.map(href => list.find(one => one.href === href) ?? { href, at: 0, count: 0 })
      const favourites = filterRole(withMentions(await sessionEntries(navIoOf($), favMentions), list), role)
      const rest = entries ? entries.filter(one => !starSet.has(one.href)) : null
      const perRow = gridColumns(textWidth, CARD_MIN, CARD_GAP)
      const cardWidth = Math.floor((textWidth - (perRow - 1) * CARD_GAP) / perRow)
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
              const { look, isStarred, png } = looks(one)
              const { where, age } = describe(one)
              return ItemCard(w, look, {
                key: `${prefix}-${r}-${c}`,
                width: cardWidth,
                height: CARD_ROWS,
                background: isSelected ? C.surface0 : C.panelBg,
                clip: false,
                icon: {
                  isStarred,
                  png,
                  icon: iconFor(look.kind),
                  imageKey: `favicon-${index}`,
                  buttonKey: `item-${index}`,
                  autoFocus: isSelected ? true : undefined,
                  onPress: () => void selectAndOpen($, index),
                },
                nameKey: `name-${index}`,
                nameColor: isSelected ? C.accent : C.text,
                meta: `${where}${age} · ${one.status ?? describeSize(one.size)}`,
                metaColor: isSelected ? C.overlay1 : C.overlay0,
              })
            })}
            {HoverLayer(w, `hover-${prefix}-${r}`, { kind: 'cards', width: textWidth, height: CARD_ROWS, cardWidth, cardHeight: CARD_ROWS, gap: CARD_GAP, starX: 2, starY: 1, items: cards.map(one => ({ href: one.href, isStarred: starSet.has(one.href) })) })}
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
            {SectionRule(w, 'FAVOURITES', `${shownFavs.length}`, textWidth)}
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
                {SectionRule(w, group.label, `${group.items.length}`, textWidth)}
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
      cursor = 0
      const starredGroups = await groupHome(navIoOf($))
        .then(found => (found ? groupStore.shown(groupsIoOf($), found.place) : []))
        .then(all => all.filter(one => one.starred))
        .catch(() => [])
      const pinned = starredGroups.slice(0, PINNED_GROUPS)
      const pinnedBlock = await (async () => {
        if (!pinned.length) return null
        cursor += 2
        const { cards: grid, heights } = await groupCards(pinned, 'starred', nav.length, selected)
        pinned.forEach((one, i) => {
          keys.push(`starred-${i}`)
          starts.push(cursor)
          cursor += heights[i] ?? 0
          nav.push({ href: '', group: one.id, key: `starred-${i}`, line: navLine++, col: 0 })
        })
        cursor += 1
        const count = starredGroups.length > pinned.length ? `${pinned.length} of ${starredGroups.length} · e for all` : `${pinned.length}`
        return (
          <Box flexDirection="column" width={textWidth}>
            {SectionRule(w, 'STARRED GROUPS', count, textWidth)}
            <Box height={1} />
            {grid}
          </Box>
        )
      })()
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
              const { look, isStarred, png } = looks(one)
              const { where, age } = describe(one)
              const count = one.mentions > 1 ? `${one.mentions}× · ` : ''
              const meta = `${one.status ? `${one.status} · ` : ''}${where}${count}${age}`
              return ItemRow(w, look, {
                key: `${prefix}-${i}-${j}`,
                width: textWidth,
                isSelected,
                icon: {
                  isStarred,
                  png,
                  icon: iconFor(look.kind),
                  imageKey: `favicon-${index}`,
                  buttonKey: `item-${index}`,
                  autoFocus: isSelected ? true : undefined,
                  onPress: () => void selectAndOpen($, index),
                  boxes: {},
                },
                nameKey: `name-${index}`,
                nameColor: isSelected ? C.accent : C.text,
                meta,
                metaColor: C.overlay0,
              })
            })}
            {HoverLayer(w, `hover-${prefix}-${i}`, { kind: 'rows', width: textWidth, height: chunk.length, starX: 0, starY: 0, items: chunk.map(one => ({ href: one.href, isStarred: starSet.has(one.href) })) })}
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
              {SectionRule(w, group.label, `${group.items.length}`, textWidth)}
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
    const pictureRows = Math.max(IMAGE_ROWS, e.props.scroll.bodyRows - PAGE_TOP - FOOTER_ROWS - 6)
    const fullWidth = (width: number, height: number) => imageBox(width, height, textWidth - 2, pictureRows)
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
      nav.topBlockKey = `block-${topBlock}`
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
        drawnParts.push(SectionRule(w, label.toUpperCase(), right, textWidth, key))
        note(1, label)
      }
      const kindColor = (kind: string) => (isMenuOpen ? mute(colorFor(kind)) : colorFor(kind))
      const budget: PictureBudget = { used: 0 }
      const ghRef = record?.kind.startsWith('gh-') ? parseRef(record.address) : null
      const refs = refContext(ghRef?.owner && ghRef.repo ? `${ghRef.owner}/${ghRef.repo}` : undefined)
      const memoBase = `${current.href}|${remote.fetchedAt}|${textWidth}|${refs.teamKeys?.length}|${refs.workspace}`
      const mediaBlock = (index: number, alt: string, url: string, heading: string) => {
        const key = `media-${index}`
        const one = record?.media?.[url]
        const picture = remote.pictures?.[url]
        const loadedPng = picture && pixels.get(picture.file)
        const png = fitPicture(budget, loadedPng)
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
                !one?.play && <Markdown dimColor={isMenuOpen} key={`${key}-link`} text={`[open image](${url})`} onLinkPress={link => void pressLink(navIoOf($), link.href)} />
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
        if (!record?.media && !text.includes('```peek-diagram')) return markdownChunks(key, text, heading, indent)
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
          if (found && record?.media?.[found[2] ?? '']) {
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
              <Markdown dimColor={isMenuOpen} key={`${key}-md-${i}`} text={chunk} onLinkPress={link => void pressLink(navIoOf($), link.href)} />
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
            {remote.failureDetail && <Text color={C.overlay1}>{remote.failureDetail}</Text>}
            <Text color={C.subtext0}>{message.hint}</Text>
            <Text color={C.overlay0}>Press o to open it in the browser.</Text>
          </Box>,
        )
        note(remote.failureDetail ? 4 : 3)
      } else {
        const faviconPng = remote.favicon && pixels.get(remote.favicon.file)
        const favicon = fitPicture(budget, faviconPng)
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
        const preview = fitPicture(budget, previewPng)
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
                        <Button key={`list-item-${li}-${i}`} label={fitName(item.title, Math.max(8, textWidth - meta.length - 2))} plain onPress={() => void openFromPage(navIoOf($), item.href)} />
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
            const png = Image ? fitPicture(budget, loaded) : undefined
            if (png && picture && Image) {
              const box = imageBox(picture.width, picture.height, width, pictureRows)
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
          const face = Image ? fitPicture(budget, avatarPng) : undefined
          const when = whenLabel(one.at, now)
          const bodyParts: unknown[] = []
          let bodyRows = 0
          let pending: string[] = []
          const flush = () => {
            const chunk = pending.join('\n')
            pending = []
            if (!chunk.trim()) return
            bodyParts.push(<Markdown dimColor={isMenuOpen} key={`${key}-md-${bodyParts.length}`} text={chunk} onLinkPress={link => void pressLink(navIoOf($), link.href)} />)
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
            const png = Image ? fitPicture(budget, loaded) : undefined
            if (!png || !picture || !Image) {
              pending.push(`[${alt || 'open image'}](${url})`)
              continue
            }
            flush()
            const box = imageBox(picture.width, picture.height, width, pictureRows)
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
              <Markdown dimColor={isMenuOpen} key={`body-${index}-${chunkIndex}`} text={chunk} onLinkPress={link => void pressLink(navIoOf($), link.href)} />,
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
                const toggle = () => void pressLink(navIoOf($), `${item.href}#task-${item.line}`)
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
                  onLinkPress={link => void pressLink(navIoOf($), link.href)}
                />
              </Box>
            </Box>,
          )
          note(estimateRows(part.text, textWidth - 3))
          continue
        }
        const picture = await docImage(navIoOf($), part.src, path)
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
                onLinkPress={link => void pressLink(navIoOf($), link.href)}
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
    const liveState = liveSession.live?.state()
    const canLive = e.surface === 'terminal' && Boolean(Image) && current.remote !== undefined && parseRef(current.href)?.kind === 'web'
    const liveRows = Math.max(4, e.props.scroll.bodyRows - PAGE_TOP - FOOTER_ROWS - 2)
    const viewport = liveBox(textWidth, liveRows)
    const isLiveHere = canLive && liveSession.href === current.href && liveState !== undefined && liveState.phase !== 'off'
    const liveFrame = isLiveHere ? liveState.frame : undefined
    if (liveFrame && Image) {
      liveSession.isFrameDrawn = true
      if (liveSession.viewport && (liveSession.viewport.width !== viewport.width || liveSession.viewport.height !== viewport.height)) {
        liveSession.viewport = viewport
        void liveSession.live?.command('resize', viewport)
      }
      liveSession.geom = { left: Math.floor((e.props.bodyColumns - pageWidth) / 2) + (isNarrow ? 0 : 2), top: HEADER_ROWS + 1 - offset, columns: textWidth, rows: liveRows }
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
              <Client key="live-input" module="./live-input.tsx" props={{ width: textWidth, height: liveRows, acked: liveSession.lastInputSeq }} width={textWidth} height={liveRows} />
            </Box>
          )}
        </Box>
      )
      position = ''
    }
    const liveStatus = isLiveHere ? liveStatusText(liveState, current.location) : ''
    const notice = liveSession.notice?.href === current.href ? failureText(liveSession.notice.kind) : null
    const goNext = jumps.next
    const goPrev = jumps.prev
    const starTarget = (liveFrame && liveState?.url) || current.href
    const isStarred = (await read($, stars)).some(one => starKeyOf(one) === itemKey(starTarget))
    const remote = current.remote
    const source = remote?.record ? sourceLine(remote, now) : ''
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
          {notice && (
            <Box key="live-notice" flexDirection="column" marginBottom={1}>
              <Text color={C.red} bold>{notice.title}</Text>
              <Text color={C.subtext0}>{notice.hint}</Text>
            </Box>
          )}
          {body as never}
      </Box>,
      info,
      [
          ...modeKeys,
          ...(canLive
            ? [{ key: 'live', label: liveSession.href === current.href ? 'Reader' : 'Live', hotkey: 'v', onPress: () => void toggleLive(navIoOf($), current, viewport) }]
            : []),
          ...(liveFrame && liveSession.isTyping
            ? [{ key: 'done-typing', label: 'Done typing', hotkey: 'd', menu: 'Done typing: give the keys back to peek', onPress: () => { liveSession.isTyping = false; $.ui.invalidate('ui.render') } }]
            : []),
          { key: 'next', label: 'Down', hotkey: 'j', onPress: liveFrame ? () => scrollLive(LINE_SCROLL_PX) : goNext },
          { key: 'prev', label: 'Up', hotkey: 'k', onPress: liveFrame ? () => scrollLive(-LINE_SCROLL_PX) : goPrev },
          { key: 'star', label: isStarred ? 'Unstar' : 'Star', hotkey: 'f', onPress: liveFrame ? () => void liveKey(navIoOf($), 'f') : () => void setStar(navIoOf($), current.href) },
          { key: 'open', label: remote ? 'Open in browser' : 'Open', hotkey: 'o', onPress: liveFrame ? () => void liveKey(navIoOf($), 'o') : () => void openExternally(navIoOf($), current) },
          ...(remote ? [{ key: 'refresh', label: liveFrame ? 'Reload' : 'Refresh', hotkey: 'u', onPress: liveFrame ? () => void liveKey(navIoOf($), 'u') : () => void refresh(navIoOf($), current.href) }] : []),
          ...(liveFrame || nav.backStack.length || nav.groupBack
            ? [{ key: 'back', label: 'Back', hotkey: 'b', menu: liveFrame ? undefined : nav.groupBack && nav.backStack.length <= nav.groupBack.depth ? `Back to ${nav.groupBack.title}` : 'Back to the previous page', onPress: liveFrame ? () => void liveKey(navIoOf($), 'b') : () => void goBack(navIoOf($)) }]
            : []),
          {
            key: 'copy',
            label: remote ? 'Copy link' : 'Copy path',
            hotkey: 'c',
            onPress: liveFrame ? () => void liveKey(navIoOf($), 'c') : () => void $.ui.copy({ text: current.location }),
          },
          { key: 'close', label: 'Close', hotkey: 'x', onPress: () => void $.ui.close({ id: PANE }) },
      ].map(one => (liveSession.isTyping ? { ...one, onPress: () => { liveSession.isTyping = false; one.onPress() } } : one)),
      { menuOn: { target: current.error || (remote?.failure && !remote.record) || isLiveHere ? undefined : current.href } },
    )
  })
}
