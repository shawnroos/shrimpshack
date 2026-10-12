import type { Group, GroupContext, GroupItem, GroupOp, GroupOutcome, GroupResult, GroupSection } from '../types'
import { parseHref } from './lib'
import { itemKey } from './refs'

// A group file at these caps stays far under the 4 MiB fs.read limit.
export const GROUP_CAPS = { groups: 50, items: 200, sections: 20, removed: 100, description: 500, label: 200 }

type Step = { group: Group; outcome: GroupOutcome }

export const refused = (op: GroupOutcome['op'], reason: string, extra: Partial<GroupOutcome> = {}): GroupOutcome => ({ op, status: 'refused', reason, ...extra })

export function shortId(random: () => number): string {
  let id = ''
  for (let i = 0; i < 8; i++) id += Math.min(35, Math.floor(random() * 36)).toString(36)
  return id
}

const fold = (text: string) => text.trim().toLowerCase()

function titleTaken(title: string, others: readonly Group[], selfId?: string): Group | undefined {
  return others.find(one => one.id !== selfId && fold(one.title) === fold(title))
}

function findSection(group: Group, name: string): GroupSection | undefined {
  return group.sections.find(one => one.id === name) ?? group.sections.find(one => fold(one.title) === fold(name))
}

function sectionTitle(group: Group, id: string | undefined): string {
  return id ? `"${group.sections.find(one => one.id === id)?.title ?? id}"` : 'the unsectioned block'
}

function findItem(group: Group, ref: string): GroupItem | undefined {
  const key = itemKey(ref)
  return group.items.find(one => itemKey(one.ref) === key)
}

function placed(item: GroupItem, section: string | undefined): GroupItem {
  const { section: _old, ...rest } = item
  return section ? { ...rest, section } : rest
}

function tombstone(removed: readonly string[], key: string): string[] {
  return [...removed.filter(one => one !== key), key].slice(-GROUP_CAPS.removed)
}

