import type { Group, GroupItem, GroupOp, GroupResult } from '../types/groups'
import { sessionMemo } from './cache'
import { gitRoot, toHref } from './entries'
import { toggleStar } from './gallery'
import { applyGroupOps, groupsDir, isScheme, membersOf, refPath, resolveProjectKey, shortId, starGroup, storedRef } from './groups'
import type { GroupPlace, GroupWrite } from './groups'
import { remotePicture } from './images'
import { nav, navigate, saveTitles, remoteLoader, remoteRef, show, starKeyOf, startTicking } from './navigation'
import type { NavIo } from './navigation'
import { type ItemLook, type ItemState, remoteNaming } from './pane/look'
import type { Action } from './pane/types'
import { baseName, dirName, fileHref, kindOf, parseHref, resolvePath } from './paths'
import { cached, refreshItem } from './refresh'
import type { TitleEntry } from './refresh'
import { itemKey } from './refs'
import { capturePlace, createIndex, folderDocPaths, readDoc, TASK_CAPS, userPlace } from './tasks/store'
import type { TaskDoc, TaskIndex, TaskPlace, TasksIo } from './tasks/store'
import { mirrorDocs } from './mirror/records'
import { tasksIoOf } from './tasks/io'
import { taskSession } from './tasks/poll'
import { ICON } from './theme'
import { itemFromDoc } from './views/items'
import type { Item } from './views/items'
import { parseUrl } from './wire'

export async function setStar(io: NavIo, raw: string, wanted?: boolean): Promise<boolean> {
  const canonical = remoteRef(raw)?.address ?? raw
  let isOn = false
  await io.stars.update(list => {
    const href = list.find(one => starKeyOf(one) === itemKey(canonical)) ?? canonical
    const next = toggleStar(list, href, wanted)
    isOn = next.includes(href)
    return next
  })
  await io.storeSet('stars', await io.stars.read()).catch(() => undefined)
  return isOn
}

export async function openGroupPage(io: NavIo, id: string) {
  await navigate(io, [{ to: 'openGroup', change: () => ({ id, item: null }) }, { to: 'mode', mode: 'groups' }, { to: 'page' }])
}

async function personWrite(
  io: NavIo,
  id: string,
  failure: string,
  change: (current: Group, now: number) => GroupResult,
  onWritten: (write: Extract<GroupWrite, { ok: true }>) => void = () => undefined,
) {
  const home = await groupHome(io)
  if (!home) {
    io.toast(`${failure}: HOME is not set.`)
    return
  }
  const now = await io.now()
  let isGone = false
  const write = await io.writeGroup(home.place, id, current => {
    if (current) return change(current, now)
    isGone = true
    return { group: null, outcomes: [] }
  })
  if (!write.ok) io.toast(`${failure}: ${write.error}.`)
  else if (isGone) {
    io.toast('That group was deleted.')
    if ((await io.openGroup.read())?.id === id) await io.openGroup.update(() => null)
  } else onWritten(write)
  io.invalidate()
}

export async function toggleGroupStar(io: NavIo, id: string) {
  await personWrite(io, id, 'Could not star the group', current => starGroup(current, !current.starred))
}

export const starredFirst = (groups: readonly Group[]) => [...groups].sort((a, b) => Number(b.starred) - Number(a.starred))

// The tab re-sorts starred-first, so the cursor index is re-pointed at the group it was on;
// left on its old index, the next f would toggle a different card.
export async function starInGroupsTab(io: NavIo, id: string) {
  const kept = (await io.selectedNav())?.href
  await toggleGroupStar(io, id)
  const home = await groupHome(io)
  if (!home || !kept) return
  const index = starredFirst(await io.shownGroups(home.place)).findIndex(one => one.id === kept)
  if (index >= 0) await io.cursor.update(() => index)
  io.invalidate()
}

