import type { Group } from '../../types/groups'
import { groupHome, ruleCandidates, taskPlaceOf } from '../groups-session'
import type { NavIo } from '../navigation'
import { listOf, listTitleOf, mirrorDocs, mirrorRoot, mirrorSessions, placeKeyOf, shownListState, splitList } from '../mirror/records'
import type { ListPhase } from '../mirror/records'
import { tasksIoOf } from '../tasks/io'
import { OPEN_STATUSES } from '../tasks/status-words'
import { PERSON, TASKS_TAIL, capturePlace, placeOfTasksFolder, userPlace } from '../tasks/store'
import type { TaskPlace, TasksIo } from '../tasks/store'
import { matches, requiredPropsFor } from '../views/definition'
import type { Definition, MatchDoc } from '../views/definition'
import type { Item } from '../views/items'
import { recipeBlock } from '../views/recipe-source'
import type { RecipeBlock } from '../views/recipe-source'
import { createViewRegistry } from '../views/registry'
import type { ViewsIo, ViewsLoad } from '../views/registry'

export const TASKS_ICON = '\u{f0ae}'
const MAX_ANCESTORS = 20

const registry = createViewRegistry()

export async function viewsLoad(io: NavIo): Promise<ViewsLoad> {
  const viewsIo: ViewsIo = { list: io.list, read: io.readFile, stat: path => io.stat(path).catch(() => null) }
  return registry.load(viewsIo, { builtIn: `${io.liveIo().root}/views`, user: `${(await io.home()) ?? ''}/.local/share/claude-peek/views` })
}

export async function definitionsOf(io: NavIo): Promise<Definition[]> {
  return (await viewsLoad(io)).definitions
}

export const definitionIn = (load: ViewsLoad, doc: MatchDoc): Definition | null => load.definitions.find(one => matches(one, doc)) ?? null

// Every task is read the way a rule group reads its members: through a group whose empty rule matches them all.
const EVERY_TASK: Group = { projectKey: '', id: 'tasks', title: 'Tasks', description: '', starred: false, updatedAt: 0, sections: [], items: [], removed: [], rule: {} }

export const taskFilter: { creator: string | null } = { creator: null }

// Two props no doc stores: `neighbours`, the tasks a sequence links either way, and `ancestors`, the parent chain,
// so a template selects a task's neighbours and every descendant with a plain rule.
function withDerived(items: readonly Item[], definitions: readonly Definition[]): Item[] {
  const byRef = new Map<string, Item>()
  for (const item of items) for (const ref of [item.id, item.href]) if (!byRef.has(ref)) byRef.set(ref, item)
  const neighbours = new Map<string, Set<string>>()
  const link = (a: string, b: string) => {
    if (a === b) return
    neighbours.set(a, (neighbours.get(a) ?? new Set()).add(b))
    neighbours.set(b, (neighbours.get(b) ?? new Set()).add(a))
  }
  for (const item of items) {
    const sequence = item.props.sequence
    if (typeof sequence !== 'object' || sequence === null || Array.isArray(sequence)) continue
    for (const ref of Object.values(sequence).flat()) {
      const other = typeof ref === 'string' ? byRef.get(ref) : undefined
      if (other) link(item.id, other.id)
    }
  }
  const ancestorsOf = (item: Item): string[] => {
    const chain: string[] = []
    let parent = item.props.parent
    while (typeof parent === 'string' && chain.length < MAX_ANCESTORS) {
      const found = byRef.get(parent)
      if (!found || found.id === item.id || chain.includes(found.id)) break
      chain.push(found.id)
      parent = found.props.parent
    }
    return chain
  }
  return items.map(item => {
    const definition = definitions.find(one => matches(one, { path: item.href, props: item.props }))
    const missing = definition ? requiredPropsFor(definition, item.props) : []
    const near = [...(neighbours.get(item.id) ?? [])]
    const ancestors = ancestorsOf(item)
    return {
      ...item,
      props: { ...item.props, ...(near.length ? { neighbours: near } : {}), ...(ancestors.length ? { ancestors } : {}) },
      ...(missing.length ? { missing } : {}),
    }
  })
}

export async function taskItems(io: NavIo, options: { isEverywhere?: boolean } = {}, views: () => Promise<ViewsLoad> = () => viewsLoad(io)): Promise<Item[]> {
  const home = await groupHome(io).catch(() => null)
  const [items, load] = await Promise.all([ruleCandidates(io, [EVERY_TASK], home?.worktreeRoot, options), views()])
  return withDerived(items, load.definitions)
}

export type DrawData = { views: () => Promise<ViewsLoad>; items: () => Promise<Item[]>; recipe: (id: string, url: string | undefined) => Promise<RecipeBlock> }

// Shared by everything one draw reads, and made fresh for each draw so an edited definition or task shows on the next.
export function drawData(io: NavIo): DrawData {
  let views: Promise<ViewsLoad> | null = null
  let items: Promise<Item[]> | null = null
  const recipes = new Map<string, Promise<RecipeBlock>>()
  const data: DrawData = {
    views: () => (views ??= viewsLoad(io)),
    items: () => (items ??= taskItems(io, {}, data.views)),
    recipe: (id, url) => {
      const key = `${id}\n${url ?? ''}`
      const known = recipes.get(key) ?? recipeBlock(io, id, url)
      recipes.set(key, known)
      return known
    },
  }
  return data
}