function applyOne(group: Group, op: GroupOp, ctx: GroupContext): Step {
  const done = (next: Group, reason: string, extra: Partial<GroupOutcome> = {}): Step => ({
    group: { ...next, updatedAt: ctx.now },
    outcome: { op: op.op, status: 'applied', reason, ...extra },
  })
  const keep = (status: 'unchanged' | 'refused', reason: string, extra: Partial<GroupOutcome> = {}): Step => ({
    group,
    outcome: { op: op.op, status, reason, ...extra },
  })
  const noSection = (name: string) => keep('refused', `No section "${name}" in this group`)

  switch (op.op) {
    case 'setTitle': {
      const title = op.title.trim()
      if (!title) return keep('refused', 'A group needs a title')
      const clash = titleTaken(title, ctx.others, group.id)
      if (clash) return keep('refused', `A group named "${clash.title}" already exists`, { groupId: clash.id })
      if (title === group.title) return keep('unchanged', 'The title is already that')
      return done({ ...group, title }, `Renamed to "${title}"`)
    }
    case 'setDescription': {
      if (op.description.length > GROUP_CAPS.description) {
        return keep('refused', `A description holds at most ${GROUP_CAPS.description} characters`)
      }
      if (op.description === group.description) return keep('unchanged', 'The description is already that')
      return done({ ...group, description: op.description }, 'Description set')
    }
    case 'addSection': {
      const title = op.title.trim()
      if (!title) return keep('refused', 'A section needs a title')
      const clash = findSection(group, title)
      if (clash && fold(clash.title) === fold(title)) {
        return keep('refused', `A section named "${clash.title}" already exists`, { sectionId: clash.id })
      }
      if (group.sections.length >= GROUP_CAPS.sections) {
        return keep('refused', `A group holds at most ${GROUP_CAPS.sections} sections`)
      }
      const section = { id: ctx.newId(), title }
      return done({ ...group, sections: [...group.sections, section] }, `Added section "${title}"`, { sectionId: section.id })
    }
    case 'renameSection': {
      const section = findSection(group, op.section)
      if (!section) return noSection(op.section)
      const title = op.title.trim()
      if (!title) return keep('refused', 'A section needs a title')
      const clash = group.sections.find(one => one.id !== section.id && fold(one.title) === fold(title))
      if (clash) return keep('refused', `A section named "${clash.title}" already exists`, { sectionId: clash.id })
      if (title === section.title) return keep('unchanged', 'The section is already called that', { sectionId: section.id })
      const sections = group.sections.map(one => (one.id === section.id ? { ...one, title } : one))
      return done({ ...group, sections }, `Renamed section to "${title}"`, { sectionId: section.id })
    }
    case 'removeSection': {
      const section = findSection(group, op.section)
      if (!section) return noSection(op.section)
      return done(
        {
          ...group,
          sections: group.sections.filter(one => one.id !== section.id),
          items: group.items.map(one => (one.section === section.id ? placed(one, undefined) : one)),
        },
        `Removed section "${section.title}"; its items moved to the unsectioned block`,
        { sectionId: section.id },
      )
    }
    case 'reorderSections': {
      const sections = op.order.map(name => findSection(group, name))
      const ids = new Set(sections.map(one => one?.id))
      if (sections.some(one => !one) || ids.size !== sections.length || ids.size !== group.sections.length) {
        return keep('refused', 'A reorder names every section exactly once')
      }
      if (sections.every((one, i) => one?.id === group.sections[i]?.id)) return keep('unchanged', 'The sections are already in that order')
      return done({ ...group, sections: sections.filter((one): one is GroupSection => Boolean(one)) }, 'Sections reordered')
    }
    case 'addItem': {
      const ref = op.ref.trim()
      if (!ref) return keep('refused', 'An item needs a file or link')
      if (op.label !== undefined && op.label.length > GROUP_CAPS.label) {
        return keep('refused', `A label holds at most ${GROUP_CAPS.label} characters`, { ref })
      }
      const wanted = ctx.actor === 'person' || op.section === undefined ? undefined : findSection(group, op.section)
      if (ctx.actor === 'agent' && op.section !== undefined && !wanted) return noSection(op.section)
      const present = findItem(group, ref)
      if (present) {
        if (present.section === wanted?.id) return keep('unchanged', `${ref} is already in this group`, { ref })
        return keep('unchanged', `${ref} is already in ${sectionTitle(group, present.section)}; move it to change its place`, {
          ref,
          ...(present.section ? { sectionId: present.section } : {}),
        })
      }
      const key = itemKey(ref)
      const isTombstoned = group.removed.includes(key)
      if (isTombstoned && ctx.actor === 'agent' && !op.force) {
        return keep('refused', `The person removed ${ref} from this group; pass force to add it back`, { ref, needsForce: true })
      }
      if (group.items.length >= GROUP_CAPS.items) return keep('refused', `A group holds at most ${GROUP_CAPS.items} items`, { ref })
      const item: GroupItem = {
        ref,
        ...(wanted ? { section: wanted.id } : {}),
        addedBy: ctx.actor,
        addedAt: ctx.now,
        ...(op.label !== undefined ? { label: op.label } : {}),
      }
      return done(
        { ...group, items: [...group.items, item], removed: isTombstoned ? group.removed.filter(one => one !== key) : group.removed },
        `Added ${ref} to ${sectionTitle(group, wanted?.id)}`,
        { ref },
      )
    }
    case 'moveItem': {
      const present = findItem(group, op.ref)
      if (!present) return keep('refused', `${op.ref} is not in this group`, { ref: op.ref })
      const target = op.section === undefined ? undefined : findSection(group, op.section)
      if (op.section !== undefined && !target) return noSection(op.section)
      if (present.section === target?.id) return keep('unchanged', `${op.ref} is already there`, { ref: op.ref })
      return done(
        { ...group, items: group.items.map(one => (one === present ? placed(one, target?.id) : one)) },
        `Moved ${op.ref} to ${sectionTitle(group, target?.id)}`,
        { ref: op.ref },
      )
    }
    case 'removeItem': {
      const present = findItem(group, op.ref)
      if (!present) return keep('unchanged', `${op.ref} is not in this group`, { ref: op.ref })
      if (ctx.actor === 'agent' && present.addedBy === 'person' && !op.force) {
        return keep('refused', `The person added ${present.ref}; pass force to remove it`, { ref: present.ref, needsForce: true })
      }
      return done(
        {
          ...group,
          items: group.items.filter(one => one !== present),
          removed: ctx.actor === 'person' ? tombstone(group.removed, itemKey(present.ref)) : group.removed,
        },
        `Removed ${present.ref}`,
        { ref: present.ref },
      )
    }
  }
}

