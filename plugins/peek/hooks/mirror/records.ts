import type { PropValue } from '../../types'
import { readFrontmatter } from '../frontmatter'
import { shortId } from '../groups'
import { fileHref } from '../paths'
import { readDoc } from '../tasks/store'
import type { TaskDoc, TaskPlace, TasksIo } from '../tasks/store'
import { asObj, tryJson } from '../wire'

export type AgentItem = { id: string; subject: string; description?: string; status: string; blockedBy: string[] }
export type ListPhase = 'active' | 'folded' | 'archived'
export type ListEntry = { phase: ListPhase; groupId?: string; foldedAt?: number; archivedAt?: number }
export type ListState = { count: number; watermark: number; isCleared: boolean; lists: Record<string, ListEntry>; placeKey?: string }
export type SessionNote = { root?: string; endedAt?: number; endedMtime?: number; reason?: string }

export const MIRROR_CAPS = { sessions: 64, items: 500, docs: 2000, states: 256 }
// The prop the U5 row drawer (SESSION_ENDED_PROP in pane/blocks/row.tsx) reads to show "session ended".
export const SESSION_ENDED_PROP = 'session_ended'
export const TASK_STATUS: Readonly<Record<string, string>> = { pending: 'todo', in_progress: 'doing', completed: 'done' }

export async function mirrorRoot(io: TasksIo): Promise<string> {
  const home = await io.home()
  if (!home) throw new Error('HOME is not set, so peek has nowhere to keep mirrored tasks')
  return `${home}/.local/share/claude-peek/mirror`
}

export const recordPathOf = (root: string, session: string, taskId: string) => `${root}/${session}/${taskId}.md`
export const listOf = (session: string, count: number) => `${session}#${count}`
const recordIdOf = (session: string, taskId: string) => `${session}/${taskId}`
export const splitList = (list: string) => ({ session: list.slice(0, list.lastIndexOf('#')), key: list.slice(list.lastIndexOf('#') + 1) })
export const listTitleOf = (list: string) => {
  const { session, key } = splitList(list)
  return `Agent tasks ${session.slice(0, 8)} #${key}`
}
export const noteOf = (root: string, session: string) => `${root}/${session}/session.json`
export const stateOf = (root: string, session: string) => `${root}/${session}/state.json`

// A record lives in the mirror folder but its status is logged in its repo's change log; with the mirror folder as the
// place's folder the status path treats it as a task of that repo, not as a deliverable bound to one worktree.
export const mirrorPlaceOf = (place: TaskPlace, root: string): TaskPlace => ({ ...place, folder: root })

const textOf = (value: unknown) => (typeof value === 'string' ? value : typeof value === 'number' ? String(value) : undefined)

export function parseAgentItem(text: string): AgentItem | null {
  const raw = asObj(tryJson(text))
  const id = textOf(raw?.id)
  const subject = textOf(raw?.subject)
  const status = textOf(raw?.status)
  if (!raw || !id || !subject || !status) return null
  const blockedBy = Array.isArray(raw.blockedBy) ? raw.blockedBy.flatMap(one => textOf(one) ?? []) : []
  const description = textOf(raw.description)
  return { id, subject, status, blockedBy, ...(description ? { description } : {}) }
}

function yamlOf(value: PropValue): string {
  if (typeof value === 'string') return JSON.stringify(value)
  if (value === null || typeof value !== 'object') return String(value)
  if (Array.isArray(value)) return `[${value.map(one => yamlOf(one)).join(', ')}]`
  return `{ ${Object.entries(value)
    .map(([key, one]) => `${key}: ${yamlOf(one as PropValue)}`)
    .join(', ')} }`
}

// withStatus for any one prop: only that line changes, and undefined removes it.
export function withProp(text: string, key: string, value: PropValue | undefined): string {
  const lines = text.split('\n')
  const close = lines[0]?.trimEnd() === '---' ? lines.findIndex((one, i) => i > 0 && (one.trimEnd() === '---' || one.trimEnd() === '...')) : -1
  const line = value === undefined ? null : `${key}: ${yamlOf(value)}`
  if (close < 0) return line ? `---\n${line}\n---\n${text}` : text
  const at = lines.findIndex((one, i) => i > 0 && i < close && one.startsWith(`${key}:`))
  if (at >= 0 && line) lines[at] = line
  else if (at >= 0) lines.splice(at, 1)
  else if (line) lines.splice(close, 0, line)
  return lines.join('\n')
}

