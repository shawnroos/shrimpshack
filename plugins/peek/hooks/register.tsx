import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Mode } from '../types'
import { C as BASE, MUTED } from './theme'
import type { Ports } from './ports'
import { wheelPoint } from './live'
import type { LiveIo } from './live'
import { hydrateTitles } from './refresh'
import type { TitleEntry } from './refresh'
import type { GroupsIo } from './groups'
import { classifyBlocks } from './gallery'
import { linkify, pathCandidates } from './markdown'
import { fileHref, parseHref, resolvePath } from './paths'
import type { Direction, DrawContext, NavItem, PaneActions, Screen } from './pane/types'
import { FOOTER_ROWS, HEADER_ROWS, PAGE_TOP, frame as drawFrame, geometryOf } from './pane/chrome'
import { parsePaneMessage } from './pane/messages'
import { menuLists } from './pane/menu'
import { EMPTY_LAYOUT } from './pane/layout'
import type { Layout } from './pane/layout'
import { groupsScreen } from './pane/screens/groups'
import { recentScreen } from './pane/screens/recent'
import { galleryScreen } from './pane/screens/gallery'
import { viewScreen } from './pane/screens/view/index'
import { bootLinear, clamp, nav, pressLink, refContext, repoContext, setMenu, show, switchMode } from './navigation'
import type { NavIo } from './navigation'
import { TOOLS } from './group-tools'
import { createGroupStore } from './groups-store'
import { loadFile, loadUrl } from './loaders'
import { pixels, toPng } from './images'
import { WHEEL_SCROLL_PX, leaveLive, liveSession, onLiveInput, scrollLive } from './live-pane'
import { UiGallery } from './ui-gallery'
import { groupHome, groupPage, openCardItem, openGroupHref, openGroupPage, setStar, starInGroupsTab, toggleGroupStar } from './groups-session'
import { forgetPath, guess, noteCapture, pathExists, remember, toHref } from './entries'

const PANE = 'peek'
const view = atom({ plugin: 'peek', key: 'view' } as const, null)
const mentions = atom({ plugin: 'peek', key: 'mentions' } as const, [])
const mode = atom({ plugin: 'peek', key: 'mode' } as const, 'view')
const page = atom({ plugin: 'peek', key: 'page' } as const, 0)
const menuOpen = atom({ plugin: 'peek', key: 'menuOpen' } as const, false)
const menuFilter = atom({ plugin: 'peek', key: 'menuFilter' } as const, '')
const openGroup = atom({ plugin: 'peek', key: 'openGroup' } as const, null)
const scopeAtom = atom({ plugin: 'peek', key: 'scope' } as const, 'session')
const galleryType = atom({ plugin: 'peek', key: 'galleryType' } as const, 'all')
const gallerySort = atom({ plugin: 'peek', key: 'gallerySort' } as const, 'recent')
const galleryFilter = atom({ plugin: 'peek', key: 'galleryFilter' } as const, '')
const roleFilter = atom({ plugin: 'peek', key: 'roleFilter' } as const, 'all')
const stars = atom({ plugin: 'peek', key: 'stars' } as const, [])
const cursorAtom = atom({ plugin: 'peek', key: 'cursor' } as const, 0)
// Module state, not UI state, so the draw may write them: the last drawn screen's layout and the content height
// the last scroll reported.
let paneLayout: Layout = EMPTY_LAYOUT
let contentRows = 0

// Up and down keep the column, so a card grid moves like a grid.
function stepFrom(at: number, direction: Direction): number {
  const here = paneLayout.nav[at]
  if (!here) return 0
  if (direction === 'left' || direction === 'right') {
    const next = paneLayout.nav[at + (direction === 'left' ? -1 : 1)]
    return next && next.line === here.line ? at + (direction === 'left' ? -1 : 1) : at
  }
  const line = here.line + (direction === 'up' ? -1 : 1)
  let best = -1
  paneLayout.nav.forEach((one, index) => {
    if (one.line === line && (best < 0 || Math.abs(one.col - here.col) < Math.abs((paneLayout.nav[best]?.col ?? 0) - here.col))) best = index
  })
  return best < 0 ? at : best
}

