import { expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { capturePlace, createTask, listFolderTasks } from '../hooks/tasks/store'
import type { TaskPlace, TasksIo } from '../hooks/tasks/store'
import { SETTLE_MS, noticeReads, observe, setStatus } from '../hooks/tasks/status'
import type { StatusChange } from '../hooks/tasks/status'
import { tasksWorld } from './fixtures/world'
import type { World } from './fixtures/world'

const DAY = 86_400_000
const SHIP = '/wt/feature/docs/ship.md'
const SHIP_TEXT = '---\nname: Ship the export\nisTask: true\nstatus: todo\n---\n# Ship\n'

async function setup(on: On, files: Record<string, string> = {}): Promise<{ w: World; io: TasksIo; place: TaskPlace }> {
  const { w, io } = tasksWorld(on, files)
  return { w, io, place: await capturePlace(io, '/repo') }
}

async function newTask(io: TasksIo, place: TaskPlace, name: string): Promise<string> {
  const made = await createTask(io, place, { name, creator: 'shawn' })
  if (made.status !== 'applied') throw new Error(made.reason)
  return made.path
}

const entriesIn = (w: World, place: TaskPlace) => Object.keys(w.files).filter(one => one.startsWith(`${place.stateDir}/entries/`))
const line = (one: StatusChange) => `${one.source}:${one.by}:${one.previous ?? '-'}->${one.status}`

test('AE4: a status change from the pane and one from a tool both reach a second session through the one path', async (_$, on) => {
  const { io, place } = await setup(on)
  const doc = await newTask(io, place, 'Write the launch note')
  const other = observe(io, place, { id: 'session-two', root: '/wt/feature' })
  await other.prime()
  const seen: StatusChange[] = []
  other.subscribe(batch => seen.push(...batch.changes))
  expect((await setStatus(io, place, { doc, status: 'done', source: 'pane', by: 'shawn', writer: 'session-one' })).status).toBe('applied')
  expect((await setStatus(io, place, { doc, status: 'doing', source: 'tool', by: 'session-one', writer: 'session-one' })).status).toBe('applied')
  await other.poll()
  expect(seen.map(line)).toEqual(['pane:shawn:todo->done', 'tool:session-one:done->doing'])
  expect(seen.every(one => one.doc === doc && one.writer === 'session-one' && one.worktree === undefined)).toBe(true)
})

test('setting the same status twice rewrites the doc once and logs one entry', async (_$, on) => {
  const { w, io, place } = await setup(on)
  const doc = await newTask(io, place, 'Tidy the notes')
  const watcher = observe(io, place, { id: 'watcher', root: '/repo' })
  await watcher.prime()
  w.log = []
  const first = await setStatus(io, place, { doc, status: 'done', source: 'pane', by: 'shawn', writer: 's1' })
  const second = await setStatus(io, place, { doc, status: 'done', source: 'tool', by: 's2', writer: 's2' })
  expect([first.status, second.status]).toEqual(['applied', 'unchanged'])
  expect(w.log.filter(one => one[0] === 'run' && one[1] === 'mv' && one[4] === doc)).toHaveLength(1)
  expect(entriesIn(w, place)).toHaveLength(1)
  expect((await watcher.poll()).changes.map(line)).toEqual(['pane:shawn:todo->done'])
})

test('a status change rewrites only the status line and leaves every other byte of the doc alone', async (_$, on) => {
  const { w, io, place } = await setup(on)
  const doc = await newTask(io, place, 'Keep the rest')
  const before = `${w.files[doc] ?? ''}\nA body line with status: todo in it.\n`
  w.files[doc] = before
  await setStatus(io, place, { doc, status: 'doing', source: 'pane', by: 'shawn', writer: 's1' })
  expect(w.files[doc]).toBe(before.replace(/^status: todo$/m, 'status: doing'))
})

test('a direct edit to a doc\'s status is logged once on the next read, not once per session that reads it', async (_$, on) => {
  const { w, io, place } = await setup(on)
  const doc = await newTask(io, place, 'Edited by hand')
  const watcher = observe(io, place, { id: 'watcher', root: '/repo' })
  await watcher.prime()
  await noticeReads(io, place, await listFolderTasks(io, place), 's1')
  expect(entriesIn(w, place)).toHaveLength(0)
  w.files[doc] = (w.files[doc] ?? '').replace('status: todo', 'status: done')
  w.touch(doc)
  const read = await listFolderTasks(io, place)
  const [two, three] = await Promise.all([noticeReads(io, place, read, 's2'), noticeReads(io, place, read, 's3')])
  const later = await noticeReads(io, place, await listFolderTasks(io, place), 's4')
  expect([...two, ...three].map(line)).toEqual(['direct:unknown:todo->done'])
  expect(later).toEqual([])
  expect(entriesIn(w, place)).toHaveLength(1)
  expect((await watcher.poll()).changes.map(line)).toEqual(['direct:unknown:todo->done'])
})

test('two sessions reacting to one change: only the one that claims it acts', async (_$, on) => {
  const { io, place } = await setup(on)
  const doc = await newTask(io, place, 'Claim me')
  const two = observe(io, place, { id: 'two', root: '/repo' })
  const three = observe(io, place, { id: 'three', root: '/wt/feature' })
  await two.prime()
  await three.prime()
  await setStatus(io, place, { doc, status: 'done', source: 'pane', by: 'shawn', writer: 'one' })
  const [seenTwo] = (await two.poll()).changes
  const [seenThree] = (await three.poll()).changes
  if (!seenTwo || !seenThree) throw new Error('both sessions should see the change')
  const claims = await Promise.all([two.claim(seenTwo, 'notify'), three.claim(seenThree, 'notify')])
  expect(claims.filter(Boolean)).toHaveLength(1)
  expect(await two.claim(seenTwo, 'notify')).toBe(false)
  expect(await two.claim(seenTwo, 'another-hook')).toBe(true)
})

test('two different tasks change at the same moment and a third session observes both entries', async (_$, on) => {
  const { w, io, place } = await setup(on)
  const first = await newTask(io, place, 'First')
  const second = await newTask(io, place, 'Second')
  const third = observe(io, place, { id: 'third', root: '/repo' })
  await third.prime()
  const at = w.now
  await Promise.all([
    setStatus(io, place, { doc: first, status: 'done', source: 'pane', by: 'shawn', writer: 'one' }),
    setStatus(io, place, { doc: second, status: 'doing', source: 'tool', by: 'two', writer: 'two' }),
  ])
  expect(w.now).toBe(at)
  expect(entriesIn(w, place)).toHaveLength(2)
  const { changes } = await third.poll()
  expect(changes.map(one => `${one.doc}:${one.status}`).sort()).toEqual([`${first}:done`, `${second}:doing`].sort())
})

test('entries older than seven days are pruned on write, a poll after pruning still sees the new entry, and a session that missed pruned entries is told to reread', async (_$, on) => {
  const { w, io, place } = await setup(on)
  const old = await newTask(io, place, 'Old')
  const fresh = await newTask(io, place, 'Fresh')
  const steady = observe(io, place, { id: 'steady', root: '/repo' })
  const asleep = observe(io, place, { id: 'asleep', root: '/repo' })
  await steady.prime()
  await asleep.prime()
  await setStatus(io, place, { doc: old, status: 'done', source: 'pane', by: 'shawn', writer: 'one' })
  expect((await steady.poll()).changes).toHaveLength(1)
  w.now += 8 * DAY
  await setStatus(io, place, { doc: fresh, status: 'doing', source: 'pane', by: 'shawn', writer: 'one' })
  expect(entriesIn(w, place)).toHaveLength(1)
  const kept = await steady.poll()
  expect(kept.changes.map(one => one.doc)).toEqual([fresh])
  expect(kept.isGap).toBe(false)
  const woke = await asleep.poll()
  expect(woke.isGap).toBe(true)
  expect(woke.changes.map(one => one.doc)).toEqual([fresh])
})

test('a deliverable\'s status change in one worktree is not observed by a session in another worktree', async (_$, on) => {
  const { io, place } = await setup(on, { [SHIP]: SHIP_TEXT })
  const shared = await newTask(io, place, 'Shared')
  const main = observe(io, place, { id: 'main', root: '/repo' })
  const feature = observe(io, place, { id: 'feature', root: '/wt/feature' })
  await main.prime()
  await feature.prime()
  const featurePlace = await capturePlace(io, '/wt/feature')
  expect(featurePlace.key).toBe(place.key)
  await setStatus(io, featurePlace, { doc: SHIP, status: 'doing', source: 'pane', by: 'shawn', writer: 'feature', worktree: '/wt/feature' })
  await setStatus(io, place, { doc: shared, status: 'done', source: 'pane', by: 'shawn', writer: 'main' })
  expect((await feature.poll()).changes.map(one => `${one.doc}:${one.worktree ?? '-'}`)).toEqual([`${SHIP}:/wt/feature`, `${shared}:-`])
  expect((await main.poll()).changes.map(one => one.doc)).toEqual([shared])
})

test('no lock or staged file is ever written inside a working tree', async (_$, on) => {
  const { w, io, place } = await setup(on, { [SHIP]: SHIP_TEXT })
  const doc = await newTask(io, place, 'Somewhere safe')
  await setStatus(io, place, { doc, status: 'doing', source: 'pane', by: 'shawn', writer: 's1' })
  await setStatus(io, place, { doc: SHIP, status: 'done', source: 'tool', by: 's1', writer: 's1', worktree: '/wt/feature' })
  w.files[doc] = (w.files[doc] ?? '').replace('status: doing', 'status: done')
  await noticeReads(io, place, await listFolderTasks(io, place), 's2')
  const watcher = observe(io, place, { id: 'w', root: '/repo' })
  await watcher.prime()
  await setStatus(io, place, { doc, status: 'todo', source: 'pane', by: 'shawn', writer: 's1' })
  const [change] = (await watcher.poll()).changes
  if (!change) throw new Error('the watcher should see the change')
  expect(await watcher.claim(change, 'notify')).toBe(true)
  const allowed = new Set(['/repo/.peek/tasks', '/repo/.git/info', '/repo/.git/info/exclude'])
  const touched = w.log.flatMap(one => {
    if (one[0] === 'write') return [one[1] ?? '']
    if (one[1] === 'mkdir') return [one.at(-1) ?? '']
    if (one[1] === 'mv') return [one[3] ?? '']
    return []
  })
  expect(touched.length).toBeGreaterThan(5)
  expect(touched.filter(one => /^\/(repo|wt)\//.test(one) && !allowed.has(one))).toEqual([])
})

test('a stalled writer whose lock was broken and retaken cannot overwrite the newer status', async (_$, on) => {
  const { w, io, place } = await setup(on)
  const doc = await newTask(io, place, 'Contended')
  const lock = `${place.stateDir}/lock`
  w.onWrite = path => {
    if (!path.endsWith('.staged')) return
    w.onWrite = undefined
    delete w.files[`${lock}/owner`]
    w.dirs.delete(lock)
    w.dirs.set(lock, w.now)
    w.files[`${lock}/owner`] = 'the-other-session'
    w.files[doc] = (w.files[doc] ?? '').replace('status: todo', 'status: done')
  }
  w.log = []
  const outcome = await setStatus(io, place, { doc, status: 'doing', source: 'tool', by: 's1', writer: 's1' })
  expect(outcome.status).toBe('refused')
  expect(outcome.reason).toMatch(/busy/)
  expect(w.files[doc]).toMatch(/^status: done$/m)
  expect(w.log.some(one => one[1] === 'mv' && one[4] === doc)).toBe(false)
  expect(entriesIn(w, place)).toHaveLength(0)
  expect(w.files[`${lock}/owner`]).toBe('the-other-session')
})

test('a second entry landing within the same folder time as a poll that has not settled is still seen', async (_$, on) => {
  const { w, io, place } = await setup(on)
  const first = await newTask(io, place, 'First')
  const second = await newTask(io, place, 'Second')
  const watcher = observe(io, place, { id: 'watcher', root: '/repo' })
  await watcher.prime()
  const entries = `${place.stateDir}/entries`
  await setStatus(io, place, { doc: first, status: 'done', source: 'pane', by: 'shawn', writer: 'one' })
  const sameMtime = w.dirs.get(entries) ?? 0
  w.now = sameMtime
  expect((await watcher.poll()).changes.map(one => one.doc)).toEqual([first])
  await setStatus(io, place, { doc: second, status: 'done', source: 'pane', by: 'shawn', writer: 'one' })
  w.dirs.set(entries, sameMtime)
  expect(w.now).toBe(sameMtime)
  expect((await watcher.poll()).changes.map(one => one.doc)).toEqual([second])
})

test('once the entries folder has settled, a poll with its time unchanged neither lists nor reads it', async (_$, on) => {
  const { w, io, place } = await setup(on)
  const doc = await newTask(io, place, 'Quiet')
  const entries = `${place.stateDir}/entries`
  const listed: string[] = []
  const watcher = observe({ ...io, list: path => (listed.push(path), io.list(path)) }, place, { id: 'watcher', root: '/repo' })
  await watcher.prime()
  await setStatus(io, place, { doc, status: 'done', source: 'pane', by: 'shawn', writer: 'one' })
  w.now = w.dirs.get(entries) ?? 0
  expect((await watcher.poll()).changes.map(one => one.doc)).toEqual([doc])
  w.now += SETTLE_MS + 1
  expect((await watcher.poll()).changes).toEqual([])
  listed.length = 0
  w.reads.length = 0
  expect((await watcher.poll()).changes).toEqual([])
  expect([...listed, ...w.reads].filter(one => one.startsWith(entries))).toEqual([])
})
