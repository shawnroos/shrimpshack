import { shortId } from '../groups'
import { asObj, tryJson } from '../wire'
import { isStatusWord, statusOf } from './store'
import type { TaskPlace, TasksIo } from './store'

export type StatusSource = 'pane' | 'tool' | 'mirror' | 'hook' | 'direct'
export type StatusChange = { id: string; doc: string; status: string; previous?: string; source: StatusSource; by: string; writer: string; at: number; worktree?: string }
export type StatusOutcome = { status: 'applied' | 'unchanged' | 'refused'; reason: string; change?: StatusChange }
export type StatusInput = { doc: string; status: string; source: StatusSource; by: string; writer: string; worktree?: string }
export type ObservedBatch = { changes: StatusChange[]; isGap: boolean }
export type Observer = {
  prime: () => Promise<void>
  poll: () => Promise<ObservedBatch>
  subscribe: (fn: (batch: ObservedBatch) => void) => () => void
  claim: (change: StatusChange, hook: string) => Promise<boolean>
}

type Known = Record<string, { status: string; at: number }>
type Held = { commit: (text: string, to: string) => Promise<void> }

const DAY_MS = 86_400_000
export const KEEP_MS = 7 * DAY_MS
// Keeps known.json far under the 4 MiB fs.read limit.
const KNOWN_CAP = 2000
const LOCK_STALE_MS = 10_000
const LOCK_POLL_MS = 100
const LOCK_POLLS = 20
// An entries folder touched this recently may gain another entry within the same timestamp, so it is listed again.
const SETTLE_MS = 2_000
const TIME_DIGITS = 15
const BUSY = 'The task log is busy, try again'

const lockOf = (place: TaskPlace) => `${place.stateDir}/lock`
const ownerOf = (lock: string) => `${lock}/owner`
const entriesOf = (place: TaskPlace) => `${place.stateDir}/entries`
const claimsOf = (place: TaskPlace) => `${place.stateDir}/claims`
const knownOf = (place: TaskPlace) => `${place.stateDir}/known.json`
const prunedOf = (place: TaskPlace) => `${place.stateDir}/pruned`
const safeName = (text: string) => text.replace(/[^A-Za-z0-9_-]/g, '_').slice(0, 40) || 'x'
const timeOf = (id: string) => Number(id.slice(0, TIME_DIGITS)) || 0
const isEntryName = (name: string) => /^\d{15}-.+\.json$/.test(name)
const isInside = (path: string, dir: string) => path.startsWith(`${dir}/`)
const newestOf = (ids: readonly string[]) => ids.reduce((most, one) => (one > most ? one : most), '')

async function dropLock(io: TasksIo, lock: string) {
  await io.run(['rm', '-f', ownerOf(lock)]).catch(() => null)
  await io.run(['rmdir', lock]).catch(() => null)
}

// The groups.ts lock: one older than LOCK_STALE_MS can be broken while its holder still runs, so the holder
// re-checks its token before every commit.
async function holdsLock(io: TasksIo, lock: string, token: string): Promise<boolean> {
  return (await io.read(ownerOf(lock)).catch(() => null)) === token
}

async function takeLock(io: TasksIo, lock: string): Promise<string | null> {
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
    const held = await io.stat(lock)
    if (held && !hasBroken && (await io.now()) - held.mtimeMs > LOCK_STALE_MS) {
      hasBroken = true
      await dropLock(io, lock)
      continue
    }
    if (poll < LOCK_POLLS) await io.sleep(LOCK_POLL_MS)
  }
  return null
}

async function underLock<T>(io: TasksIo, place: TaskPlace, work: (held: Held) => Promise<T>): Promise<T | null> {
  const stagedDir = `${place.stateDir}/staged`
  const made = await io.run(['mkdir', '-p', stagedDir]).catch(() => null)
  if (made?.exitCode !== 0) return null
  const lock = lockOf(place)
  const token = await takeLock(io, lock)
  if (!token) return null
  let n = 0
  const commit = async (text: string, to: string) => {
    const staged = `${stagedDir}/${token}-${n++}.staged`
    const wrote = await io.write(staged, text).then(
      () => true,
      () => false,
    )
    if (!wrote) throw new Error(`Could not write ${staged}`)
    if (!(await holdsLock(io, lock, token))) {
      await io.run(['rm', '-f', staged]).catch(() => null)
      throw new Error(BUSY)
    }
    const moved = await io.run(['mv', '-f', staged, to]).catch(() => null)
    if (moved?.exitCode !== 0) {
      await io.run(['rm', '-f', staged]).catch(() => null)
      throw new Error(`Could not replace ${to}`)
    }
  }
  try {
    return await work({ commit })
  } finally {
    if (await holdsLock(io, lock, token)) await dropLock(io, lock)
  }
}