async function personGroupWrite(io: NavIo, id: string, title: string, op: Extract<GroupOp, { op: 'addItem' | 'removeItem' }>) {
  const verb = op.op === 'addItem' ? 'add to' : 'remove from'
  const home = await groupHome(io)
  const shown = home && op.op === 'removeItem' ? await io.shownGroup(home.place, id) : null
  const candidates = shown && home ? await ruleCandidates(io, [shown], home.worktreeRoot) : []
  const ruleMembers = (current: Group) => membersOf(current, candidates, home?.worktreeRoot).flatMap(one => (one.addedBy === 'rule' ? [one.ref] : []))
  await personWrite(
    io,
    id,
    `Could not ${verb} ${title}`,
    (current, now) => applyGroupOps(current, [op], { now, newId: () => shortId(Math.random), actor: 'person', others: [], ruleMembers: ruleMembers(current) }),
    write => {
      const outcome = write.outcomes[0]
      const name = write.group?.title ?? title
      if (outcome?.status === 'applied') io.toast(op.op === 'addItem' ? `Added to ${name}` : `Removed from ${name}`)
      else if (outcome?.status === 'unchanged' && op.op === 'addItem') io.toast(`Already in ${name}`)
      else io.toast(outcome?.reason ?? `Could not ${verb} ${name}.`)
    },
  )
}

async function personGroupAdd(io: NavIo, id: string, title: string, href: string) {
  const target = await groupTarget(io, href, (await groupHome(io))?.worktreeRoot, true)
  if ('error' in target) io.toast(`Could not add to ${title}: ${target.error}.`)
  else await personGroupWrite(io, id, title, { op: 'addItem', ref: target.ref })
}

export type GroupMenuFor = { target?: string; group?: Group; selectedRef?: string; starHint?: string }

const GROUP_MENU_ROWS = 8

export async function groupMenuRows(io: NavIo, on: GroupMenuFor): Promise<Action[]> {
  const home = await groupHome(io)
  if (!home) return []
  const open = on.group
  const own: Action[] = open
    ? [
        { id: 'group-star', icon: ICON.star, label: `${open.starred ? 'Unstar' : 'Star'} this group`, hint: on.starHint ?? '', run: () => void toggleGroupStar(io, open.id) },
        ...(on.selectedRef !== undefined
          ? [{ id: 'group-remove-here', icon: '\u{f068}', label: 'Remove from this group', hint: '', run: () => void personGroupWrite(io, open.id, open.title, { op: 'removeItem', ref: on.selectedRef ?? '' }) }]
          : []),
      ]
    : []
  const href = on.target
  const target = href ? await groupTarget(io, href, home.worktreeRoot, false) : null
  if (!href || !target || 'error' in target) return own.map(one => ({ ...one, isGroupRow: true }))
  const key = itemKey(target.ref)
  const groups = (await io.shownGroups(home.place)).filter(one => one.id !== open?.id)
  const rows = groups.map((one, index): Action => {
    const held = one.items.find(item => itemKey(item.ref) === key)
    const isFilteredOnly = index >= GROUP_MENU_ROWS
    return held
      ? { id: `group-remove-${one.id}`, icon: '\u{f068}', label: `Remove from group: ${one.title}`, hint: '', isFilteredOnly, run: () => void personGroupWrite(io, one.id, one.title, { op: 'removeItem', ref: held.ref }) }
      : { id: `group-add-${one.id}`, icon: '\u{f067}', label: `Add to group: ${one.title}`, hint: '', isFilteredOnly, run: () => void personGroupAdd(io, one.id, one.title, href) }
  })
  return [...own, ...rows].map(one => ({ ...one, isGroupRow: true }))
}

// Drawing may not write state, so the page keeps what its handlers need here: the row last drawn or selected (a
// selected item another session removes falls to it), the remote items the refresh tick should keep fresh, and
// which deleted group was already reported. The Groups tab clears `drawn`.
export const groupPage = {
  drawn: null as { id: string; selected: number } | null,
  goneNotice: '',
  remotes: [] as string[],
}

// Opening from a card sets openGroup too, so Back lands on the group page with this item selected.
export async function openGroupHref(io: NavIo, group: { id: string; title: string }, key: string, href: string) {
  const file = href ? parseHref(href) : null
  if (!href || (file && !(await io.exists(file.path).catch(() => false)))) {
    io.toast(`That file is gone: ${file?.path ?? key}`)
    return
  }
  await io.openGroup.update(() => ({ id: group.id, item: key }))
  nav.groupBack = { id: group.id, title: group.title, depth: nav.backStack.length }
  await show(io, href, true)
}