// A group page keeps its selection as the open group's item, falling back to the row it drew selected; every other
// list keeps it in the cursor.
async function selectedIndex($: EngineInterface): Promise<number> {
  const { nav, group } = paneLayout
  if (!group) return clamp(await read($, cursorAtom), nav.length)
  const opened = await read($, openGroup)
  const at = opened?.id === group.id ? nav.findIndex(one => one.groupItem?.key === opened.item) : -1
  return at >= 0 ? at : group.selected
}

// On a group page the item is written first, then the cursor; a page with no row there selects nothing.
async function select($: EngineInterface, index: number): Promise<boolean> {
  const item = paneLayout.nav[index]?.groupItem
  if (paneLayout.group) {
    if (!item) return false
    // Opening from a card sets the item without this, so the row a removed item falls to stays the page's own.
    if (groupPage.drawn?.id === item.group) groupPage.drawn.selected = index
    await update($, openGroup, opened => (opened?.id === item.group ? { ...opened, item: item.key } : opened))
  }
  await update($, cursorAtom, () => index)
  return true
}

async function moveSelection($: EngineInterface, direction: Direction) {
  const landed = stepFrom(await selectedIndex($), direction)
  if (!(await select($, landed))) return
  const key = paneLayout.nav[landed]?.key
  // 'nearest' counts a row under the pinned footer as already showing, so the
  // cursor could walk behind it; centring always leaves it in the clear.
  if (key) await $.ui.scroll({ in: PANE, to: { key }, block: 'center' }).catch(() => undefined)
  await $.ui.focus({ requestId: PANE, key: `item-${landed}` }).catch(() => undefined)
}

async function selectAndOpen($: EngineInterface, index: number) {
  await select($, index)
  await openNav($, paneLayout.nav[index])
}

async function selectedNav($: EngineInterface): Promise<NavItem | undefined> {
  return paneLayout.nav[await selectedIndex($)]
}

async function openNav($: EngineInterface, one: NavItem | undefined) {
  if (one?.groupItem) await openGroupHref(navIoOf($), { id: one.groupItem.group, title: one.groupItem.title }, one.groupItem.key, one.href)
  else if (one?.group) await openGroupPage(navIoOf($), one.group)
  else if (one?.href) await show(navIoOf($), one.href)
}

const GALLERY = 'peek-ui'
const presses = atom({ plugin: 'peek', key: 'galleryPresses' } as const, 0)
const typed = atom({ plugin: 'peek', key: 'galleryText' } as const, '')
const picked = atom({ plugin: 'peek', key: 'galleryPick' } as const, 'round')

let paneColumns = 100

function portsOf($: EngineInterface): Ports {
  return {
    sessionId: () => $.session.id(),
    sessionRoot: () => $.session.root(),
    cwd: () => $.session.cwd(),
    home: () => $.env.get('HOME'),
    linearKeyEnv: () => $.env.get('LINEAR_API_KEY'),
    run: (argv, init) => $.process.run(argv, init),
    spawn: argv => $.process.spawn({ argv }),
    fetch: (url, init) => $.http.fetch(url, init),
    read: path => $.fs.read(path),
    readBytes: path => $.fs.read(path, { as: 'bytes' }),
    write: (path, text) => $.fs.write(path, text),
    list: path => $.fs.list(path),
    stat: path => $.fs.stat(path),
    exists: path => $.fs.exists(path),
    now: () => $.clock.now(),
    sleep: ms => $.clock.sleep(ms),
    every: (ms, fn) => $.clock.every(ms, fn),
    after: (ms, fn) => $.clock.after(ms, fn),
    mcpCall: (server, tool, args) => $.mcp.call(server, tool, args),
  }
}

