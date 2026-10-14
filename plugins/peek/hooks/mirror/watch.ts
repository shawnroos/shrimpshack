import type { PropValue } from '../../types'
import { createGroup, deleteGroup, groupsDir, listGroups, writeGroup } from '../groups'
import { setStatus } from '../tasks/status'
import type { StatusOutcome, StatusSource } from '../tasks/status'
import { TASK_CAPS, capturePlace, createTask, userPlace } from '../tasks/store'
import type { TaskPlace, TasksIo } from '../tasks/store'
import { findTranscript, readTranscript, rebuildItems, transcriptCwd } from './rebuild'
import {
  MIRROR_CAPS,
  SESSION_ENDED_PROP,
  TASK_STATUS,
  listOf,
  mirrorPlaceOf,
  mirrorRoot,
  newestDirs,
  parseAgentItem,
  propsOf,
  readListState,
  readNote,
  recordPathOf,
  recordText,
  withProp,
  writeAtomic,
  writeListState,
  writeNote,
} from './records'
import type { AgentItem, ListEntry, ListState } from './records'

export type MirrorWrite = { status: 'applied' | 'unchanged' | 'refused'; reason: string; doc?: string }
export type Mirror = {
  poll: () => Promise<void>
  noteStart: () => Promise<void>
  noteEnd: (session: string, reason: string) => Promise<void>
  setStatus: (record: string, status: string, how: { by: string; source: StatusSource }) => Promise<MirrorWrite>
  adopt: (record: string, by: string) => Promise<MirrorWrite>
}

export const ARCHIVE_MS = 12 * 3600_000
// An open list whose folder has not moved for this long is treated as ended even with no session end recorded.
const STALE_MS = 24 * 3600_000
const FOLDERS = 200
const PLACE_RETRY_MS = 60_000
const SESSION_FOLDER = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const ITEM_FILE = /^\d+\.json$/
const OPEN = new Set(['todo', 'doing'])

type Rec = { path: string; list: string; status: string; agentStatus: string; name: string; takeover?: string; isEnded: boolean }
type Followed = { folderMtime?: number; files: Map<string, number>; records: Map<string, Rec>; state: ListState | null; isRebuildTried: boolean }

const keyOf = (list: string) => list.slice(list.lastIndexOf('#') + 1)

function recOf(path: string, text: string): Rec | null {
  const props = propsOf(text)
  const str = (key: string) => (typeof props[key] === 'string' ? (props[key] as string) : '')
  if (!str('list')) return null
  const takeover = str('takeover')
  return {
    path,
    list: str('list'),
    status: str('status'),
    agentStatus: str('agent_status'),
    name: str('name'),
    ...(takeover ? { takeover } : {}),
    isEnded: props[SESSION_ENDED_PROP] === true,
  }
}

// Every session derives the same id for a list, so two sessions seeing one list write one group.
function groupIdOf(list: string): string {
  let a = 0x811c9dc5
  let b = 0x01000193 ^ list.length
  for (let i = 0; i < list.length; i++) {
    const code = list.charCodeAt(i)
    a = Math.imul(a ^ code, 0x01000193) >>> 0
    b = Math.imul(b ^ code, 0x5bd1e995) >>> 0
  }
  return `${a.toString(36).padStart(7, '0')}${b.toString(36)}`.slice(0, 8)
}

