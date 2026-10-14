import { expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { readFrontmatter } from '../hooks/frontmatter'
import { startTaskPoll } from '../hooks/tasks/poll'
import type { TaskSession } from '../hooks/tasks/poll'
import { AGENT, HOME, agentItem, call, dirOf, fakeTimers, jsonOf, tasksWorld } from './fixtures/world'
import type { World } from './fixtures/world'

const TASKS = '/repo/.peek/tasks'
const USER_TASKS = `${HOME}/.local/share/claude-peek/tasks`
const MIRROR = `${HOME}/.local/share/claude-peek/mirror`
const SELF = 'groups-pane'

const doc = (props: Record<string, string>, body = '') => ['---', ...Object.entries(props).map(([key, value]) => `${key}: ${value}`), '---', body].join('\n')

const ESC = { [`${TASKS}/esc.md`]: doc({ name: '"Esc work"', id: 'esc1', status: 'doing', creator: 'shawn' }) }

// The tools reach the mirror through this module's task session, as the pane does, so each test starts one on its
// own world rather than through session.start, which would keep the first test's world for the whole file.
async function started(on: On, files: Record<string, string> = {}): Promise<World & { session: TaskSession }> {
  const { w, io } = tasksWorld(on, files)
  const session = await startTaskPoll({ ...io, every: fakeTimers(w).every, isActive: async () => true }, { id: SELF, root: '/repo' })
  return Object.assign(w, { session })
}

const propsAt = (w: World, path: string) => readFrontmatter(w.files[path] ?? '').props ?? {}
const docsIn = (w: World, folder: string) => Object.keys(w.files).filter(path => path.startsWith(`${folder}/`) && path.endsWith('.md'))
const groupFiles = (w: World, projectKey: string) => Object.keys(w.files).filter(path => path.startsWith(`${dirOf(projectKey)}/`) && path.endsWith('.json'))

test('covers F1: save_task with a name, after another task and on_behalf person writes a todo doc with that sequence, Shawn as creator and the calling session', async ($, on) => {
  const w = await started(on, ESC)
  const text = await call($, 'save_task', { name: 'Fix the crumb hover', sequence: { after: 'esc1' }, on_behalf: 'person' })
  expect(text.split('\n')[0]).toMatch(/^Saved task "Fix the crumb hover" \([0-9a-z]{8}\)/)
  const made = docsIn(w, TASKS).filter(path => !path.endsWith('/esc.md'))
  expect(made).toHaveLength(1)
  const props = propsAt(w, made[0] ?? '')
  expect([props.name, props.status, props.creator, props.session]).toEqual(['Fix the crumb hover', 'todo', 'shawn', SELF])
  expect(props.sequence).toEqual({ after: 'esc1' })
  expect(jsonOf(text).path).toBe(made[0])
})

test('a free-form creator is ignored, and an on_behalf self task is created by the session, so it does not pin in Recent as Shawn\'s', async ($, on) => {
  const w = await started(on)
  await call($, 'save_task', { name: 'Read the parser', on_behalf: 'self', creator: 'shawn' })
  await call($, 'save_task', { name: 'Ask about dates', on_behalf: 'person', creator: 'someone-else' })
  const byName = Object.fromEntries(docsIn(w, TASKS).map(path => [propsAt(w, path).name, propsAt(w, path).creator]))
  expect(byName).toEqual({ 'Read the parser': SELF, 'Ask about dates': 'shawn' })
})

test('save_task with an id changes props and status; the status goes through the status log as a tool change', async ($, on) => {
  const w = await started(on, ESC)
  const text = await call($, 'save_task', { id: 'esc1', status: 'done', due: '2026-11-02', attachments: ['docs/plan.md'], description: 'Done in the Esc pass.' })
  expect(text.split('\n')[0]).toMatch(/^Saved task "Esc work" \(esc1\)/)
  const props = propsAt(w, `${TASKS}/esc.md`)
  expect([props.status, props.due, props.attachments, props.creator]).toEqual(['done', '2026-11-02', ['docs/plan.md'], 'shawn'])
  expect(w.files[`${TASKS}/esc.md`]).toContain('Done in the Esc pass.')
  const logged = Object.entries(w.files).filter(([path]) => path.includes('/task-log/') && path.includes('/entries/')).map(([, one]) => JSON.parse(one))
  expect(logged.map(one => [one.status, one.previous, one.source, one.by])).toEqual([['done', 'doing', 'tool', SELF]])
})

test('list_tasks and read_task return tasks with their props, filtered by status and creator', async ($, on) => {
  await started(on, { ...ESC, [`${TASKS}/b.md`]: doc({ name: '"Second"', id: 'b2', status: 'todo', creator: SELF }, 'Body two.') })
  const all = jsonOf(await call($, 'list_tasks', {})) as { tasks: { id: string; name: string; status: string }[] }
  expect(all.tasks.map(one => one.id).sort()).toEqual(['b2', 'esc1'])
  const mine = jsonOf(await call($, 'list_tasks', { creator: 'person' })) as { tasks: { id: string }[] }
  expect(mine.tasks.map(one => one.id)).toEqual(['esc1'])
  const open = jsonOf(await call($, 'list_tasks', { status: 'todo' })) as { tasks: { id: string }[] }
  expect(open.tasks.map(one => one.id)).toEqual(['b2'])
  const read = await call($, 'read_task', { id: 'b2' })
  expect(read.split('\n')[0]).toBe('Task "Second" (b2): todo.')
  expect(jsonOf(read)).toMatchObject({ id: 'b2', path: `${TASKS}/b.md`, props: { creator: SELF }, body: 'Body two.' })
})

test('move_tasks into Shawn\'s list adopts a mirrored item as a takeover doc keeping its id', async ($, on) => {
  const record = `${MIRROR}/s9/3.md`
  const recordDoc = doc({ name: '"Left over"', id: 's9/3', status: 'todo', list: '"s9#1"', creator: 's9', session: 's9', task_id: '"3"', agent_status: 'pending', session_ended: 'true' })
  const w = await started(on, { [record]: recordDoc, [`${MIRROR}/s9/session.json`]: JSON.stringify({ root: '/repo', endedAt: 1 }) })
  const text = await call($, 'move_tasks', { tasks: ['s9/3'], to: 'mine' })
  expect(text.split('\n')[0]).toMatch(/^Moved 1 task to \/repo\/\.peek\/tasks/)
  const taken = docsIn(w, TASKS)
  expect(taken).toHaveLength(1)
  const props = propsAt(w, taken[0] ?? '')
  expect([props.name, props.mirror, props.creator, props.status]).toEqual(['Left over', 's9/3', 's9', 'todo'])
  expect(propsAt(w, record).takeover).toBe(taken[0])
  w.files[`${MIRROR}/s9/4.md`] = recordDoc.replace('s9/3', 's9/4').replace('"3"', '"4"').replace('Left over', 'Elsewhere')
  expect((await call($, 'move_tasks', { tasks: ['s9/4'], to: '/other' })).split('\n')[0]).toMatch(/^Moved 1 task to \/other\/\.peek\/tasks/)
  expect(docsIn(w, '/other/.peek/tasks').map(path => propsAt(w, path).mirror)).toEqual(['s9/4'])
})

test('move_tasks moves a mirrored list to another repo, then to the user-level list', async ($, on) => {
  const w = await started(on, { [`${MIRROR}/${AGENT}/session.json`]: JSON.stringify({ root: '/repo' }) })
  const mirror = w.session.mirror
  agentItem(w, AGENT, '1', 'Read the parser')
  await mirror.poll()
  expect(groupFiles(w, '/repo/.git')).toHaveLength(1)

  const moved = await call($, 'move_tasks', { list: `${AGENT}#1`, to: '/other' })
  expect(moved.split('\n')[0]).toBe(`Moved list ${AGENT}#1 to /other/.peek/tasks.`)
  expect(groupFiles(w, '/repo/.git')).toHaveLength(0)
  expect(groupFiles(w, '/other/.git')).toHaveLength(1)
  await mirror.poll()
  expect(groupFiles(w, '/repo/.git')).toHaveLength(0)
  await call($, 'save_task', { id: `${AGENT}/1`, status: 'doing' })
  expect(docsIn(w, '/other/.peek/tasks').map(path => propsAt(w, path).name)).toEqual(['Read the parser'])

  agentItem(w, AGENT, '2', 'Fix the comma')
  // A home folder can itself be a repo, so the user-level list must never be placed by asking git.
  w.commonDirs[USER_TASKS] = '/home/.git'
  const toUser = await call($, 'move_tasks', { list: `${AGENT}#1`, to: 'user' })
  expect(toUser.split('\n')[0]).toBe(`Moved list ${AGENT}#1 to ${USER_TASKS}.`)
  expect(groupFiles(w, '/other/.git')).toHaveLength(0)
  await mirror.poll()
  await call($, 'save_task', { id: `${AGENT}/2`, status: 'doing' })
  expect(docsIn(w, USER_TASKS).map(path => propsAt(w, path).name)).toEqual(['Fix the comma'])
})

const BAD_VIEW = ['---', 'type: Not A Name', 'match: { folder: notes }', 'props:', '  due: { kind: when }', '---', '# {{name}}', ''].join('\n')
const GOOD_VIEW = ['---', 'type: note', 'match: { folder: notes }', 'props:', '  due: { kind: date }', '---', '# {{name}}', ''].join('\n')

test('check_view reports a definition\'s problems without loading it', async ($, on) => {
  const w = await started(on, { '/repo/notes/view.md': BAD_VIEW })
  const fromFile = await call($, 'check_view', { path: 'notes/view.md' })
  expect(fromFile.split('\n')[0]).toBe('/repo/notes/view.md has 2 problems; peek would not load it.')
  const problems = jsonOf(fromFile).problems as string[]
  expect(problems).toHaveLength(2)
  expect(problems[0]).toMatch(/^\/repo\/notes\/view\.md: type /)
  expect(problems[1]).toMatch(/^\/repo\/notes\/view\.md: props\.due\b/)
  expect(await call($, 'check_view', { text: GOOD_VIEW })).toBe('The definition of "note" has no problems.')
  const views = `${HOME}/.local/share/claude-peek/views`
  expect(Object.keys(w.files).some(path => path.startsWith(`${views}/`))).toBe(false)
})

test('check_view reports a type another definition already uses, since neither would load', async (_$, on) => {
  const views = `${HOME}/.local/share/claude-peek/views`
  await started(on, { [`${views}/note.md`]: GOOD_VIEW })
  const text = await call(_$, 'check_view', { text: GOOD_VIEW.replace('folder: notes', 'folder: other') })
  expect(text.split('\n')[0]).toBe('The definition has 1 problem; peek would not load it.')
  expect(jsonOf(text).problems).toEqual([`The definition: type "note" is also defined by ${views}/note.md; neither would load`])
})

test('invalid task input returns a one-line reason and changes nothing', async ($, on) => {
  const w = await started(on, ESC)
  const before = JSON.stringify(w.files)
  const cases: [string, Record<string, unknown>, string][] = [
    ['save_task', { on_behalf: 'person' }, 'Give a name to create a task, or an id to change one.'],
    ['save_task', { name: 'A', on_behalf: 'shawn' }, 'on_behalf is person (a task Shawn asked for) or self (your own work).'],
    ['save_task', { name: 'A', on_behalf: 'self', status: 'blocked' }, 'status is one of todo, doing, done, cancelled.'],
    ['save_task', { name: 'A', on_behalf: 'self', due: 'next week' }, 'due is a date like 2026-11-02.'],
    ['save_task', { name: 'A', on_behalf: 'self', sequence: { after: 'nope' } }, 'No task nope; use an id from list_tasks.'],
    ['save_task', { name: 'A', on_behalf: 'self', sequence: { soon: 'esc1' } }, 'sequence is { after, before, with }, each a task id or a list of them.'],
    ['save_task', { name: 'A', on_behalf: 'self', parent: 'nope' }, 'No task nope; use an id from list_tasks.'],
    ['save_task', { name: 'A', on_behalf: 'self', attachments: 'docs/plan.md' }, 'attachments is a list of file paths or URLs.'],
    ['save_task', { id: 'nope', status: 'done' }, 'No task nope; use an id from list_tasks.'],
    ['save_task', { name: 'x'.repeat(201), on_behalf: 'self' }, 'A task name holds at most 200 characters.'],
    ['read_task', { id: 'nope' }, 'No task nope; use an id from list_tasks.'],
    ['move_tasks', { tasks: ['esc1'] }, 'to is mine, user, or a folder inside a git repo.'],
    ['move_tasks', { tasks: ['esc1'], to: '/nowhere' }, '/nowhere is not inside a git repo; use user for the user-level list.'],
    ['move_tasks', { to: 'user' }, 'Give tasks (ids) or a list (session#n) to move.'],
    ['move_tasks', { list: 'not-a-list', to: 'user' }, 'not-a-list is not a list; a list is <session id>#<n> from list_tasks.'],
    ['check_view', {}, 'Give a path to a definition file, or its text.'],
  ]
  for (const [tool, input, message] of cases) expect([tool, input, await call($, tool, input)]).toEqual([tool, input, message])
  expect(JSON.stringify(w.files)).toBe(before)
})