function navIoOf($: EngineInterface): NavIo {
  const ports = portsOf($)
  const io: NavIo = {
    ...ports,
    view: { read: () => read($, view), update: change => update($, view, change) },
    mode: { read: () => read($, mode), update: change => update($, mode, change) },
    page: { read: () => read($, page), update: change => update($, page, change) },
    mentions: { read: () => read($, mentions), update: change => update($, mentions, change) },
    openGroup: { read: () => read($, openGroup), update: change => update($, openGroup, change) },
    stars: { read: () => read($, stars), update: change => update($, stars, change) },
    cursor: { read: () => read($, cursorAtom), update: change => update($, cursorAtom, change) },
    menuOpen: { read: () => read($, menuOpen), update: change => update($, menuOpen, change) },
    menuFilter: { read: () => read($, menuFilter), update: change => update($, menuFilter, change) },
    readFile: ports.read,
    writeFile: ports.write,
    storeGet: key => $.store.get(key),
    storeSet: (key, value) => $.store.set(key, value),
    invalidate: () => $.ui.invalidate('ui.render'),
    blit: options => $.ui.blit({ requestId: PANE, ...options }),
    copy: options => $.ui.copy(options),
    toast: text => $.ui.toast(text),
    fork: request => $.model.fork(request),
    scroll: options => $.ui.scroll({ in: PANE, ...options }),
    open: options => $.ui.open({ id: PANE, ...options }),
    remoteIo: () => ports,
    liveIo: () => liveIoOf($, ports),
    groupsIo: () => groupsIoOf(ports),
    columns: () => paneColumns,
    selectedNav: () => selectedNav($),
    shownGroups: place => groupStore.shown(groupsIoOf(ports), place),
    shownGroup: (place, id) => groupStore.shownOne(groupsIoOf(ports), place, id),
    writeGroup: (place, id, change) => groupStore.write(groupsIoOf(ports), place, id, change),
    openGroupRemotes: () => groupPage.remotes,
    forgetPath,
    loadFile: (href, path, line) => loadFile(io, href, path, line),
    loadUrl: href => loadUrl(io, href),
  }
  return io
}

function groupsIoOf(ports: Ports): GroupsIo {
  return {
    read: ports.read,
    write: ports.write,
    list: ports.list,
    stat: path => ports.stat(path).catch(() => null),
    run: argv => ports.run(argv),
    now: ports.now,
    sleep: ports.sleep,
  }
}

const groupStore = createGroupStore()

// The Peek tab with nothing open shows Recent.
const SCREENS: Record<Mode, (ctx: DrawContext, actions: PaneActions) => Promise<Screen>> = {
  view: (ctx, actions) => (ctx.current ? viewScreen(ctx, actions, ctx.current) : recentScreen(ctx, actions)),
  recent: recentScreen,
  gallery: galleryScreen,
  groups: groupsScreen,
}

function paneActionsOf($: EngineInterface): PaneActions {
  return {
    io: navIoOf($),
    scope: { read: () => read($, scopeAtom), update: change => update($, scopeAtom, change) },
    roleFilter: { read: () => read($, roleFilter), update: change => update($, roleFilter, change) },
    galleryType: { read: () => read($, galleryType), update: change => update($, galleryType, change) },
    gallerySort: { read: () => read($, gallerySort), update: change => update($, gallerySort, change) },
    galleryFilter: { read: () => read($, galleryFilter), update: change => update($, galleryFilter, change) },
    moveSelection: direction => moveSelection($, direction),
    selectAndOpen: index => selectAndOpen($, index),
    selectedIndex: () => selectedIndex($),
    selectedNav: () => selectedNav($),
    openNav: one => openNav($, one),
    close: () => $.ui.close({ id: PANE }),
  }
}

