import type { Mode, View } from '../../types'
import type { RecipePage } from '../../types/recipes'
import { nextOf } from '../gallery'
import type { RoleFilter, Scope } from '../gallery'
import { setStar, toggleExpanded, toggleGroupStar } from '../groups-session'
import { writeArchivePage } from '../mirror/records'
import { openFromPage, refresh, switchMode } from '../navigation'
import type { Cell, NavIo } from '../navigation'
import { fileHref, parseHref } from '../paths'
import { setStatus } from '../tasks/status'
import { taskSession } from '../tasks/poll'
import { tasksIoOf } from '../tasks/io'
import { PERSON, readDoc } from '../tasks/store'
import { ICON, ROLE_ICON, SCOPE_ICON } from '../theme'
import { LAYOUTS } from '../views/definition'
import type { Item } from '../views/items'
import { asObj } from '../wire'
import { cycleLayoutOfRow, onPlaceChange, setPlace, toggleFoldOfRow } from './blocks/common'
import type { PlaceState } from './blocks/common'
import { isEnded } from './blocks/row'
import { isMirrored, ownPlace, placeOfDoc } from './task-data'
import type { ArchivedList } from './task-data'
import type { Action, PaneActions } from './types'

export const MODES: { id: Mode; label: string; icon: string; hotkey: string; row: string; about: string; isMenuSwitch: boolean }[] = [
  { id: 'view', label: 'Peek', icon: ICON.peek, hotkey: 'p', row: 'peek', about: 'show the open file', isMenuSwitch: false },
  { id: 'recent', label: 'Recent', icon: ICON.recent, hotkey: 'r', row: 'recent', about: 'files by last use', isMenuSwitch: false },
  { id: 'gallery', label: 'Gallery', icon: ICON.gallery, hotkey: 'g', row: 'gallery', about: 'files as cards by type', isMenuSwitch: false },
  { id: 'groups', label: 'Groups', icon: ICON.groups, hotkey: 'e', row: 'groups', about: 'files and links the agent bundled', isMenuSwitch: true },
]

const ROLES: RoleFilter[] = ['all', 'artifacts', 'touched']
const SCOPES: Scope[] = ['session', 'worktree', 'repo']

export const MOVE_KEYS = new Set(['next', 'prev', 'left', 'right'])

export const modeActions = (actions: PaneActions): Action[] =>
  MODES.map(one => ({
    id: `mode-${one.id}`,
    label: one.label,
    hotkey: one.hotkey,
    run: () => void switchMode(actions.io, one.id),
  }))

// The ⌃k rows for Peek, Recent and Gallery set the mode alone, so the page offset and the open group stay as they
// were; the Groups row, the footer mode keys and the tabs all go through switchMode. Unifying them changes behavior.
export const modeRows = (io: NavIo, hasView: boolean): Action[] =>
  MODES.filter(one => hasView || one.id !== 'view').map(one => ({
    id: one.row,
    icon: one.icon,
    label: `${one.label}: ${one.about}`,
    hintFrom: `mode-${one.id}`,
    run: one.isMenuSwitch ? () => void switchMode(io, one.id) : () => void io.mode.update(() => one.id),
  }))

function cycleActions<T extends string>(spec: {
  id: string
  hotkey: string
  label: string
  values: readonly T[]
  icon: Record<T, string>
  cell: (actions: PaneActions) => Cell<T>
}) {
  return {
    action: (actions: PaneActions, current: T): Action => ({
      id: spec.id,
      label: `${spec.label}: ${current}`,
      hotkey: spec.hotkey,
      run: () => void spec.cell(actions).update(one => nextOf(spec.values, one)),
    }),
    rows: (actions: PaneActions): Action[] =>
      spec.values.map(one => ({
        id: `${spec.id}-${one}`,
        icon: spec.icon[one],
        label: `${spec.label}: ${one}`,
        hintFrom: spec.id,
        run: () => void spec.cell(actions).update(() => one),
      })),
  }
}

const role = cycleActions({ id: 'role', hotkey: 'a', label: 'Show', values: ROLES, icon: ROLE_ICON, cell: actions => actions.roleFilter })
const scope = cycleActions({ id: 'scope', hotkey: 's', label: 'Scope', values: SCOPES, icon: SCOPE_ICON, cell: actions => actions.scope })
export const roleAction = role.action
export const roleRows = role.rows
export const scopeAction = scope.action
export const scopeRows = scope.rows