export function recordText(input: { session: string; count: number; item: AgentItem; status: string }): string {
  const { session, item } = input
  const props: Record<string, PropValue> = {
    name: item.subject,
    id: recordIdOf(session, item.id),
    status: input.status,
    list: listOf(session, input.count),
    creator: session,
    session,
    task_id: item.id,
    agent_status: item.status,
    ...(item.blockedBy.length ? { sequence: { after: item.blockedBy.map(one => recordIdOf(session, one)) } } : {}),
  }
  const head = Object.entries(props).map(([key, value]) => `${key}: ${yamlOf(value)}`)
  return ['---', ...head, '---', (item.description ?? '').replace(/\r/g, '')].join('\n')
}

export const propsOf = (text: string) => readFrontmatter(text).props ?? {}

export async function writeAtomic(io: TasksIo, path: string, text: string): Promise<void> {
  const dir = path.slice(0, path.lastIndexOf('/'))
  const made = await io.run(['mkdir', '-p', dir]).catch(() => null)
  if (made?.exitCode !== 0) throw new Error(`Could not create ${dir}`)
  const staged = `${path}.${shortId(Math.random)}.staged`
  await io.write(staged, text)
  const moved = await io.run(['mv', '-f', staged, path]).catch(() => null)
  if (moved?.exitCode !== 0) {
    await io.run(['rm', '-f', staged]).catch(() => null)
    throw new Error(`Could not replace ${path}`)
  }
}

const readJson = async (io: TasksIo, path: string) => asObj(tryJson(await io.read(path).catch(() => '')))
const numberOf = (value: unknown) => (typeof value === 'number' && Number.isFinite(value) ? value : undefined)

export async function readNote(io: TasksIo, root: string, session: string): Promise<SessionNote> {
  const raw = (await readJson(io, noteOf(root, session))) ?? {}
  const endedAt = numberOf(raw.endedAt)
  const endedMtime = numberOf(raw.endedMtime)
  return {
    ...(typeof raw.root === 'string' ? { root: raw.root } : {}),
    ...(typeof raw.reason === 'string' ? { reason: raw.reason } : {}),
    ...(endedAt !== undefined ? { endedAt } : {}),
    ...(endedMtime !== undefined ? { endedMtime } : {}),
  }
}

export const writeNote = (io: TasksIo, root: string, session: string, note: SessionNote) => writeAtomic(io, noteOf(root, session), JSON.stringify(note))

const PHASES: readonly ListPhase[] = ['active', 'folded', 'archived']

export async function readListState(io: TasksIo, session: string, root?: string): Promise<ListState | null> {
  const raw = await readJson(io, stateOf(root ?? (await mirrorRoot(io)), session))
  const count = numberOf(raw?.count)
  if (!raw || count === undefined) return null
  const lists: Record<string, ListEntry> = {}
  for (const [key, value] of Object.entries(asObj(raw.lists) ?? {})) {
    const one = asObj(value)
    const phase = PHASES.find(name => name === one?.phase)
    if (!one || !phase) continue
    const foldedAt = numberOf(one.foldedAt)
    const archivedAt = numberOf(one.archivedAt)
    lists[key] = {
      phase,
      ...(typeof one.groupId === 'string' ? { groupId: one.groupId } : {}),
      ...(foldedAt !== undefined ? { foldedAt } : {}),
      ...(archivedAt !== undefined ? { archivedAt } : {}),
    }
  }
  return { count, watermark: numberOf(raw.watermark) ?? 0, isCleared: raw.isCleared === true, lists, ...(typeof raw.placeKey === 'string' ? { placeKey: raw.placeKey } : {}) }
}

const stateCache = new Map<string, { mtimeMs: number; state: ListState | null }>()

export async function shownListState(io: TasksIo, root: string, session: string): Promise<ListState | null> {
  const path = stateOf(root, session)
  const mtimeMs = (await io.stat(path))?.mtimeMs
  if (mtimeMs === undefined) return null
  const known = stateCache.get(path)
  if (known?.mtimeMs === mtimeMs) return known.state
  const state = await readListState(io, session, root).catch(() => null)
  if (stateCache.size >= MIRROR_CAPS.states) stateCache.clear()
  stateCache.set(path, { mtimeMs, state })
  return state
}

// A list peek could not place belongs to the user-level list (R21).
export const placeKeyOf = (state: ListState | null) => state?.placeKey ?? 'user'

export const writeListState = (io: TasksIo, root: string, session: string, state: ListState) => writeAtomic(io, stateOf(root, session), JSON.stringify(state))