const queues = new Map<string, Promise<unknown>>()

// One process queues its own writes per project, so a pane action and a tool call never race each other for the lock.
function queued<T>(place: TaskPlace, work: () => Promise<T>): Promise<T> {
  const run = (queues.get(place.stateDir) ?? Promise.resolve()).then(work)
  const tail = run.catch(() => undefined)
  queues.set(place.stateDir, tail)
  void tail.then(() => {
    if (queues.get(place.stateDir) === tail) queues.delete(place.stateDir)
  })
  return run
}

async function entryIds(io: TasksIo, place: TaskPlace): Promise<string[]> {
  const listed = await io.list(entriesOf(place)).catch(() => [])
  return listed
    .filter(one => one.kind === 'file' && isEntryName(one.name))
    .map(one => one.name.slice(0, -'.json'.length))
    .sort()
}

const readPruned = async (io: TasksIo, place: TaskPlace) => (await io.read(prunedOf(place)).catch(() => '')).trim()

async function readKnown(io: TasksIo, place: TaskPlace): Promise<Known> {
  const raw = asObj(tryJson(await io.read(knownOf(place)).catch(() => '{}'))) ?? {}
  const known: Known = {}
  for (const [doc, value] of Object.entries(raw)) {
    const one = asObj(value)
    if (one && typeof one.status === 'string') known[doc] = { status: one.status, at: typeof one.at === 'number' ? one.at : 0 }
  }
  return known
}

function capped(known: Known): Known {
  const docs = Object.entries(known)
  if (docs.length <= KNOWN_CAP) return known
  return Object.fromEntries(docs.sort((a, b) => b[1].at - a[1].at).slice(0, KNOWN_CAP))
}

// Under the lock each entry takes a time past every entry before it, pruned ones included, so ids sort in write order
// and a reader's last-seen id never skips an entry written in the same millisecond.
async function nextEntryId(io: TasksIo, place: TaskPlace, now: number, writer: string): Promise<string> {
  const newest = timeOf(newestOf([...(await entryIds(io, place)), await readPruned(io, place)]))
  return `${String(Math.max(now, newest + 1)).padStart(TIME_DIGITS, '0')}-${safeName(writer)}-${shortId(Math.random)}`
}

async function prune(io: TasksIo, place: TaskPlace, now: number) {
  const cutoff = now - KEEP_MS
  const old = (await entryIds(io, place)).filter(one => timeOf(one) < cutoff)
  for (const id of old) await io.run(['rm', '-f', `${entriesOf(place)}/${id}.json`]).catch(() => null)
  const claims = await io.list(claimsOf(place)).catch(() => [])
  for (const one of claims) if (timeOf(one.name) < cutoff) await io.run(['rmdir', `${claimsOf(place)}/${one.name}`]).catch(() => null)
  const newest = old.at(-1)
  if (newest && newest > (await readPruned(io, place))) await io.write(prunedOf(place), newest)
}

async function logChange(io: TasksIo, place: TaskPlace, held: Held, change: Omit<StatusChange, 'id'>): Promise<StatusChange> {
  const made = await io.run(['mkdir', '-p', entriesOf(place)]).catch(() => null)
  if (made?.exitCode !== 0) throw new Error(`Could not create ${entriesOf(place)}`)
  const entry: StatusChange = { id: await nextEntryId(io, place, change.at, change.writer), ...change }
  await held.commit(JSON.stringify(entry), `${entriesOf(place)}/${entry.id}.json`)
  return entry
}

export function withStatus(text: string, status: string): string {
  const lines = text.split('\n')
  const close = lines[0]?.trimEnd() === '---' ? lines.findIndex((one, i) => i > 0 && (one.trimEnd() === '---' || one.trimEnd() === '...')) : -1
  if (close < 0) return `---\nstatus: ${status}\n---\n${text}`
  const at = lines.findIndex((one, i) => i > 0 && i < close && /^status\s*:/.test(one))
  if (at < 0) lines.splice(close, 0, `status: ${status}`)
  else lines[at] = `status: ${status}`
  return lines.join('\n')
}