export function createMirror(io: TasksIo, self: { id: string; root: string }): Mirror {
  const followed = new Map<string, Followed>()
  const places = new Map<string, TaskPlace>()
  const unplaced = new Map<string, number>()
  let running: Promise<void> | null = null

  const placeOf = async (root: string, session: string): Promise<TaskPlace> => {
    const known = places.get(session)
    if (known) return known
    const now = await io.now()
    // Looking for a transcript stats every project folder, so an unplaceable session is retried only now and then.
    if (now - (unplaced.get(session) ?? -Infinity) < PLACE_RETRY_MS) return userPlace(io)
    const note = await readNote(io, root, session)
    let folder = note.root
    const home = await io.home()
    if (!folder && home) {
      const path = await findTranscript(io, home, session)
      if (path) folder = transcriptCwd(await readTranscript(io, path))
    }
    if (!folder) {
      if (unplaced.size >= MIRROR_CAPS.sessions) unplaced.clear()
      unplaced.set(session, now)
      return userPlace(io)
    }
    // Only a found placement is kept: a session placed later must not stay pinned to the user log in this process.
    const place = await capturePlace(io, folder)
    if (places.size >= MIRROR_CAPS.sessions) places.clear()
    places.set(session, place)
    return place
  }

  const edit = async (path: string, change: (text: string) => string) => {
    const text = await io.read(path).catch(() => null)
    if (text === null) return
    const next = change(text)
    if (next !== text) await writeAtomic(io, path, next)
  }

  const ensureGroup = async (place: TaskPlace, session: string, key: string): Promise<string | undefined> => {
    const home = await io.home()
    // A list outside any repo has no groups folder to live in; its records still carry the list prop.
    if (place.isUser || !home) return undefined
    const gplace = { dir: groupsDir(home, place.key), projectKey: place.key }
    const list = listOf(session, Number(key))
    const id = groupIdOf(list)
    const now = await io.now()
    const others = (await listGroups(io, gplace)).filter(one => one.id !== id)
    const write = await writeGroup(io, gplace, id, current =>
      current
        ? { group: current, outcomes: [] }
        : createGroup(
            { projectKey: place.key, id, title: `Agent tasks ${session.slice(0, 8)} #${key}` },
            [
              { op: 'setRule', rule: { list } },
              { op: 'setSplit', split: 'status' },
            ],
            { now, newId: () => id, actor: 'agent', others },
          ),
    )
    return write.ok && write.group ? id : undefined
  }

  const archiveGroup = async (place: TaskPlace, groupId: string) => {
    const home = await io.home()
    if (place.isUser || !home) return
    // deleteGroup refuses a group Shawn starred or added to, so that one stays where it is.
    await writeGroup(io, { dir: groupsDir(home, place.key), projectKey: place.key }, groupId, current => (current ? deleteGroup(current) : { group: null, outcomes: [] }))
  }

  const follow = async (root: string, session: string): Promise<Followed> => {
    const known = followed.get(session)
    if (known) return known
    const records = new Map<string, Rec>()
    const names = (await io.list(`${root}/${session}`).catch(() => [])).filter(one => one.kind === 'file' && one.name.endsWith('.md'))
    for (const one of names.slice(0, MIRROR_CAPS.items)) {
      const path = `${root}/${session}/${one.name}`
      const rec = recOf(path, (await io.read(path).catch(() => null)) ?? '')
      if (rec) records.set(one.name.slice(0, -'.md'.length), rec)
    }
    const fresh: Followed = { files: new Map(), records, state: await readListState(io, session, root), isRebuildTried: false }
    if (followed.size >= MIRROR_CAPS.sessions) followed.clear()
    followed.set(session, fresh)
    return fresh
  }

  const take = async (root: string, session: string, f: Followed, state: ListState, item: AgentItem) => {
    const status = TASK_STATUS[item.status]
    if (!status) return
    const path = recordPathOf(root, session, item.id)
    let rec = f.records.get(item.id) ?? null
    if (!rec) {
      const onDisk = await io.read(path).catch(() => null)
      const text = onDisk ?? recordText({ session, count: state.count, item: { ...item, subject: item.subject.slice(0, TASK_CAPS.name) }, status })
      if (onDisk === null) await writeAtomic(io, path, text)
      rec = recOf(path, text)
      if (!rec || f.records.size >= MIRROR_CAPS.items) return
      f.records.set(item.id, rec)
      const key = keyOf(rec.list)
      state.lists[key] ??= { phase: 'active' }
    }
    if (rec.agentStatus !== item.status) {
      const place = await placeOf(root, session)
      const target = rec.takeover ?? rec.path
      const outcome = await setStatus(io, rec.takeover ? place : mirrorPlaceOf(place, root), { doc: target, status, source: 'mirror', by: session, writer: self.id })
      if (outcome.status === 'refused') return
      if (!rec.takeover) rec.status = status
      await edit(rec.path, text => withProp(text, 'agent_status', item.status))
      rec.agentStatus = item.status
    }
  }

  const readFolder = async (root: string, session: string, dir: string, f: Followed) => {
    const entries = await io.list(dir).catch(() => [])
    const items = entries.filter(one => one.kind === 'file' && ITEM_FILE.test(one.name)).slice(0, MIRROR_CAPS.items)
    const watermark = entries.some(one => one.name === '.highwatermark') ? Number((await io.read(`${dir}/.highwatermark`).catch(() => '')).trim()) || 0 : 0
    let state = f.state
    let rebuilt: AgentItem[] = []
    if (!state && !items.length) {
      // Claude Code clears a finished list's files, leaving `.lock` and `.highwatermark`; only then is the transcript tried.
      if (f.isRebuildTried || !watermark || f.records.size) return
      f.isRebuildTried = true
      const home = await io.home()
      const path = home ? await findTranscript(io, home, session) : null
      rebuilt = path ? rebuildItems(await readTranscript(io, path)) : []
      if (!rebuilt.length) return
    }
    if (!state) state = { count: 1, watermark, isCleared: false, lists: {} }
    else if (watermark > state.watermark) {
      if (f.records.size) state.count++
      state.watermark = watermark
      state.isCleared = false
    } else if (!items.length && f.records.size) state.isCleared = true
    else if (state.isCleared && items.some(one => !f.records.has(one.name.slice(0, -'.json'.length)))) {
      state.count++
      state.isCleared = false
    }
    f.state = state
    for (const item of rebuilt) await take(root, session, f, state, item)
    const present = new Set(items.map(one => one.name))
    for (const name of [...f.files.keys()]) if (!present.has(name)) f.files.delete(name)
    for (const one of items) {
      const path = `${dir}/${one.name}`
      const stat = await io.stat(path)
      if (!stat || f.files.get(one.name) === stat.mtimeMs) continue
      const item = parseAgentItem((await io.read(path).catch(() => null)) ?? '')
      f.files.set(one.name, stat.mtimeMs)
      if (item) await take(root, session, f, state, item)
    }
  }

  const settle = async (root: string, session: string, f: Followed, state: ListState, folderMtime: number) => {
    const now = await io.now()
    const note = await readNote(io, root, session)
    const isEnded = (note.endedAt !== undefined && (note.endedMtime === undefined || folderMtime <= note.endedMtime)) || now - folderMtime > STALE_MS
    for (const [key, entry] of Object.entries(state.lists)) {
      const live = [...f.records.values()].filter(rec => keyOf(rec.list) === key && !rec.takeover)
      if (!live.length) continue
      // A list Claude Code has since cleared is over too: its open items will never move again.
      const isOver = isEnded || Number(key) < state.count
      for (const rec of live) {
        const isEndedNow = isOver && OPEN.has(rec.status)
        if (rec.isEnded === isEndedNow) continue
        await edit(rec.path, text => withProp(text, SESSION_ENDED_PROP, isEndedNow ? true : undefined))
        rec.isEnded = isEndedNow
      }
      const isFolded = isOver || !live.some(rec => OPEN.has(rec.status))
      let next: ListEntry = entry
      if (!isFolded) next = entry.phase === 'active' ? entry : { phase: 'active', ...(entry.phase === 'folded' && entry.groupId ? { groupId: entry.groupId } : {}) }
      else if (entry.phase === 'active') next = { ...entry, phase: 'folded', foldedAt: now }
      else if (entry.phase === 'folded' && now - (entry.foldedAt ?? now) >= ARCHIVE_MS) {
        if (entry.groupId) await archiveGroup(await placeOf(root, session), entry.groupId)
        const { groupId: _gone, ...rest } = entry
        next = { ...rest, phase: 'archived', archivedAt: now }
      }
      if (next.phase !== 'archived' && !next.groupId) {
        const groupId = await ensureGroup(await placeOf(root, session), session, key)
        if (groupId) next = { ...next, groupId }
      }
      state.lists[key] = next
    }
  }

  const scan = async (root: string, tasks: string, session: string) => {
    const dir = `${tasks}/${session}`
    const stat = await io.stat(dir)
    if (!stat) return
    const f = await follow(root, session)
    const isMoved = stat.mtimeMs !== f.folderMtime
    // Claude Code may rewrite an item in place, which leaves the folder's time alone, so a list still in work is read
    // item by item on every poll.
    const isInWork = [...f.records.values()].some(rec => rec.agentStatus !== 'completed')
    const before = JSON.stringify(f.state)
    if (isMoved || isInWork) await readFolder(root, session, dir, f)
    f.folderMtime = stat.mtimeMs
    const state = f.state
    if (!state) return
    await settle(root, session, f, state, stat.mtimeMs)
    if (JSON.stringify(state) !== before) await writeListState(io, root, session, state)
  }

  const pollAll = async () => {
    const home = await io.home()
    if (!home) return
    const root = await mirrorRoot(io)
    const tasks = `${home}/.claude/tasks`
    const names = (await io.list(tasks).catch(() => [])).filter(one => one.kind === 'dir' && SESSION_FOLDER.test(one.name)).map(one => one.name)
    const sessions = await newestDirs(io, tasks, names, FOLDERS)
    for (const session of sessions) {
      // One unreadable folder must not stop the others from mirroring.
      await scan(root, tasks, session).catch(() => undefined)
    }
  }

  const takeOver = async (record: string, extra: Record<string, PropValue>): Promise<MirrorWrite & { place?: TaskPlace }> => {
    const text = await io.read(record).catch(() => null)
    const props = text === null ? {} : propsOf(text)
    const session = typeof props.session === 'string' ? props.session : ''
    const list = typeof props.list === 'string' ? props.list : ''
    const name = typeof props.name === 'string' ? props.name : ''
    if (!session || !list || !name) return { status: 'refused', reason: `${record} is not a mirrored task` }
    const root = await mirrorRoot(io)
    const place = await placeOf(root, session)
    const prior = typeof props.takeover === 'string' ? props.takeover : ''
    if (prior && (await io.stat(prior))) {
      for (const [key, value] of Object.entries(extra)) await edit(prior, one => withProp(one, key, value))
      return { status: 'unchanged', reason: 'Already taken over', doc: prior, place }
    }
    const status = typeof props.status === 'string' ? props.status : 'todo'
    const made = await createTask(io, place, { name, creator: session, status })
    if (made.status !== 'applied') return made
    const carried: Record<string, PropValue | undefined> = { mirror: props.id, list, session, task_id: props.task_id, sequence: props.sequence, ...extra }
    await edit(made.path, one => Object.entries(carried).reduce((doc, [key, value]) => (value === undefined ? doc : withProp(doc, key, value)), one))
    await edit(record, one => withProp(withProp(one, 'takeover', made.path), SESSION_ENDED_PROP, undefined))
    const rec = followed.get(session)?.records.get(typeof props.task_id === 'string' ? props.task_id : '')
    if (rec) {
      rec.takeover = made.path
      rec.isEnded = false
    }
    return { status: 'applied', reason: `Took over "${name}"`, doc: made.path, place }
  }

  return {
    poll: () => {
      running ??= pollAll().finally(() => {
        running = null
      })
      return running
    },
    noteStart: async () => {
      const root = await mirrorRoot(io)
      places.delete(self.id)
      await writeNote(io, root, self.id, { root: self.root })
    },
    noteEnd: async (session, reason) => {
      const root = await mirrorRoot(io)
      const home = await io.home()
      const folder = home ? await io.stat(`${home}/.claude/tasks/${session}`) : null
      const note = await readNote(io, root, session)
      await writeNote(io, root, session, { ...note, endedAt: await io.now(), reason, ...(folder ? { endedMtime: folder.mtimeMs } : {}) })
    },
    setStatus: async (record, status, how) => {
      const taken = await takeOver(record, {})
      if (taken.status === 'refused' || !taken.doc || !taken.place) return taken
      const outcome: StatusOutcome = await setStatus(io, taken.place, { doc: taken.doc, status, source: how.source, by: how.by, writer: self.id })
      return { status: outcome.status, reason: outcome.reason, doc: taken.doc }
    },
    adopt: async (record, by) => {
      const taken = await takeOver(record, { adopted_by: by })
      return { status: taken.status, reason: taken.reason, ...(taken.doc ? { doc: taken.doc } : {}) }
    },
  }
}
