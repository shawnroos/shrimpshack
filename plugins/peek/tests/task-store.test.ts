import { expect, test } from 'claude-code/testing'

import { readFrontmatter } from '../hooks/frontmatter'
import { capturePlace, createTask, listFolderTasks } from '../hooks/tasks/store'
import { setStatus } from '../hooks/tasks/status'
import type { StatusChange } from '../hooks/tasks/status'
import { startTaskPoll } from '../hooks/tasks/poll'
import type { TaskSession, TaskSessionIo } from '../hooks/tasks/poll'
import type { TasksIo } from '../hooks/tasks/store'
import { fakeTimers, tasksWorld } from './fixtures/world'
import type { Timers } from './fixtures/world'

const EXCLUDE = '/repo/.git/info/exclude'
const SHIP = '/repo/docs/ship.md'

function sessionIo(io: TasksIo, timers: Timers, isActive: () => boolean = () => true): TaskSessionIo {
  return { ...io, every: timers.every, isActive: async () => isActive() }
}

// One poll period at a time, waiting for each poll's work before the next tick fires.
async function runPolls(session: TaskSession, timers: Timers, from: number, count: number) {
  for (let n = from + 1; n <= from + count; n++) {
    timers.advance(3_000)
    await session.polled(n)
  }
}

test('AE2: a task captured in a feature worktree lands in the main checkout\'s folder and survives the worktree\'s removal', async (_$, on) => {
  const { w, io } = tasksWorld(on, { '/wt/feature/README.md': '# Feature\n' })
  const made = await createTask(io, await capturePlace(io, '/wt/feature'), { name: 'Follow up on the export bug', creator: 'session-7' })
  if (made.status !== 'applied') throw new Error(made.reason)
  expect(made.path.startsWith('/repo/.peek/tasks/')).toBe(true)
  for (const path of Object.keys(w.files)) if (path.startsWith('/wt/feature/')) delete w.files[path]
  delete w.commonDirs['/wt/feature']
  const tasks = await listFolderTasks(io, await capturePlace(io, '/repo'))
  expect(tasks.map(one => one.props.name)).toEqual(['Follow up on the export bug'])
  expect(tasks[0]?.props).toEqual({ name: 'Follow up on the export bug', id: made.id, status: 'todo', creator: 'session-7' })
  expect(tasks[0]?.status).toBe('todo')
})

test('the first write adds .peek/ to the repo\'s exclude list once and never touches .gitignore', async (_$, on) => {
  const { w, io } = tasksWorld(on, { [EXCLUDE]: '# local ignores\n*.log\n', '/repo/.gitignore': 'node_modules/\n' })
  const place = await capturePlace(io, '/wt/feature')
  await createTask(io, place, { name: 'One', creator: 'shawn' })
  await createTask(io, place, { name: 'Two', creator: 'shawn' })
  expect(w.files[EXCLUDE]).toBe('# local ignores\n*.log\n.peek/\n')
  expect(w.files['/repo/.gitignore']).toBe('node_modules/\n')
  expect(w.log.some(one => one.some(part => part.includes('.gitignore')))).toBe(false)
})

test('a task captured outside any git repo goes to the user-level folder', async (_$, on) => {
  const { w, io } = tasksWorld(on)
  const place = await capturePlace(io, '/scratch')
  expect(place.isUser).toBe(true)
  const made = await createTask(io, place, { name: 'Call the bank', creator: 'shawn' })
  if (made.status !== 'applied') throw new Error(made.reason)
  expect(made.path.startsWith('/home/.local/share/claude-peek/tasks/')).toBe(true)
  expect(readFrontmatter(w.files[made.path] ?? '').props).toEqual({ name: 'Call the bank', id: made.id, status: 'todo', creator: 'shawn' })
  expect(w.log.some(one => one.some(part => part.includes('exclude')))).toBe(false)
})