// Every peek session writes a note here, so the cap must keep the newest folders rather than an arbitrary slice.
export async function newestDirs(io: TasksIo, parent: string, names: readonly string[], cap: number): Promise<string[]> {
  const stamped = await Promise.all(names.map(async name => ({ name, mtimeMs: (await io.stat(`${parent}/${name}`))?.mtimeMs ?? 0 })))
  return stamped
    .sort((a, b) => b.mtimeMs - a.mtimeMs)
    .slice(0, cap)
    .map(one => one.name)
}

export const sessionDocs = async (io: TasksIo, root: string, session: string) =>
  (await io.list(`${root}/${session}`).catch(() => [])).filter(one => one.kind === 'file' && one.name.endsWith('.md')).slice(0, MIRROR_CAPS.items)

const docCache = new Map<string, { mtimeMs: number; doc: TaskDoc | null }>()

export const mirrorSessions = async (io: TasksIo, root: string) =>
  newestDirs(io, root, (await io.list(root).catch(() => [])).filter(one => one.kind === 'dir').map(one => one.name), MIRROR_CAPS.sessions)

// A record a takeover doc replaced is left out: the doc carries the same list, so the item would show twice. With a
// place, only lists placed there and not yet archived are read; without one, every record is, so a task can still be
// found by its id after its list moved or archived.
export async function mirrorDocs(io: TasksIo, place?: { key: string }): Promise<TaskDoc[]> {
  const root = await mirrorRoot(io)
  const sessions = await mirrorSessions(io, root)
  const docs: TaskDoc[] = []
  for (const session of sessions) {
    const state = place ? await shownListState(io, root, session) : null
    if (place && placeKeyOf(state) !== place.key) continue
    const looked = await Promise.all(
      (await sessionDocs(io, root, session)).map(async one => {
        const path = `${root}/${session}/${one.name}`
        const stat = await io.stat(path)
        if (!stat) return null
        const known = docCache.get(path)
        if (known?.mtimeMs === stat.mtimeMs) return { path, known, isFresh: false }
        return { path, known: { mtimeMs: stat.mtimeMs, doc: await readDoc(io, path) }, isFresh: true }
      }),
    )
    for (const one of looked) {
      if (!one) continue
      const { path, known } = one
      if (one.isFresh) {
        docCache.delete(path)
        if (docCache.size >= MIRROR_CAPS.docs) {
          const oldest = docCache.keys().next().value
          if (oldest !== undefined) docCache.delete(oldest)
        }
        docCache.set(path, known)
      }
      const list = known.doc?.props.list
      const isArchived = place !== undefined && typeof list === 'string' && state?.lists[splitList(list).key]?.phase === 'archived'
      if (known.doc && typeof known.doc.props.takeover !== 'string' && !isArchived) docs.push(known.doc)
    }
  }
  return docs
}

const escapeLinkText = (text: string) => text.replace(/[[\]\\]/g, '\\$&')

// An archived list has no group left, so it opens as a page written from its records when Shawn asks for it.
export async function writeArchivePage(io: TasksIo, list: string): Promise<string> {
  const root = await mirrorRoot(io)
  const { session, key } = splitList(list)
  const rows: { order: number; line: string }[] = []
  for (const one of await sessionDocs(io, root, session)) {
    const path = `${root}/${session}/${one.name}`
    const props = propsOf(await io.read(path).catch(() => ''))
    if (props.list !== list) continue
    const takeover = typeof props.takeover === 'string' && (await io.stat(props.takeover)) ? props.takeover : null
    const shown = takeover ? propsOf(await io.read(takeover).catch(() => '')) : props
    const status = typeof shown.status === 'string' ? shown.status : 'todo'
    const name = typeof props.name === 'string' ? props.name : one.name
    const ended = shown[SESSION_ENDED_PROP] === true ? ' · session ended' : ''
    rows.push({ order: Number(props.task_id) || 0, line: `- ${status}${ended} · [${escapeLinkText(name)}](${fileHref(takeover ?? path)})` })
  }
  rows.sort((a, b) => a.order - b.order)
  const text = [`# ${listTitleOf(list)}`, '', `Archived agent list, ${rows.length} task${rows.length === 1 ? '' : 's'}.`, '', ...rows.map(one => one.line), ''].join('\n')
  const page = `${root.slice(0, root.lastIndexOf('/'))}/archive/${session}-${key}.md`
  await writeAtomic(io, page, text)
  return page
}