export function applyGroupOps(group: Group, ops: readonly GroupOp[], ctx: GroupContext): { group: Group; outcomes: GroupOutcome[] } {
  const outcomes: GroupOutcome[] = []
  let current = group
  for (const op of ops) {
    const step = applyOne(current, op, ctx)
    current = step.group
    outcomes.push(step.outcome)
  }
  return { group: current, outcomes }
}

export function createGroup(
  input: { projectKey: string; id?: string; title: string; description?: string },
  ops: readonly GroupOp[],
  ctx: GroupContext,
): GroupResult {
  const refuse = (reason: string, groupId?: string): GroupResult => ({ group: null, outcomes: [refused('create', reason, groupId ? { groupId } : {})] })
  const title = input.title.trim()
  if (!title) return refuse('A group needs a title')
  const clash = titleTaken(title, ctx.others)
  if (clash) return refuse(`A group named "${clash.title}" already exists`, clash.id)
  if (ctx.others.length >= GROUP_CAPS.groups) return refuse(`A project holds at most ${GROUP_CAPS.groups} groups`)
  const empty: Group = {
    projectKey: input.projectKey,
    id: input.id ?? ctx.newId(),
    title,
    description: '',
    starred: false,
    updatedAt: ctx.now,
    sections: [],
    items: [],
    removed: [],
  }
  const setup: GroupOp[] = input.description ? [{ op: 'setDescription', description: input.description }] : []
  const applied = applyGroupOps(empty, [...setup, ...ops], ctx)
  return {
    group: applied.group,
    outcomes: [{ op: 'create', status: 'applied', reason: `Created "${title}"`, groupId: empty.id }, ...applied.outcomes],
  }
}

export function starGroup(group: Group, starred: boolean): { group: Group; outcomes: GroupOutcome[] } {
  if (group.starred === starred) {
    return { group, outcomes: [{ op: 'star', status: 'unchanged', reason: starred ? 'Already starred' : 'Not starred' }] }
  }
  return {
    group: { ...group, starred },
    outcomes: [{ op: 'star', status: 'applied', reason: starred ? 'Starred' : 'Unstarred' }],
  }
}

export function deleteGroup(group: Group, force = false): GroupResult {
  const theirs = group.items.filter(one => one.addedBy === 'person').map(one => one.ref)
  const losses = [...(group.starred ? ['the person starred it'] : []), ...(theirs.length ? [`the person added ${theirs.join(', ')}`] : [])]
  if (losses.length && !force) {
    return {
      group,
      outcomes: [{ op: 'delete', status: 'refused', reason: `Not deleted: ${losses.join('; ')}. Pass force to delete it anyway`, groupId: group.id, needsForce: true }],
    }
  }
  return { group: null, outcomes: [{ op: 'delete', status: 'applied', reason: `Deleted "${group.title}"`, groupId: group.id }] }
}

export type GroupsRun = { exitCode: number; stdout: string; stderr: string }

export type GroupsIo = {
  read: (path: string) => Promise<string>
  write: (path: string, text: string) => Promise<void>
  list: (dir: string) => Promise<readonly { name: string; kind: string }[]>
  stat: (path: string) => Promise<{ mtimeMs: number } | null>
  run: (argv: readonly string[]) => Promise<GroupsRun>
  now: () => Promise<number>
  sleep: (ms: number) => Promise<void>
}

export type GroupPlace = { dir: string; projectKey: string }

export type GroupWrite =
  | { ok: true; group: Group | null; outcomes: GroupOutcome[]; isChanged: boolean }
  | { ok: false; error: string }

const LOCK_STALE_MS = 10_000
const LOCK_POLL_MS = 100
// 20 polls of 100 ms: a lock still held after about 2 s refuses the write.
const LOCK_POLLS = 20

const GROUP_ID = /^[0-9a-z]{8}$/

export const isGroupId = (id: string) => GROUP_ID.test(id)

export function projectHash(key: string): string {
  let a = 0x811c9dc5
  let b = 0x01000193 ^ key.length
  for (let i = 0; i < key.length; i++) {
    const code = key.charCodeAt(i)
    a = Math.imul(a ^ code, 0x01000193) >>> 0
    b = Math.imul(b ^ code, 0x5bd1e995) >>> 0
  }
  return `${a.toString(16).padStart(8, '0')}${b.toString(16).padStart(8, '0')}`
}