export const selectActions = (actions: PaneActions): Action[] => [
  { id: 'next', label: 'Down', hotkey: 'j', run: () => void actions.moveSelection('down') },
  { id: 'prev', label: 'Up', hotkey: 'k', run: () => void actions.moveSelection('up') },
  { id: 'left', label: 'Left', hotkey: 'h', run: () => void actions.moveSelection('left') },
  { id: 'right', label: 'Right', hotkey: 'l', run: () => void actions.moveSelection('right') },
  {
    id: 'open-selected',
    label: '⏎ Open',
    hotkey: 'o',
    menu: 'Open the selected file',
    run: () => void actions.selectedNav().then(one => actions.openNav(one)),
  },
  {
    id: 'star-selected',
    label: 'Star',
    hotkey: 'f',
    menu: 'Star or unstar the selected file',
    run: () =>
      void actions.selectedNav().then(one => {
        if (one?.group) return toggleGroupStar(actions.io, one.group)
        return one?.href ? setStar(actions.io, one.href).then(() => undefined) : undefined
      }),
  },
]

export const closeAction = (actions: PaneActions): Action => ({ id: 'close', label: 'Close', hotkey: 'x', run: () => void actions.close() })

export const expandAction = (actions: PaneActions, chosen: Mode): Action => ({
  id: 'expand-selected',
  label: 'More',
  hotkey: 'm',
  menu: 'Expand/Collapse group',
  run: () =>
    void actions.selectedNav().then(one => {
      const id = one?.group ?? (one && chosen === 'groups' ? one.href : undefined)
      if (id) toggleExpanded(actions.io, id)
    }),
})

// The cursor is one atom shared by every list, so a page opened after another list starts on `start` (its first row,
// or -1 for none); it follows the atom again once a person moves it on this page.
const pageCursor = { href: '', atOpen: 0, isOwned: false }

export async function cursorOnPage(io: Pick<NavIo, 'cursor'>, href: string, start = 0): Promise<number> {
  const raw = await io.cursor.read()
  if (pageCursor.href !== href) Object.assign(pageCursor, { href, atOpen: raw, isOwned: false })
  else if (!pageCursor.isOwned && raw !== pageCursor.atOpen) pageCursor.isOwned = true
  return pageCursor.isOwned ? raw : start
}

// True when this call took the cursor for the page, setting it to the first row.
export async function claimCursor(io: Pick<NavIo, 'cursor'>, href: string): Promise<boolean> {
  if (pageCursor.href === href && pageCursor.isOwned) return false
  await io.cursor.update(() => 0)
  Object.assign(pageCursor, { href, atOpen: 0, isOwned: true })
  return true
}

const isPageError = (page: RecipePage | undefined) => page?.phase === 'failed' || page?.phase === 'conflict'

// A draft's review holds the first focus, so its page starts with no row selected.
export const startsWithNoRow = (page: RecipePage | undefined) => Boolean(page && page.phase !== 'conflict' && page.isDraft && page.review)

// The footer, the menu and the menu target read what a link page can do from here.
export function pageCaps(current: View) {
  const isLink = Boolean(current.remote || current.page)
  const isError = isPageError(current.page)
  return {
    canRefresh: isLink,
    canStar: !isError,
    hasMenuTarget: !isError,
    openLabel: isLink ? 'Open in browser' : 'Open',
    copyLabel: isLink ? 'Copy link' : 'Copy path',
    refreshLabel: isError ? 'Retry' : 'Refresh',
  }
}

const STATUS_CYCLE = ['todo', 'doing', 'done'] as const

const NO_SESSION = 'peek has not started following tasks in this session yet'

// Every pane status change goes through the one status path; a mirrored record goes through the mirror, which makes
// the takeover doc first (R21). A refusal leaves the doc as it was and says why.
async function changeStatus(io: NavIo, path: string, pick: (current: string | undefined) => string) {
  const tio = tasksIoOf(io)
  const doc = await readDoc(tio, path)
  if (!doc) {
    io.toast(`Could not set the status: no task doc at ${path}`)
    return
  }
  const status = pick(doc.status)
  const who = { by: PERSON, source: 'pane' as const }
  let outcome: { status: string; reason: string }
  if (await isMirrored(io, path)) {
    const mirror = taskSession()?.mirror
    outcome = mirror ? await mirror.setStatus(path, status, who) : { status: 'refused', reason: NO_SESSION }
  } else {
    const { place, worktree } = await placeOfDoc(io, path)
    outcome = await setStatus(tio, place, { doc: path, status, ...who, writer: await io.sessionId(), ...(worktree ? { worktree } : {}) })
  }
  if (outcome.status === 'refused') io.toast(`Could not set the status: ${outcome.reason}`)
  if (outcome.status !== 'applied') return
  const current = await io.view.read()
  if (current && parseHref(current.href)?.path === path) await refresh(io, current.href)
  io.invalidate()
}

const nextStatus = (current: string | undefined) => nextOf<string>(STATUS_CYCLE, current ?? '')

