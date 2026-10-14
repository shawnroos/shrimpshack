import { expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import type { Group } from '../types/groups'
import { readFrontmatter } from '../hooks/frontmatter'
import { listGroups, membersOf } from '../hooks/groups'
import type { GroupPlace } from '../hooks/groups'
import { ruleCandidates } from '../hooks/groups-session'
import type { NavIo } from '../hooks/navigation'
import { readListState } from '../hooks/mirror/records'
import { rebuildItems } from '../hooks/mirror/rebuild'
import { ARCHIVE_MS, createMirror } from '../hooks/mirror/watch'
import type { Mirror } from '../hooks/mirror/watch'
import { startTaskPoll } from '../hooks/tasks/poll'
import { capturePlace, createTask, listFolderTasks, userPlace } from '../hooks/tasks/store'
import type { TaskPlace, TasksIo } from '../hooks/tasks/store'
import { AGENT, AGENT_TWO, HOME, agentFolder, agentItem, agentTranscript, clearAgentList, deleteAgentItems, dirOf, fakeTimers, lockOnlyFolder, tasksWorld } from './fixtures/world'
import type { World } from './fixtures/world'

const MIRROR = `${HOME}/.local/share/claude-peek/mirror`
const REPO_GROUPS: GroupPlace = { dir: dirOf('/repo/.git'), projectKey: '/repo/.git' }
const record = (session: string, id: string) => `${MIRROR}/${session}/${id}.md`

type Setup = { w: World; io: TasksIo; mirror: Mirror; repo: TaskPlace }

async function setup(on: On, self = { id: AGENT, root: '/repo' }): Promise<Setup> {
  const { w, io } = tasksWorld(on)
  const mirror = createMirror(io, self)
  await mirror.noteStart()
  return { w, io, mirror, repo: await capturePlace(io, '/repo') }
}

const ANY_TASK: Group = { projectKey: '', id: 'tasks', title: 'Tasks', description: '', starred: false, updatedAt: 0, sections: [], items: [], removed: [], rule: {} }
const PLACED_NOWHERE = '11111111-2222-4333-8444-555555555555'
const propsAt = (w: World, path: string) => readFrontmatter(w.files[path] ?? '').props ?? {}
const navOf = (io: TasksIo) => ({ groupsIo: () => io, home: io.home }) as unknown as NavIo
const entriesIn = (w: World, place: TaskPlace) =>
  Object.entries(w.files)
    .filter(([path]) => path.startsWith(`${place.stateDir}/entries/`))
    .map(([, text]) => JSON.parse(text) as Record<string, unknown>)

async function mirroredNames(io: TasksIo, worktreeRoot?: string) {
  return (await ruleCandidates(navOf(io), [ANY_TASK], worktreeRoot)).filter(one => one.source === 'mirrored').map(one => one.name)
}

async function members(io: TasksIo) {
  const groups = await listGroups(io, REPO_GROUPS)
  const candidates = await ruleCandidates(navOf(io), groups, '/repo')
  return groups.map(group => {
    const paths = membersOf(group, candidates, '/repo').map(one => (one.ref.startsWith('file:') ? decodeURIComponent(new URL(one.ref).pathname) : `/repo/${one.ref}`))
    return { title: group.title, rule: group.rule, items: paths.flatMap(path => candidates.filter(one => one.href === path)) }
  })
}

test('an agent creating three items shows one group with three todo tasks in its session\'s repo', async (_$, on) => {
  const { w, io, mirror } = await setup(on)
  agentItem(w, AGENT, '1', 'Read the parser')
  agentItem(w, AGENT, '2', 'Fix the comma', 'pending', ['1'])
  agentItem(w, AGENT, '3', 'Run the tests', 'pending', ['2'])
  await mirror.poll()
  const groups = await members(io)
  expect(groups).toHaveLength(1)
  expect(groups[0]?.rule).toEqual({ list: `${AGENT}#1` })
  expect(groups[0]?.items.map(one => [one.name, one.props.status])).toEqual([
    ['Read the parser', 'todo'],
    ['Fix the comma', 'todo'],
    ['Run the tests', 'todo'],
  ])
  expect(propsAt(w, record(AGENT, '3')).sequence).toEqual({ after: [`${AGENT}/2`] })
  expect(propsAt(w, record(AGENT, '3')).creator).toBe(AGENT)
})

test('AE3: an agent sequence with every task done folds, then archives after the delay; Shawn\'s own done task never archives', async (_$, on) => {
  const { w, io, mirror, repo } = await setup(on)
  const own = await createTask(io, repo, { name: 'My own task', creator: 'shawn', status: 'done' })
  agentItem(w, AGENT, '1', 'Read the parser', 'completed')
  agentItem(w, AGENT, '2', 'Fix the comma', 'completed')
  await mirror.poll()
  expect((await readListState(io, AGENT))?.lists['1']?.phase).toBe('folded')
  expect(await listGroups(io, REPO_GROUPS)).toHaveLength(1)
  w.now += ARCHIVE_MS - 1
  await mirror.poll()
  expect(await listGroups(io, REPO_GROUPS)).toHaveLength(1)
  w.now += 2
  await mirror.poll()
  expect((await readListState(io, AGENT))?.lists['1']?.phase).toBe('archived')
  expect(await listGroups(io, REPO_GROUPS)).toHaveLength(0)
  expect(own.status === 'applied' && w.files[own.path]?.includes('status: done')).toBe(true)
  expect((await listFolderTasks(io, repo)).map(one => one.props.name)).toEqual(['My own task'])
})

test('a task that goes back to doing brings its archived group back', async (_$, on) => {
  const { w, io, mirror } = await setup(on)
  agentItem(w, AGENT, '1', 'Read the parser', 'completed')
  await mirror.poll()
  w.now += ARCHIVE_MS + 1
  await mirror.poll()
  expect(await listGroups(io, REPO_GROUPS)).toHaveLength(0)
  agentItem(w, AGENT, '1', 'Read the parser', 'in_progress')
  await mirror.poll()
  expect((await readListState(io, AGENT))?.lists['1']?.phase).toBe('active')
  expect((await members(io))[0]?.items.map(one => one.props.status)).toEqual(['doing'])
})

test('AE8: an ended session\'s open tasks read "session ended" and archive, while an adopted one stays in Shawn\'s list', async (_$, on) => {
  const { w, io, mirror, repo } = await setup(on)
  agentItem(w, AGENT, '1', 'Read the parser')
  agentItem(w, AGENT, '2', 'Fix the comma')
  agentItem(w, AGENT, '3', 'Run the tests')
  await mirror.poll()
  const adopted = await mirror.adopt(record(AGENT, '3'), 'shawn')
  expect(adopted.status).toBe('applied')
  await mirror.noteEnd(AGENT, 'prompt_input_exit')
  await mirror.poll()
  expect(propsAt(w, record(AGENT, '1')).session_ended).toBe(true)
  expect(propsAt(w, record(AGENT, '2')).session_ended).toBe(true)
  expect(propsAt(w, record(AGENT, '3')).session_ended).toBeUndefined()
  expect(await mirroredNames(io, '/repo')).toEqual(['Read the parser', 'Fix the comma'])
  w.now += ARCHIVE_MS + 1
  await mirror.poll()
  expect((await readListState(io, AGENT))?.lists['1']?.phase).toBe('archived')
  expect(await listGroups(io, REPO_GROUPS)).toHaveLength(0)
  expect(await mirroredNames(io, '/repo')).toEqual([])
  expect((await ruleCandidates(navOf(io), [ANY_TASK], '/repo')).map(one => one.name)).toEqual(['Run the tests'])
  const kept = await listFolderTasks(io, repo)
  expect(kept.map(one => [one.props.name, one.status, one.props.creator, one.props.adopted_by])).toEqual([['Run the tests', 'todo', AGENT, 'shawn']])
})

test('an ended session that comes back to work is no longer ended', async (_$, on) => {
  const { w, mirror } = await setup(on)
  agentItem(w, AGENT, '1', 'Read the parser')
  await mirror.poll()
  await mirror.noteEnd(AGENT, 'other')
  await mirror.poll()
  expect(propsAt(w, record(AGENT, '1')).session_ended).toBe(true)
  agentItem(w, AGENT, '2', 'Fix the comma')
  await mirror.poll()
  expect(propsAt(w, record(AGENT, '1')).session_ended).toBeUndefined()
})

test('a list cleared and recreated in the same folder starts a second group', async (_$, on) => {
  const { w, io, mirror } = await setup(on)
  agentItem(w, AGENT, '1', 'Read the parser', 'completed')
  agentItem(w, AGENT, '2', 'Fix the comma', 'completed')
  await mirror.poll()
  clearAgentList(w, AGENT, 2)
  await mirror.poll()
  agentItem(w, AGENT, '3', 'Write the docs')
  await mirror.poll()
  const groups = await members(io)
  expect(groups.map(one => one.rule?.list).sort()).toEqual([`${AGENT}#1`, `${AGENT}#2`])
  expect(groups.find(one => one.rule?.list === `${AGENT}#2`)?.items.map(one => one.name)).toEqual(['Write the docs'])
})

test('each mirrored record carries the list prop, and a reset raises its count', async (_$, on) => {
  const { w, mirror } = await setup(on)
  agentItem(w, AGENT, '19', 'Before the reset')
  await mirror.poll()
  expect(propsAt(w, record(AGENT, '19')).list).toBe(`${AGENT}#1`)
  clearAgentList(w, AGENT, 19)
  agentItem(w, AGENT, '20', 'After the reset')
  await mirror.poll()
  expect(propsAt(w, record(AGENT, '19')).list).toBe(`${AGENT}#1`)
  expect(propsAt(w, record(AGENT, '20')).list).toBe(`${AGENT}#2`)
})

test('a folder with only lock files, or a legacy session folder, creates no group', async (_$, on) => {
  const { w, io, mirror } = await setup(on)
  lockOnlyFolder(w, AGENT_TWO, 3)
  w.dirs.set(`${HOME}/.claude/tasks/session-f119dd80`, w.now)
  await mirror.poll()
  expect(await listGroups(io, REPO_GROUPS)).toHaveLength(0)
  expect(Object.keys(w.files).filter(one => one.startsWith(`${MIRROR}/${AGENT_TWO}/`))).toEqual([])
})

test('item files deleted by Claude Code leave the records at their last status', async (_$, on) => {
  const { w, io, mirror } = await setup(on)
  agentItem(w, AGENT, '1', 'Read the parser', 'completed')
  agentItem(w, AGENT, '2', 'Fix the comma', 'in_progress')
  await mirror.poll()
  deleteAgentItems(w, AGENT)
  await mirror.poll()
  expect([propsAt(w, record(AGENT, '1')).status, propsAt(w, record(AGENT, '2')).status]).toEqual(['done', 'doing'])
  expect((await members(io))[0]?.items).toHaveLength(2)
})

test('Shawn marks a mirrored item done, the agent then starts it, and the takeover doc shows in progress with both changes logged', async (_$, on) => {
  const { w, io, mirror, repo } = await setup(on)
  agentItem(w, AGENT, '1', 'Read the parser')
  await mirror.poll()
  const marked = await mirror.setStatus(record(AGENT, '1'), 'done', { by: 'shawn', source: 'pane' })
  expect(marked.status).toBe('applied')
  const [doc] = await listFolderTasks(io, repo)
  expect([doc?.status, doc?.props.creator, doc?.props.list, doc?.props.task_id]).toEqual(['done', AGENT, `${AGENT}#1`, '1'])
  agentItem(w, AGENT, '1', 'Read the parser')
  await mirror.poll()
  expect((await listFolderTasks(io, repo))[0]?.status).toBe('done')
  agentItem(w, AGENT, '1', 'Read the parser', 'in_progress')
  await mirror.poll()
  const [after] = await listFolderTasks(io, repo)
  expect(after?.status).toBe('doing')
  expect(entriesIn(w, repo).map(one => `${one.source}:${one.by}:${one.previous}->${one.status}`)).toEqual(['pane:shawn:todo->done', `mirror:${AGENT}:done->doing`])
  expect((await members(io))[0]?.items.map(one => [one.href, one.props.status])).toEqual([[after?.path, 'doing']])
})

test('a session with no peek hook record is placed by its conversation\'s working folder', async (_$, on) => {
  const { w, io, mirror } = await setup(on, { id: 'peek-elsewhere', root: '/other' })
  agentTranscript(w, '/repo', AGENT_TWO, [{ type: 'custom-title', sessionId: AGENT_TWO }, { type: 'user', cwd: '/repo', sessionId: AGENT_TWO }])
  agentItem(w, AGENT_TWO, '1', 'Placed by its transcript')
  await mirror.poll()
  expect((await members(io)).map(one => one.items.map(item => item.name))).toEqual([['Placed by its transcript']])
})

test('two sessions polling the same task folder log one entry when an item completes', async (_$, on) => {
  const { w, io, mirror, repo } = await setup(on)
  const other = createMirror(io, { id: 'session-two', root: '/wt/feature' })
  agentItem(w, AGENT, '1', 'Read the parser')
  await Promise.all([mirror.poll(), other.poll()])
  agentItem(w, AGENT, '1', 'Read the parser', 'completed')
  await Promise.all([mirror.poll(), other.poll()])
  const entries = entriesIn(w, repo)
  expect(entries.map(one => [one.doc, one.status, one.source, one.worktree])).toEqual([[record(AGENT, '1'), 'done', 'mirror', undefined]])
})

test('R21: a list whose files are already gone is rebuilt from its saved conversation, best effort', async (_$, on) => {
  const { w, io, mirror } = await setup(on, { id: 'peek-elsewhere', root: '/other' })
  const lines = [
    { type: 'user', cwd: '/repo', sessionId: AGENT_TWO },
    { type: 'assistant', message: { content: [{ type: 'tool_use', id: 'tu1', name: 'TaskCreate', input: { subject: 'Rebuilt one', description: 'x' } }] } },
    { type: 'user', toolUseResult: { task: { id: '1', subject: 'Rebuilt one' } }, message: { content: [{ type: 'tool_result', tool_use_id: 'tu1', content: 'Task #1 created successfully: Rebuilt one' }] } },
    { type: 'assistant', message: { content: [{ type: 'tool_use', id: 'tu2', name: 'TaskUpdate', input: { taskId: '1', status: 'in_progress' } }] } },
  ]
  expect(rebuildItems(lines.map(one => JSON.stringify(one)).join('\n')).map(one => [one.id, one.subject, one.status])).toEqual([['1', 'Rebuilt one', 'in_progress']])
  agentTranscript(w, '/repo', AGENT_TWO, lines)
  lockOnlyFolder(w, AGENT_TWO, 1)
  await mirror.poll()
  expect((await members(io)).map(one => one.items.map(item => [item.name, item.props.status]))).toEqual([[['Rebuilt one', 'doing']]])
  expect(w.files[`${agentFolder(AGENT_TWO)}/1.json`]).toBeUndefined()
})

test('the light poll mirrors a list within one tick, and a same-session nudge mirrors it at once', async (_$, on) => {
  const { w, io } = tasksWorld(on)
  const timers = fakeTimers(w)
  const session = await startTaskPoll({ ...io, every: timers.every, isActive: async () => true }, { id: AGENT, root: '/repo' })
  agentItem(w, AGENT, '1', 'Seen on the tick')
  timers.advance(3_000)
  await session.polled(1)
  expect((await members(io)).map(one => one.items.map(item => item.name))).toEqual([['Seen on the tick']])
  agentItem(w, AGENT, '2', 'Seen on the nudge')
  session.nudge()
  await session.polled(2)
  expect((await members(io)).map(one => one.items.map(item => item.name))).toEqual([['Seen on the tick', 'Seen on the nudge']])
})

test('with more session folders than the cap, the newest ones are followed and their records stay rule candidates', async (_$, on) => {
  const { w, io, mirror } = await setup(on)
  for (let i = 0; i < 70; i++) {
    const old = `00000000-0000-4000-8000-${String(i).padStart(12, '0')}`
    w.files[`${MIRROR}/${old}/session.json`] = '{}'
    w.touch(`${MIRROR}/${old}/session.json`)
  }
  agentItem(w, AGENT, '1', 'Newest list')
  await mirror.poll()
  expect((await members(io)).map(one => one.items.map(item => item.name))).toEqual([['Newest list']])
})

test('R21: a list shows only in the repo its session ran in, an unplaced one only in the user-level list, and a moved one in its new repo', async (_$, on) => {
  const { w, io, mirror } = await setup(on)
  agentTranscript(w, '/other', AGENT_TWO, [{ type: 'user', cwd: '/other', sessionId: AGENT_TWO }])
  agentItem(w, AGENT, '1', 'In this repo')
  agentItem(w, AGENT_TWO, '1', 'In the other repo')
  agentItem(w, PLACED_NOWHERE, '1', 'Placed nowhere')
  await mirror.poll()
  expect(await mirroredNames(io, '/repo')).toEqual(['In this repo'])
  expect(await mirroredNames(io, '/wt/feature')).toEqual(['In this repo'])
  expect(await mirroredNames(io, '/other')).toEqual(['In the other repo'])
  expect(await mirroredNames(io)).toEqual(['Placed nowhere'])
  await mirror.moveList(AGENT, '/other')
  expect(await mirroredNames(io, '/repo')).toEqual([])
  expect((await mirroredNames(io, '/other')).sort()).toEqual(['In the other repo', 'In this repo'])
})

test('a list recorded before lists kept their repo, whose task folder is gone, is placed from its session note', async (_$, on) => {
  const { w, io, mirror } = await setup(on)
  w.files[`${MIRROR}/${AGENT_TWO}/session.json`] = JSON.stringify({ root: '/other' })
  w.files[`${MIRROR}/${AGENT_TWO}/state.json`] = JSON.stringify({ count: 1, watermark: 0, isCleared: false, lists: { 1: { phase: 'folded', foldedAt: w.now } } })
  w.files[record(AGENT_TWO, '1')] = `---\nname: "Old list item"\nid: "${AGENT_TWO}/1"\nstatus: "done"\nlist: "${AGENT_TWO}#1"\n---\n`
  w.touch(record(AGENT_TWO, '1'))
  expect(await mirroredNames(io, '/other')).toEqual([])
  await mirror.poll()
  expect(await mirroredNames(io, '/other')).toEqual(['Old list item'])
  expect(await mirroredNames(io, '/repo')).toEqual([])
})

test('a list moved by one session stays in its new repo when another session later folds it', async (_$, on) => {
  const { w, io, mirror, repo } = await setup(on)
  const other = createMirror(io, { id: 'session-two', root: '/wt/feature' })
  agentItem(w, AGENT, '1', 'Read the parser')
  await mirror.poll()
  agentItem(w, AGENT, '1', 'Read the parser', 'in_progress')
  await other.poll()
  await mirror.moveList(AGENT, '/other')
  agentItem(w, AGENT, '1', 'Read the parser', 'completed')
  await other.poll()
  expect((await readListState(io, AGENT))?.lists['1']?.phase).toBe('folded')
  expect((await readListState(io, AGENT))?.placeKey).toBe('/other/.git')
  expect(await mirroredNames(io, '/other')).toEqual(['Read the parser'])
  expect(await mirroredNames(io, '/repo')).toEqual([])
  expect(entriesIn(w, repo).map(one => one.status)).toEqual(['doing'])
  expect(entriesIn(w, await capturePlace(io, '/other')).map(one => one.status)).toEqual(['done'])
})

test('an item adopted in one session gets the agent\'s next change through another session', async (_$, on) => {
  const { w, io, mirror, repo } = await setup(on)
  const other = createMirror(io, { id: 'session-two', root: '/wt/feature' })
  agentItem(w, AGENT, '1', 'Read the parser')
  await mirror.poll()
  await other.poll()
  expect((await mirror.adopt(record(AGENT, '1'), 'shawn')).status).toBe('applied')
  agentItem(w, AGENT, '1', 'Read the parser', 'in_progress')
  await other.poll()
  expect((await listFolderTasks(io, repo)).map(one => one.status)).toEqual(['doing'])
  expect(propsAt(w, record(AGENT, '1')).status).toBe('todo')
})

test('R21: an item moved to the user-level list still follows the agent\'s later changes', async (_$, on) => {
  const { w, io, mirror } = await setup(on)
  agentItem(w, AGENT, '1', 'Read the parser')
  await mirror.poll()
  const user = await userPlace(io)
  expect((await mirror.adopt(record(AGENT, '1'), 'shawn', user)).status).toBe('applied')
  agentItem(w, AGENT, '1', 'Read the parser', 'completed')
  await mirror.poll()
  expect((await listFolderTasks(io, user)).map(one => one.status)).toEqual(['done'])
})

test('a poll after this session wrote a list\'s state does not read that state back', async (_$, on) => {
  const { w, mirror } = await setup(on)
  agentItem(w, AGENT, '1', 'Read the parser')
  await mirror.poll()
  agentItem(w, AGENT, '1', 'Read the parser', 'completed')
  await mirror.poll()
  w.reads.length = 0
  await mirror.poll()
  expect(w.reads.filter(one => one.endsWith('/state.json'))).toEqual([])
})