export function groupsDir(homeDir: string, projectKey: string): string {
  return `${homeDir}/.local/share/claude-peek/groups/${projectHash(projectKey)}`
}

export async function resolveProjectKey(run: GroupsIo['run'], root: string): Promise<string> {
  const ran = await run(['git', '-C', root, 'rev-parse', '--path-format=absolute', '--git-common-dir']).catch(() => null)
  const key = ran?.exitCode === 0 ? ran.stdout.trim() : ''
  return key || root
}

export const isScheme = (ref: string) => /^[a-z][a-z0-9+.-]*:/i.test(ref)

export function storedRef(href: string, worktreeRoot?: string): string {
  if (!worktreeRoot || !href.startsWith('file:')) return href
  const url = new URL(href)
  const path = decodeURIComponent(url.pathname)
  if (!path.startsWith(`${worktreeRoot}/`)) return href
  const line = /^#L(\d+)$/.exec(url.hash)
  return `${path.slice(worktreeRoot.length + 1)}${line ? `#L${line[1]}` : ''}`
}

export function refPath(ref: string, worktreeRoot?: string): { path: string; line?: number } | null {
  if (isScheme(ref)) return parseHref(ref)
  if (!worktreeRoot) return null
  const match = /^(.*?)(?:#L(\d+))?$/.exec(ref)
  return { path: `${worktreeRoot}/${match?.[1] ?? ref}`, ...(match?.[2] ? { line: Number(match[2]) } : {}) }
}

type Loose = Record<string, unknown>

const isLoose = (value: unknown): value is Loose => Boolean(value) && typeof value === 'object'

function parseItem(one: unknown): GroupItem[] {
  if (!isLoose(one) || typeof one.ref !== 'string') return []
  return [
    {
      ref: one.ref,
      ...(typeof one.section === 'string' ? { section: one.section } : {}),
      // An unreadable addedBy keeps the person's protection rather than letting the agent remove it.
      addedBy: one.addedBy === 'agent' ? 'agent' : 'person',
      addedAt: typeof one.addedAt === 'number' ? one.addedAt : 0,
      ...(typeof one.label === 'string' ? { label: one.label } : {}),
    },
  ]
}

const parseSection = (one: unknown): GroupSection[] =>
  isLoose(one) && typeof one.id === 'string' && typeof one.title === 'string' ? [{ id: one.id, title: one.title }] : []

function parseGroup(text: string, projectKey: string): Group | null {
  let raw: unknown
  try {
    raw = JSON.parse(text)
  } catch {
    return null
  }
  const group = raw as Partial<Group> | null
  if (!group || typeof group !== 'object') return null
  if (group.projectKey !== projectKey || typeof group.id !== 'string' || typeof group.title !== 'string') return null
  if (!Array.isArray(group.sections) || !Array.isArray(group.items) || !Array.isArray(group.removed)) return null
  const sections = (group.sections as unknown[]).flatMap(parseSection)
  const kept = new Set(sections.map(one => one.id))
  return {
    projectKey,
    id: group.id,
    title: group.title,
    description: typeof group.description === 'string' ? group.description : '',
    starred: group.starred === true,
    updatedAt: typeof group.updatedAt === 'number' ? group.updatedAt : 0,
    sections,
    items: (group.items as unknown[]).flatMap(parseItem).map(one => (one.section && !kept.has(one.section) ? placed(one, undefined) : one)),
    removed: (group.removed as unknown[]).filter((one): one is string => typeof one === 'string'),
  }
}

export const fileOf = (place: GroupPlace, id: string) => `${place.dir}/${id}.json`

export async function readGroup(io: GroupsIo, place: GroupPlace, id: string): Promise<Group | null> {
  if (!isGroupId(id)) return null
  const text = await io.read(fileOf(place, id)).catch(() => null)
  const group = text === null ? null : parseGroup(text, place.projectKey)
  return group?.id === id ? group : null
}

export async function listGroups(io: GroupsIo, place: GroupPlace): Promise<Group[]> {
  const entries = await io.list(place.dir).catch(() => [])
  const ids = entries.filter(one => one.kind === 'file' && /^[0-9a-z]{8}\.json$/.test(one.name)).map(one => one.name.slice(0, 8))
  const groups = await Promise.all(ids.map(id => readGroup(io, place, id)))
  return groups.filter((one): one is Group => one !== null).sort((a, b) => b.updatedAt - a.updatedAt || a.id.localeCompare(b.id))
}

const ownerOf = (lock: string) => `${lock}/owner`

async function dropLock(io: GroupsIo, lock: string) {
  await io.run(['rm', '-f', ownerOf(lock)]).catch(() => null)
  await io.run(['rmdir', lock]).catch(() => null)
}

// A lock older than LOCK_STALE_MS can be broken by another session while its holder is
// still running, so a holder re-checks this token before it commits or releases.
async function holdsLock(io: GroupsIo, lock: string, token: string): Promise<boolean> {
  return (await io.read(ownerOf(lock)).catch(() => null)) === token
}

async function takeLock(io: GroupsIo, lock: string): Promise<string | null> {
  let hasBroken = false
  for (let poll = 0; poll <= LOCK_POLLS; poll++) {
    const made = await io.run(['mkdir', lock]).catch(() => null)
    if (made?.exitCode === 0) {
      const token = `${shortId(Math.random)}${shortId(Math.random)}`
      const wrote = await io.write(ownerOf(lock), token).then(
        () => true,
        () => false,
      )
      if (wrote) return token
      await dropLock(io, lock)
      return null
    }
    const held = await io.stat(lock).catch(() => null)
    if (held && !hasBroken && (await io.now()) - held.mtimeMs > LOCK_STALE_MS) {
      hasBroken = true
      await dropLock(io, lock)
      continue
    }
    if (poll < LOCK_POLLS) await io.sleep(LOCK_POLL_MS)
  }
  return null
}

async function lockedWrite(
  io: GroupsIo,
  place: GroupPlace,
  id: string,
  change: (current: Group | null) => GroupResult,
): Promise<GroupWrite> {
  const file = fileOf(place, id)
  const lock = `${file}.lock`
  const made = await io.run(['mkdir', '-p', place.dir]).catch(() => null)
  if (made?.exitCode !== 0) return { ok: false, error: `Could not create the groups folder ${place.dir}` }
  const busy = { ok: false as const, error: `Group ${id} is busy, try again` }
  const token = await takeLock(io, lock)
  if (!token) return busy
  try {
    const current = await readGroup(io, place, id)
    const { group, outcomes } = change(current)
    if (group === current) return { ok: true, group, outcomes, isChanged: false }
    if (!group) {
      if (!(await holdsLock(io, lock, token))) return busy
      const removed = await io.run(['rm', '-f', file]).catch(() => null)
      if (removed?.exitCode !== 0) return { ok: false, error: `Could not delete ${file}` }
      return { ok: true, group, outcomes, isChanged: true }
    }
    const staged = `${file}.${token}.staged`
    const wrote = await io.write(staged, JSON.stringify(group, null, 2)).then(
      () => true,
      () => false,
    )
    if (!wrote) return { ok: false, error: `Could not write ${staged}` }
    if (!(await holdsLock(io, lock, token))) {
      await io.run(['rm', '-f', staged]).catch(() => null)
      return busy
    }
    const moved = await io.run(['mv', '-f', staged, file]).catch(() => null)
    if (moved?.exitCode !== 0) {
      await io.run(['rm', '-f', staged]).catch(() => null)
      return { ok: false, error: `Could not replace ${file}` }
    }
    return { ok: true, group, outcomes, isChanged: true }
  } finally {
    if (await holdsLock(io, lock, token)) await dropLock(io, lock)
  }
}

const queues = new Map<string, Promise<unknown>>()

// One process queues its own writes per group, so a pane action and a tool call never race each other for the lock.
export function writeGroup(
  io: GroupsIo,
  place: GroupPlace,
  id: string,
  change: (current: Group | null) => GroupResult,
): Promise<GroupWrite> {
  if (!isGroupId(id)) return Promise.resolve({ ok: false, error: `${id} is not a group id` })
  const key = fileOf(place, id)
  const run = (queues.get(key) ?? Promise.resolve()).then(() => lockedWrite(io, place, id, change))
  const tail = run.catch(() => undefined)
  queues.set(key, tail)
  void tail.then(() => {
    if (queues.get(key) === tail) queues.delete(key)
  })
  return run
}