export const canAdopt = (item: Item) => item.source === 'mirrored' && isEnded(item) && typeof item.props.takeover !== 'string'

export async function adopt(io: NavIo, item: Item) {
  const mirror = taskSession()?.mirror
  const made = mirror ? await mirror.adopt(item.href, PERSON) : { status: 'refused', reason: NO_SESSION }
  io.toast(made.status === 'refused' ? `Could not adopt the task: ${made.reason}` : made.reason)
  io.invalidate()
}

// `target` is read when the key is pressed: the selected block row, or the page's own task.
export function taskActions(actions: PaneActions, page: { href: string; hasRows: boolean; statusOf: () => Promise<string | null>; adoptable: Item | null }): Action[] {
  const io = actions.io
  const selectedKey = async () => {
    await claimCursor(io, page.href)
    return (await actions.selectedNav())?.key
  }
  const onRow = (change: (key: string) => unknown) => async () => {
    const key = await selectedKey()
    if (key && change(key)) io.invalidate()
  }
  const status = (pick: (current: string | undefined) => string) => async () => {
    const path = await page.statusOf()
    if (path) await changeStatus(io, path, pick)
  }
  return [
    { id: 'task-status', label: 'Status', hotkey: 'w', menu: 'Status: todo, doing, done', run: status(nextStatus) },
    { id: 'task-cancel', label: 'Cancel', menu: 'Set cancelled', run: status(() => 'cancelled') },
    ...(page.hasRows
      ? [
          { id: 'task-layout', label: 'Layout', hotkey: 'y', menu: `Layout: switch the selected block (${LAYOUTS.join(', ')})`, run: onRow(cycleLayoutOfRow) },
          { id: 'task-fold', label: 'Fold', hotkey: 'z', menu: 'Fold or unfold the selected parent', run: onRow(toggleFoldOfRow) },
        ]
      : []),
    ...(page.adoptable ? [{ id: 'task-adopt', label: 'Adopt', menu: 'Adopt this task', run: () => adopt(io, page.adoptable as Item) }] : []),
  ]
}

export function creatorRows(io: NavIo, creators: readonly string[], filter: { creator: string | null }): Action[] {
  const choose = (creator: string | null) => () => {
    filter.creator = creator
    io.invalidate()
  }
  return [
    ...[...new Set(creators)].sort().map((creator, index) => ({ id: `task-creator-${index}`, label: creator, menu: `Filter: creator ${creator}`, run: choose(creator) })),
    { id: 'task-creator-all', label: 'anyone', menu: 'Filter: creator anyone', run: choose(null) },
  ]
}

async function openArchivedList(io: NavIo, list: string) {
  const page = await writeArchivePage(tasksIoOf(io), list).catch(() => null)
  if (page) await openFromPage(io, fileHref(page))
  else io.toast(`Could not open the archived list ${list}`)
}

export function archivedRows(io: NavIo, lists: readonly ArchivedList[]): Action[] {
  return [...lists]
    .sort((a, b) => b.archivedAt - a.archivedAt)
    .map(one => ({ id: `archived-${one.list}`, label: `Archived: ${one.title}`, menu: `Archived: ${one.title}`, run: () => openArchivedList(io, one.list) }))
}

export async function openTasksPage(io: NavIo) {
  await openFromPage(io, fileHref((await ownPlace(io)).folder))
}

const MAX_SAVED_PLACES = 200

function placeStateOf(raw: unknown): PlaceState | null {
  const one = asObj(raw)
  if (!one || !Array.isArray(one.folded) || !one.folded.every(id => typeof id === 'string')) return null
  if (one.layout !== undefined && !(LAYOUTS as readonly unknown[]).includes(one.layout)) return null
  return { ...(one.layout === undefined ? {} : { layout: one.layout as PlaceState['layout'] }), folded: one.folded as string[] }
}

// Called once at session start: loads the saved layout and fold choices, then saves each change.
export async function wirePlaces(io: Pick<NavIo, 'storeGet' | 'storeSet'>) {
  const saved = asObj(await io.storeGet('places').catch(() => undefined)) ?? {}
  const kept: Record<string, PlaceState> = {}
  for (const [place, raw] of Object.entries(saved).slice(-MAX_SAVED_PLACES)) {
    const state = placeStateOf(raw)
    if (!state) continue
    kept[place] = state
    setPlace(place, state)
  }
  onPlaceChange((place, state) => {
    delete kept[place]
    kept[place] = state
    const oldest = Object.keys(kept)[0]
    if (oldest !== undefined && Object.keys(kept).length > MAX_SAVED_PLACES) delete kept[oldest]
    void io.storeSet('places', { ...kept }).catch(() => undefined)
  })
}