export async function openCardItem(io: NavIo, id: string, key: string, href: string) {
  const home = await groupHome(io)
  const group = home ? await io.shownGroup(home.place, id) : null
  if (group) await openGroupHref(io, group, key, href)
  else io.toast('That group was deleted.')
}

// Per pane and never saved. Only handlers change it: a draw may not write state.
export const expandedGroups = new Set<string>()

export function toggleExpanded(io: NavIo, id: string) {
  if (!expandedGroups.delete(id)) expandedGroups.add(id)
  io.invalidate()
}

export async function groupItemLook(io: NavIo, item: GroupItem, worktreeRoot: string | undefined, known: ReadonlyMap<string, TitleEntry>): Promise<ItemLook> {
  const key = itemKey(item.ref)
  const file = refPath(item.ref, worktreeRoot)
  if (file) {
    const { state, stat } = await fileState(io, file.path)
    const name = baseName(file.path)
    const folder = dirName(file.path)
    const where = worktreeRoot && folder.startsWith(worktreeRoot) ? folder.slice(worktreeRoot.length + 1) : folder
    return { key, href: fileHref(file.path, file.line), name: item.label ?? name, kind: stat?.kind === 'dir' ? 'folder' : kindOf(file.path), where, state }
  }
  const state = await itemState(io, item.ref, worktreeRoot)
  if (!isScheme(item.ref)) return { key, href: '', name: item.label ?? item.ref, kind: kindOf(item.ref), where: '', state }
  const ref = remoteRef(item.ref)
  const address = ref?.address ?? item.ref
  const title = known.get(key)
  const host = () => parseUrl(address)?.hostname ?? ''
  const naming = remoteNaming(ref, title, { label: item.label, bare: address, namesThread: false, host })
  return {
    key,
    href: address,
    name: naming.name,
    kind: naming.kind,
    where: naming.where,
    state,
    favicon: (await remotePicture(io, title?.favicon))?.file,
  }
}

export function loadGroupRemote(io: NavIo, address: string) {
  startTicking(io)
  void io
    .now()
    .then(now => refreshItem(address, remoteLoader(io, false), now))
    .then(() => saveTitles(io))
    .then(() => io.invalidate())
    .catch(() => undefined)
}

export type GroupHome = { place: GroupPlace; worktreeRoot?: string }

// Any `keep` makes a rejected lookup drop out, so the next call retries it; every resolved one stays.
const groupHomes = sessionMemo<GroupHome | null>({ keep: () => true })

async function findGroupHome(io: NavIo, root: string): Promise<GroupHome | null> {
  const homeDir = await io.home()
  if (!homeDir) return null
  const projectKey = await resolveProjectKey(argv => io.run(argv), root)
  const git = await gitRoot(io, root)
  return { place: { dir: groupsDir(homeDir, projectKey), projectKey }, worktreeRoot: git?.root }
}

export async function groupHome(io: NavIo): Promise<GroupHome | null> {
  const root = await io.sessionRoot()
  const key = `${await io.sessionId()}|${root}`
  return groupHomes.get(key, () => findGroupHome(io, root))
}

export type GroupTarget = { raw: string; ref: string } | { raw: string; error: string }

export async function groupTarget(io: NavIo, raw: string, worktreeRoot: string | undefined, isAdd: boolean): Promise<GroupTarget> {
  const trimmed = raw.trim()
  const href = await toHref(io, trimmed).catch(() => null)
  if (href) {
    const file = parseHref(href)
    if (isAdd && file && !(await io.exists(file.path).catch(() => false))) return { raw: trimmed, error: `No file at ${file.path}` }
    return { raw: trimmed, ref: storedRef(remoteRef(href)?.address ?? href, worktreeRoot) }
  }
  if (isAdd || !trimmed) return { raw: trimmed, error: `No file or URL at ${trimmed}` }
  if (isScheme(trimmed)) return { raw: trimmed, ref: trimmed }
  const abs = resolvePath(trimmed.replace(/:\d+$/, ''), await io.cwd(), (await io.home()) ?? '')
  return { raw: trimmed, ref: storedRef(fileHref(abs), worktreeRoot) }
}

// stat rejects for a missing path and for any other failure, so only a failed stat asks exists which one it was.
async function fileState(io: NavIo, path: string): Promise<{ state: ItemState; stat: { kind: string } | null }> {
  const stat = await io.stat(path).catch(() => null)
  if (stat) return { state: 'ok', stat }
  const state = await io.exists(path).then(
    (found): ItemState => (found ? 'ok' : 'missing'),
    (): ItemState => 'unavailable',
  )
  return { state, stat: null }
}