function liveIoOf($: EngineInterface, ports: Ports): LiveIo {
  return {
    root: $.plugin.root,
    home: ports.home,
    read: ports.read,
    exists: ports.exists,
    run: ports.run,
    spawn: ports.spawn,
    post: async (socket, path, body) => {
      const init = body === undefined ? {} : { body: JSON.stringify(body), headers: { 'content-type': 'application/json' } }
      const answer = await ports.fetch(`http://peek-web/${path}`, { method: 'POST', socketPath: socket, ...init })
      return answer.ok
    },
    after: ports.after,
    removeDir: async dir => {
      // Only the helper's own mkdtemp directory: a malformed `ready` must never aim rm at anything else.
      if (/\/peek-web\.[A-Za-z0-9]{6}$/.test(dir)) await ports.run(['rm', '-rf', dir])
    },
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    nav.lastActivity = await $.clock.now()
    const savedTitles = await $.store.get('titles').catch(() => undefined)
    if (savedTitles && typeof savedTitles === 'object' && !Array.isArray(savedTitles)) hydrateTitles(savedTitles as Record<string, TitleEntry>)
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
      await select($, index).catch(() => undefined)
      const key = paneLayout.nav[index]?.key
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
    const message = e.requestId === PANE ? parsePaneMessage(e.data) : null
    if (!message) return next(e)
    const io = navIoOf($)
    switch (message.t) {
      case 'liveInput':
        await onLiveInput(io, message.events).catch(() => undefined)
        return { props: { width: liveSession.geom?.columns ?? 1, height: liveSession.geom?.rows ?? 1, acked: liveSession.lastInputSeq } }
      case 'star':
        await setStar(io, message.href).catch(() => undefined)
        return {}
      case 'toggle':
        await pressLink(io, message.href).catch(() => undefined)
        return {}
      case 'mode':
        await switchMode(io, message.mode).catch(() => undefined)
        void $.ui.scroll({ in: PANE, to: 'start' }).catch(() => undefined)
        return {}
      case 'openGroup':
        await openGroupPage(io, message.id).catch(() => undefined)
        return {}
      case 'starGroup': {
        const isGroupsTab = (await read($, mode)) === 'groups' && !(await read($, openGroup))
        await (isGroupsTab ? starInGroupsTab(io, message.id) : toggleGroupStar(io, message.id)).catch(() => undefined)
        return {}
      }
      case 'openInGroup':
        await openCardItem(io, message.group, message.key, message.href).catch(() => undefined)
        return {}
      case 'open': {
        const at = paneLayout.nav.findIndex(one => one.groupItem && one.href === message.href)
        await (at >= 0 ? selectAndOpen($, at) : show(io, message.href)).catch(() => undefined)
        return {}
      }
    }
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
    const current = await read($, view)
    const chosen = await read($, mode)
    const at = await read($, page)
    const list = await read($, mentions)
    const now = await $.clock.now()
    const cwd = await $.session.cwd()
    const home = (await $.env.get('HOME')) ?? ''
    const geom = geometryOf(e.props.bodyColumns)
    paneColumns = geom.columns
    if (liveSession.href && (chosen !== 'view' || current?.href !== liveSession.href)) void leaveLive()
    const filter = await read($, menuFilter)
    const realBody = Math.max(1, contentRows - PAGE_TOP - FOOTER_ROWS - 1)
    const ctx: DrawContext = {
      Box: elements.Box,
      Text: elements.Text,
      Button: elements.Button,
      Markdown: elements.Markdown,
      Code: elements.Code,
      Image: 'Image' in elements ? elements.Image : undefined,
      Client: 'Client' in elements ? elements.Client : undefined,
      Input: 'Input' in elements ? elements.Input : undefined,
      C,
      surface: e.surface,
      isMenuOpen,
      current,
      chosen,
      list,
      filter,
      now,
      cwd,
      home,
      offset: at,
      bodyColumns: e.props.bodyColumns,
      bodyRows: e.props.scroll.bodyRows,
      ...geom,
      scale: contentRows > 0 ? realBody / Math.max(1, paneLayout.estimatedRows) : 1,
      contentRows,
      layout: () => paneLayout,
    }
    const actions = paneActionsOf($)
    const lists = menuLists(ctx, actions)
    const screen = await SCREENS[chosen](ctx, actions)
    // Only the group page that drew it keeps `group`; any other screen ends it.
    paneLayout = { ...paneLayout, ...screen.layout, group: screen.layout.group }
    return drawFrame(ctx, actions, lists, screen)
  })
}
