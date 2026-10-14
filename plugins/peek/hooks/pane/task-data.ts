import type { Group } from '../../types/groups'
import { groupHome, ruleCandidates } from '../groups-session'
import type { NavIo } from '../navigation'
import { mirrorDocs, mirrorRoot, newestDirs, readListState, MIRROR_CAPS, SESSION_ENDED_PROP } from '../mirror/records'
import { capturePlace, userPlace } from '../tasks/store'
import type { TaskPlace, TasksIo } from '../tasks/store'
import { matches, requiredPropsFor } from '../views/definition'
import type { Definition, MatchDoc } from '../views/definition'
import type { Item } from '../views/items'
import { createViewRegistry } from '../views/registry'
import type { ViewFolders, ViewsIo } from '../views/registry'

export const TASKS_ICON = '\u{f0ae}'
const TASKS_TAIL = '/.peek/tasks'
const MAX_ANCESTORS = 20

const registry = createViewRegistry()

export const tasksIoOf = (io: NavIo): TasksIo => ({ ...io.groupsIo(), home: io.home })

const viewsIoOf = (io: NavIo): ViewsIo => ({ list: io.list, read: io.readFile, stat: path => io.stat(path).catch(() => null) })

async function viewFolders(io: NavIo): Promise<ViewFolders> {
  return { builtIn: `${io.liveIo().root}/views`, user: `${(await io.home()) ?? ''}/.local/share/claude-peek/views` }
}

export async function definitionsOf(io: NavIo): Promise<Definition[]> {
  return (await registry.load(viewsIoOf(io), await viewFolders(io))).definitions
}

export async function definitionOfDoc(io: NavIo, doc: MatchDoc): Promise<Definition | null> {
  return registry.definitionFor(viewsIoOf(io), await viewFolders(io), doc)
}

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

export async function taskItems(io: NavIo): Promise<Item[]> {
  const home = await groupHome(io).catch(() => null)
  const [items, definitions] = await Promise.all([ruleCandidates(io, [EVERY_TASK], home?.worktreeRoot), definitionsOf(io)])
  return withDerived(items, definitions)
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
  return root ? capturePlace(tio, root) : userPlace(tio)
}

// A doc in a tasks folder belongs to that folder's repo; any other doc is a deliverable of its own worktree.
export async function placeOfDoc(io: NavIo, path: string): Promise<{ place: TaskPlace; worktree?: string }> {
  const tio = tasksIoOf(io)
  const dir = path.slice(0, path.lastIndexOf('/'))
  const user = await userPlace(tio)
  if (dir === user.folder) return { place: user }
  if (dir.endsWith(TASKS_TAIL)) return { place: await capturePlace(tio, dir.slice(0, -TASKS_TAIL.length)) }
  const ran = await io.run(['git', '-C', dir, 'rev-parse', '--show-toplevel']).catch(() => null)
  const worktree = (ran?.exitCode === 0 && ran.stdout.split('\n')[0]?.trim()) || dir
  return { place: await capturePlace(tio, worktree), worktree }
}

export async function isMirrored(io: NavIo, path: string): Promise<boolean> {
  const root = await mirrorRoot(tasksIoOf(io)).catch(() => null)
  return root !== null && path.startsWith(`${root}/`)
}

// Archived agent lists, each named by its group's title when the group is still there.
export async function archivedLists(io: NavIo): Promise<{ id: string; title: string; archivedAt: number }[]> {
  const tio = tasksIoOf(io)
  const root = await mirrorRoot(tio).catch(() => null)
  if (!root) return []
  const home = await groupHome(io).catch(() => null)
  const groups = home ? await io.shownGroups(home.place).catch(() => []) : []
  const sessions = await newestDirs(tio, root, (await io.list(root).catch(() => [])).filter(one => one.kind === 'dir').map(one => one.name), MIRROR_CAPS.sessions)
  const found: { id: string; title: string; archivedAt: number }[] = []
  for (const session of sessions) {
    const state = await readListState(tio, session, root).catch(() => null)
    for (const [list, entry] of Object.entries(state?.lists ?? {})) {
      if (entry.phase !== 'archived' || !entry.groupId) continue
      found.push({ id: entry.groupId, title: groups.find(one => one.id === entry.groupId)?.title ?? list, archivedAt: entry.archivedAt ?? 0 })
    }
  }
  return found
}

const OPEN = new Set(['todo', 'doing'])
export const PIN_CAPS = { tasks: 5, lists: 3 }

export type AgentLine = { list: string; open: number; lastAt: number }
export type RecentPins = { tasks: Item[]; moreTasks: number; lists: AgentLine[]; moreLists: number; tasksPage: string }

const isOpen = (item: { props: Item['props'] }) => typeof item.props.status === 'string' && OPEN.has(item.props.status)

// Recent's pinned open work: Shawn's own open tasks, then one line per agent list that still has open items. A list
// whose session ended or whose items are all closed is left out, the same test watch.ts folds a list by.
export async function recentPins(io: NavIo): Promise<RecentPins | null> {
  const root = (await groupHome(io).catch(() => null))?.worktreeRoot
  const items = await ruleCandidates(io, [EVERY_TASK], root)
  const own = items
    .filter(one => isOpen(one) && creatorOf(one) === 'shawn')
    .sort((a, b) => Number(b.props.status === 'doing') - Number(a.props.status === 'doing') || a.name.localeCompare(b.name))
  const counts = new Map<string, number>()
  for (const one of items) {
    const list = one.props.list
    if (typeof list !== 'string' || !isOpen(one) || one.props[SESSION_ENDED_PROP] === true) continue
    counts.set(list, (counts.get(list) ?? 0) + 1)
  }
  if (!own.length && !counts.size) return null
  const tio = tasksIoOf(io)
  const lastAt = new Map<string, number>()
  for (const doc of counts.size ? await mirrorDocs(tio).catch(() => []) : []) {
    const list = doc.props.list
    if (typeof list === 'string' && counts.has(list)) lastAt.set(list, Math.max(lastAt.get(list) ?? 0, doc.mtimeMs))
  }
  const lists = [...counts]
    .map(([list, open]) => ({ list, open, lastAt: lastAt.get(list) ?? 0 }))
    .sort((a, b) => b.lastAt - a.lastAt || a.list.localeCompare(b.list))
  const place = root ? await capturePlace(tio, root) : await userPlace(tio)
  return {
    tasks: own.slice(0, PIN_CAPS.tasks),
    moreTasks: Math.max(0, own.length - PIN_CAPS.tasks),
    lists: lists.slice(0, PIN_CAPS.lists),
    moreLists: Math.max(0, lists.length - PIN_CAPS.lists),
    tasksPage: place.folder,
  }
}