export async function itemState(io: NavIo, ref: string, worktreeRoot?: string): Promise<ItemState> {
  const file = refPath(ref, worktreeRoot)
  if (file) return (await fileState(io, file.path)).state
  if (!isScheme(ref)) return 'missing'
  const entry = cached(ref)
  if (entry?.failure === 'gone') return 'missing'
  return entry?.state === 'failed' || entry?.state === 'stale-since' ? 'unavailable' : 'ok'
}

const RULE_CAPS = { worktrees: 4, docs: 2 * TASK_CAPS.folderDocs }
const ruleIndexes = new Map<string, TaskIndex>()
const ruleDocs = new Map<string, { mtimeMs: number; doc: TaskDoc | null }>()

function indexOf(worktree: string): TaskIndex {
  const known = ruleIndexes.get(worktree)
  if (known) return known
  if (ruleIndexes.size >= RULE_CAPS.worktrees) ruleIndexes.clear()
  const index = createIndex(worktree)
  ruleIndexes.set(worktree, index)
  return index
}

async function folderTaskDocs(io: TasksIo, place: TaskPlace): Promise<TaskDoc[]> {
  const docs = await Promise.all(
    (await folderDocPaths(io, place)).map(async path => {
      const stat = await io.stat(path)
      if (!stat) return null
      const known = ruleDocs.get(path)
      if (known?.mtimeMs === stat.mtimeMs) return known.doc
      const doc = await readDoc(io, path)
      if (ruleDocs.size >= RULE_CAPS.docs) ruleDocs.clear()
      ruleDocs.set(path, { mtimeMs: stat.mtimeMs, doc })
      return doc
    }),
  )
  return docs.filter((one): one is TaskDoc => one !== null)
}

// The session's task poll already holds this worktree's places and keeps its index fresh, so draws reuse them
// instead of running git each time.
const liveSession = (worktreeRoot?: string) => {
  const live = taskSession()
  return live && worktreeRoot && live.root === worktreeRoot ? live : null
}

export async function taskPlaceOf(io: TasksIo, worktreeRoot?: string): Promise<TaskPlace> {
  const live = liveSession(worktreeRoot)?.places[0]
  if (live) return live
  return worktreeRoot ? capturePlace(io, worktreeRoot) : userPlace(io)
}

// Mirrored lists are read for this worktree's repo, or for the user-level list outside one; `isEverywhere` reads every
// list, archived ones too, for finding a task by its id.
export async function ruleCandidates(io: NavIo, groups: readonly Group[], worktreeRoot?: string, options: { isEverywhere?: boolean } = {}): Promise<Item[]> {
  if (!groups.some(one => one.rule || one.split)) return []
  const tio = tasksIoOf(io)
  const live = liveSession(worktreeRoot)
  const [user, repo] = await Promise.all([userPlace(tio).catch(() => null), worktreeRoot ? taskPlaceOf(tio, worktreeRoot).catch(() => null) : null])
  const places = [repo, user].filter((one, at, all): one is TaskPlace => one !== null && all.findIndex(other => other?.folder === one.folder) === at)
  const index = worktreeRoot && repo && !repo.isUser ? (live?.index ?? indexOf(worktreeRoot)) : null
  const shownPlace = repo ?? user
  const [folders, , mirrored] = await Promise.all([
    Promise.all(places.map(place => folderTaskDocs(tio, place).catch(() => []))).then(found => found.flat()),
    index && !live ? index.refresh(tio).catch(() => undefined) : undefined,
    options.isEverywhere ? mirrorDocs(tio).catch(() => []) : shownPlace ? mirrorDocs(tio, shownPlace).catch(() => []) : [],
  ])
  const seen = new Set<string>()
  const items: Item[] = []
  for (const [docs, source] of [[folders, 'task-folder'], [index?.docs() ?? [], 'deliverable'], [mirrored, 'mirrored']] as const) {
    for (const doc of docs) {
      if (seen.has(doc.path)) continue
      seen.add(doc.path)
      items.push(itemFromDoc(doc, { type: 'task', source }))
    }
  }
  return items
}