test('a doc gaining isTask: true joins the session\'s tasks after the next refresh tick, and only from the session\'s own worktree', async (_$, on) => {
  const { w, io } = tasksWorld(on, { [SHIP]: '# Ship\n', '/wt/feature/docs/other.md': '---\nisTask: true\n---\n' })
  w.tracked = { '/repo': ['docs/plan.md', 'docs/ship.md'], '/wt/feature': ['docs/other.md'] }
  const timers = fakeTimers(w)
  const session = await startTaskPoll(sessionIo(io, timers), { id: 's1', root: '/repo' })
  expect(session.index.docs()).toEqual([])
  w.files[SHIP] = '---\nisTask: true\nname: Ship it\n---\n# Ship\n'
  w.touch(SHIP)
  await runPolls(session, timers, 0, 4)
  expect(session.index.docs()).toEqual([])
  await runPolls(session, timers, 4, 1)
  await session.refreshed(1)
  expect(session.index.docs().map(one => `${one.path}:${one.worktree}`)).toEqual([`${SHIP}:/repo`])
})

test('the light poll keeps running while the person is idle and delivers another session\'s change to subscribers once', async (_$, on) => {
  const { w, io } = tasksWorld(on)
  w.tracked = { '/repo': [] }
  const place = await capturePlace(io, '/repo')
  const made = await createTask(io, place, { name: 'Watched', creator: 'shawn' })
  if (made.status !== 'applied') throw new Error(made.reason)
  const timers = fakeTimers(w)
  const session = await startTaskPoll(sessionIo(io, timers, () => false), { id: 's1', root: '/repo' })
  const seen: StatusChange[] = []
  session.observers[0]?.subscribe(batch => seen.push(...batch.changes))
  await setStatus(io, place, { doc: made.path, status: 'done', source: 'tool', by: 's2', writer: 's2' })
  await runPolls(session, timers, 0, 1)
  expect(seen.map(one => `${one.writer}:${one.status}`)).toEqual(['s2:done'])
  await runPolls(session, timers, 1, 5)
  expect(seen).toHaveLength(1)
})

test('the light poll reads a deliverable whose timestamp moved and logs its direct edit once', async (_$, on) => {
  const { w, io } = tasksWorld(on, { [SHIP]: '---\nisTask: true\nstatus: todo\n---\n' })
  w.tracked = { '/repo': ['docs/ship.md'] }
  const timers = fakeTimers(w)
  const session = await startTaskPoll(sessionIo(io, timers), { id: 's1', root: '/repo' })
  const seen: StatusChange[] = []
  session.observers[0]?.subscribe(batch => seen.push(...batch.changes))
  w.files[SHIP] = '---\nisTask: true\nstatus: done\n---\n'
  w.touch(SHIP)
  await runPolls(session, timers, 0, 2)
  expect(seen.map(one => `${one.source}:${one.doc}:${one.previous}->${one.status}:${one.worktree}`)).toEqual([`direct:${SHIP}:todo->done:/repo`])
})

test('a session started in a folder inside the worktree indexes and observes as the worktree\'s top', async (_$, on) => {
  const { w, io } = tasksWorld(on, { [SHIP]: '---\nisTask: true\nstatus: todo\n---\n' })
  w.tracked = { '/repo': ['docs/ship.md'] }
  const session = await startTaskPoll(sessionIo(io, fakeTimers(w)), { id: 's1', root: '/repo/docs' })
  expect(session.root).toBe('/repo')
  expect(session.index.docs().map(one => `${one.path}:${one.worktree}`)).toEqual([`${SHIP}:/repo`])
})

test('while the person is idle the light poll finds a task another session captured, so a later direct edit to it is logged', async (_$, on) => {
  const { w, io } = tasksWorld(on)
  w.tracked = { '/repo': [] }
  const timers = fakeTimers(w)
  const session = await startTaskPoll(sessionIo(io, timers, () => false), { id: 's1', root: '/repo' })
  const seen: StatusChange[] = []
  session.observers[0]?.subscribe(batch => seen.push(...batch.changes))
  await runPolls(session, timers, 0, 1)
  const made = await createTask(io, await capturePlace(io, '/wt/feature'), { name: 'Made elsewhere', creator: 's2' })
  if (made.status !== 'applied') throw new Error(made.reason)
  await runPolls(session, timers, 1, 1)
  w.files[made.path] = (w.files[made.path] ?? '').replace('status: todo', 'status: doing')
  w.touch(made.path)
  await runPolls(session, timers, 2, 2)
  expect(seen.map(one => `${one.source}:${one.doc}:${one.previous}->${one.status}`)).toEqual([`direct:${made.path}:todo->doing`])
})