export const creatorOf = (item: Item) => (typeof item.props.creator === 'string' ? item.props.creator : '')

export async function isTasksFolder(io: NavIo, path: string): Promise<boolean> {
  if (path.endsWith(TASKS_TAIL)) return true
  return (await userPlace(tasksIoOf(io)).catch(() => null))?.folder === path
}

// Shawn's list: the session repo's tasks folder, or the user-level one outside any repo.
export async function ownPlace(io: NavIo): Promise<TaskPlace> {
  const tio = tasksIoOf(io)
  const root = (await groupHome(io).catch(() => null))?.worktreeRoot
  return taskPlaceOf(tio, root)
}

// A doc in a tasks folder belongs to that folder's repo; any other doc is a deliverable of its own worktree.
export async function placeOfDoc(io: NavIo, path: string): Promise<{ place: TaskPlace; worktree?: string }> {
  const tio = tasksIoOf(io)
  const dir = path.slice(0, path.lastIndexOf('/'))
  const folderPlace = await placeOfTasksFolder(tio, dir)
  if (folderPlace) return { place: folderPlace }
  const ran = await io.run(['git', '-C', dir, 'rev-parse', '--show-toplevel']).catch(() => null)
  const worktree = (ran?.exitCode === 0 && ran.stdout.split('\n')[0]?.trim()) || dir
  return { place: await capturePlace(tio, worktree), worktree }
}

export async function isMirrored(io: NavIo, path: string): Promise<boolean> {
  const root = await mirrorRoot(tasksIoOf(io)).catch(() => null)
  return root !== null && path.startsWith(`${root}/`)
}

export type ArchivedList = { list: string; title: string; archivedAt: number }

export async function archivedLists(io: NavIo): Promise<ArchivedList[]> {
  const tio = tasksIoOf(io)
  const root = await mirrorRoot(tio).catch(() => null)
  if (!root) return []
  const place = await ownPlace(io)
  const found: ArchivedList[] = []
  const sessions = await mirrorSessions(tio, root)
  const states = await Promise.all(sessions.map(session => shownListState(tio, root, session)))
  for (const [i, session] of sessions.entries()) {
    const state = states[i]
    if (!state || placeKeyOf(state) !== place.key) continue
    for (const [key, entry] of Object.entries(state.lists)) {
      if (entry.phase !== 'archived') continue
      const list = listOf(session, Number(key))
      found.push({ list, title: listTitleOf(list), archivedAt: entry.archivedAt ?? 0 })
    }
  }
  return found
}

const PIN_CAPS = { tasks: 5, lists: 3 }

export type AgentLine = { list: string; open: number; lastAt: number; isFolded: boolean }
export type RecentPins = { tasks: Item[]; moreTasks: number; lists: AgentLine[]; moreLists: number; tasksPage: string }

const isOpen = (item: { props: Item['props'] }) => typeof item.props.status === 'string' && OPEN_STATUSES.has(item.props.status)

async function phaseOf(io: TasksIo, root: string, list: string): Promise<ListPhase | null> {
  return (await shownListState(io, root, splitList(list).session))?.lists[splitList(list).key]?.phase ?? null
}

// A folded agent list (all closed, or its session ended) keeps its line until it archives.
export async function recentPins(io: NavIo): Promise<RecentPins | null> {
  const root = (await groupHome(io).catch(() => null))?.worktreeRoot
  const items = await ruleCandidates(io, [EVERY_TASK], root)
  const own = items
    .filter(one => isOpen(one) && creatorOf(one) === PERSON)
    .sort((a, b) => Number(b.props.status === 'doing') - Number(a.props.status === 'doing') || a.name.localeCompare(b.name))
  const counts = new Map<string, number>()
  for (const one of items) {
    const list = one.props.list
    if (typeof list === 'string') counts.set(list, (counts.get(list) ?? 0) + Number(isOpen(one)))
  }
  const tio = tasksIoOf(io)
  const mirror = counts.size ? await mirrorRoot(tio).catch(() => null) : null
  const folded = new Set<string>()
  const phases = await Promise.all([...counts.keys()].map(list => (mirror ? phaseOf(tio, mirror, list) : null)))
  for (const [i, [list, open]] of [...counts].entries()) {
    const phase = phases[i]
    if (phase === 'folded') folded.add(list)
    else if (phase === 'archived' || !open) counts.delete(list)
  }
  if (!own.length && !counts.size) return null
  const lastAt = new Map<string, number>()
  for (const doc of counts.size ? await mirrorDocs(tio).catch(() => []) : []) {
    const list = doc.props.list
    if (typeof list === 'string' && counts.has(list)) lastAt.set(list, Math.max(lastAt.get(list) ?? 0, doc.mtimeMs))
  }
  const lists = [...counts]
    .map(([list, open]) => ({ list, open, lastAt: lastAt.get(list) ?? 0, isFolded: folded.has(list) }))
    .sort((a, b) => Number(a.isFolded) - Number(b.isFolded) || b.lastAt - a.lastAt || a.list.localeCompare(b.list))
  const place = await taskPlaceOf(tio, root)
  return {
    tasks: own.slice(0, PIN_CAPS.tasks),
    moreTasks: Math.max(0, own.length - PIN_CAPS.tasks),
    lists: lists.slice(0, PIN_CAPS.lists),
    moreLists: Math.max(0, lists.length - PIN_CAPS.lists),
    tasksPage: place.folder,
  }
}