export function setStatus(io: TasksIo, place: TaskPlace, input: StatusInput): Promise<StatusOutcome> {
  const refuse = (reason: string): StatusOutcome => ({ status: 'refused', reason })
  if (!isStatusWord(input.status)) return Promise.resolve(refuse(`"${input.status}" is not a status`))
  const isDeliverable = !isInside(input.doc, place.folder)
  if (isDeliverable && !input.worktree) return Promise.resolve(refuse(`${input.doc} is outside the tasks folder, so its worktree is needed`))
  return queued(place, async () => {
    try {
      const done = await underLock(io, place, async (held): Promise<StatusOutcome> => {
        const text = await io.read(input.doc).catch(() => null)
        if (text === null) return refuse(`No task doc at ${input.doc}`)
        const current = statusOf(text)
        if (current === input.status) return { status: 'unchanged', reason: `Already ${current}` }
        const at = await io.now()
        await held.commit(withStatus(text, input.status), input.doc)
        const change = await logChange(io, place, held, {
          doc: input.doc,
          status: input.status,
          ...(current !== undefined ? { previous: current } : {}),
          source: input.source,
          by: input.by,
          writer: input.writer,
          at,
          ...(isDeliverable ? { worktree: input.worktree } : {}),
        })
        const known = await readKnown(io, place)
        known[input.doc] = { status: input.status, at }
        await held.commit(JSON.stringify(capped(known)), knownOf(place))
        await prune(io, place, at)
        return { status: 'applied', reason: `Set to ${input.status}`, change }
      })
      return done ?? refuse(BUSY)
    } catch (error) {
      return refuse(error instanceof Error ? error.message : String(error))
    }
  })
}

// The compare is repeated under the lock, so a direct edit is logged once, by whichever session reads it first.
// A doc seen for the first time only sets its baseline.
export async function noticeReads(io: TasksIo, place: TaskPlace, docs: readonly { path: string; status?: string; worktree?: string }[], writer: string): Promise<StatusChange[]> {
  const known = await readKnown(io, place)
  const suspects = docs.filter(one => one.status !== undefined && known[one.path]?.status !== one.status)
  if (!suspects.length) return []
  return queued(place, async () => {
    const logged = await underLock(io, place, async held => {
      const fresh = await readKnown(io, place)
      const at = await io.now()
      const changes: StatusChange[] = []
      let isChanged = false
      for (const one of suspects) {
        const text = await io.read(one.path).catch(() => null)
        const status = text === null ? undefined : statusOf(text)
        const before = fresh[one.path]?.status
        if (status === undefined || status === before) continue
        fresh[one.path] = { status, at }
        isChanged = true
        if (before === undefined) continue
        const worktree = !isInside(one.path, place.folder) ? one.worktree : undefined
        changes.push(await logChange(io, place, held, { doc: one.path, status, previous: before, source: 'direct', by: 'unknown', writer, at, ...(worktree ? { worktree } : {}) }))
      }
      if (isChanged) await held.commit(JSON.stringify(capped(fresh)), knownOf(place))
      if (changes.length) await prune(io, place, at)
      return changes
    }).catch(() => null)
    return logged ?? []
  })
}

export function observe(io: TasksIo, place: TaskPlace, session: { id: string; root: string }): Observer {
  let lastSeen = ''
  let settledMtime: number | undefined
  const subscribers = new Set<(batch: ObservedBatch) => void>()
  return {
    prime: async () => {
      lastSeen = newestOf([lastSeen, ...(await entryIds(io, place)), await readPruned(io, place)])
    },
    poll: async () => {
      const stat = await io.stat(entriesOf(place))
      if (stat && stat.mtimeMs === settledMtime) return { changes: [], isGap: false }
      settledMtime = stat && (await io.now()) - stat.mtimeMs > SETTLE_MS ? stat.mtimeMs : undefined
      const fresh = (await entryIds(io, place)).filter(one => one > lastSeen)
      const pruned = await readPruned(io, place)
      const isGap = pruned > lastSeen
      const changes: StatusChange[] = []
      for (const id of fresh) {
        const change = asObj(tryJson(await io.read(`${entriesOf(place)}/${id}.json`).catch(() => ''))) as StatusChange | null
        if (!change || change.id !== id || typeof change.doc !== 'string' || typeof change.status !== 'string') continue
        if (change.worktree !== undefined && change.worktree !== session.root) continue
        changes.push(change)
      }
      lastSeen = newestOf([lastSeen, pruned, ...fresh])
      const batch = { changes, isGap }
      if (changes.length || isGap) {
        for (const fn of subscribers) {
          try {
            fn(batch)
          } catch {
            // One failing subscriber must not keep the batch from the others.
          }
        }
      }
      return batch
    },
    subscribe: fn => {
      subscribers.add(fn)
      return () => {
        subscribers.delete(fn)
      }
    },
    claim: async (change, hook) => {
      const made = await io.run(['mkdir', '-p', claimsOf(place)]).catch(() => null)
      if (made?.exitCode !== 0) return false
      const claimed = await io.run(['mkdir', `${claimsOf(place)}/${change.id}--${safeName(hook)}`]).catch(() => null)
      return claimed?.exitCode === 0
    },
  }
}
