import { describe, expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { cycleLayoutOfRow, getPlace, noteRow, onPlaceChange, setPlace } from '../hooks/pane/blocks/common'
import { canAdopt, wirePlaces } from '../hooks/pane/actions'
import { readFrontmatter } from '../hooks/frontmatter'
import { recordText, withProp } from '../hooks/mirror/records'
import { fillTemplate } from '../hooks/views/fill'
import { readDefinition } from '../hooks/views/definition'
import type { Item } from '../hooks/views/items'
import { MIRROR_ROOT, PANE_PROPS, call, fakeFs, mirrorListState } from './fixtures/world'
import type { World } from './fixtures/world'

const FENCE = '```'

// A copy of views/task.md: a test cannot read the plugin's own folder, so it seeds this one in the user views folder,
// which the registry reads the same way. It must track the real file.
const TASK_VIEW = [
  '---',
  'type: task',
  'match: { folder: .peek/tasks, prop: isTask, equals: true }',
  'props:',
  '  id:          { kind: text, required: true }',
  '  status:      { kind: choice, values: [todo, doing, done, cancelled], required: true }',
  '  creator:     { kind: text, required: true }',
  '  parent:      { kind: ref }',
  '  sequence:    { kind: ref }',
  '  due:         { kind: date }',
  '  attachments: { kind: links }',
  'requires_when: { isTask: true, all: true }',
  'layout_default: { page: tree, group: list }',
  '---',
  '# {{name}}',
  '',
  '| Prop | Value |',
  '|---|---|',
  '| Status | {{status}} |',
  '| Created by | {{creator}} |',
  '| Due | {{due}} |',
  '| Parent | {{parent}} |',
  '| Attachments | {{attachments}} |',
  '',
  '{{description}}',
  '',
  '## Children',
  '',
  `${FENCE}peek-tree ancestors={{id}}`,
  FENCE,
  '',
  '## Sequence',
  '',
  `${FENCE}peek-list neighbours={{id}}`,
  FENCE,
  '',
].join('\n')

const TASKS = '/repo/.peek/tasks'

function doc(props: Record<string, string>, body = '') {
  return ['---', ...Object.entries(props).map(([key, value]) => `${key}: ${value}`), '---', body].join('\n')
}

const FAMILY = {
  [`${TASKS}/p.md`]: doc({ name: '"Ship the export"', id: 'p', status: 'doing', creator: 'shawn' }, 'The body of the export task.'),
  [`${TASKS}/c1.md`]: doc({ name: '"Child one"', id: 'c1', status: 'todo', creator: 'shawn', parent: 'p' }),
  [`${TASKS}/g1.md`]: doc({ name: '"Grandchild"', id: 'g1', status: 'todo', creator: 'shawn', parent: 'c1' }),
  [`${TASKS}/c2.md`]: doc({ name: '"Child two"', id: 'c2', status: 'done', creator: 'session-7', parent: 'p' }),
  [`${TASKS}/n1.md`]: doc({ name: '"Next step"', id: 'n1', status: 'todo', creator: 'shawn', sequence: '{ after: p }' }),
  [`${TASKS}/o.md`]: doc({ name: '"Unrelated"', id: 'o', status: 'todo', creator: 'session-7' }),
}

const USER_VIEWS = '/home/.local/share/claude-peek/views'

function taskWorld(on: On, files: Record<string, string>, view = TASK_VIEW): World {
  return fakeFs(on, { [`${USER_VIEWS}/task.md`]: view, ...files })
}

type Mounted = Awaited<ReturnType<typeof mount>>

async function mount($: Parameters<typeof call>[0] & { ui: { mount: (input: never) => Promise<unknown> } }) {
  return (await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: PANE_PROPS, requestId: 'peek' } as never)) as {
    press: (q: { key: string }) => Promise<unknown>
    redraw: () => Promise<unknown>
    drawn: () => Promise<unknown>
    find: (q: { type?: string; key?: string; text?: string | RegExp }) => Promise<{ props: Record<string, unknown>; text: string } | undefined>
    input: (q: { key: string; text: string; kind?: 'change' | 'submit' }) => Promise<unknown>
    unmount: () => Promise<void>
  }
}

const settle = async () => {
  for (let i = 0; i < 50; i++) await Promise.resolve()
}

async function drawnText(ui: Mounted) {
  await settle()
  await ui.redraw()
  return JSON.stringify(await ui.drawn())
}

async function menuPress(ui: Mounted, $: { command: { run: (input: never) => Promise<unknown> } }, label: string) {
  await $.command.run({ command: 'peek-menu' } as never)
  await ui.redraw()
  await ui.input({ key: 'menu-filter', text: label, kind: 'change' })
  const row = await ui.find({ type: 'Button', text: new RegExp(`^${label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`) })
  expect(row).toBeDefined()
  await ui.press({ key: String(row?.props.key) })
  await settle()
}

const openPeek = (path: string) => ({ command: 'peek', args: path }) as never

describe('the task page', () => {
  test('shows props, body, children as a tree and sequence neighbours (R16)', async ($, on) => {
    taskWorld(on, FAMILY)
    const ui = await mount($)
    await $.command.run(openPeek(`${TASKS}/p.md`))
    const text = await drawnText(ui)
    expect(text).toContain('SHIP THE EXPORT')
    expect(text).toContain('doing')
    expect(text).toContain('The body of the export task.')
    expect(text).toMatch(/[├└]/)
    expect(text).toContain('Child one')
    expect(text).toContain('Child two')
    expect(text).toContain('Grandchild')
    expect(text).toContain('Next step')
    expect(text).not.toContain('Unrelated')
    await ui.unmount()
  })

  test('draws from the definition alone: a changed definition changes the page', async ($, on) => {
    const view = TASK_VIEW.replace('## Children', '## Kids').replace('peek-tree ancestors={{id}}', 'peek-list ancestors={{id}}')
    taskWorld(on, FAMILY, view)
    const ui = await mount($)
    await $.command.run(openPeek(`${TASKS}/p.md`))
    const text = await drawnText(ui)
    expect(text).toContain('KIDS')
    expect(text).not.toContain('CHILDREN')
    expect(text).toContain('Child one')
    expect(text).not.toMatch(/[├└]/)
    await ui.unmount()
  })

  test('the status key cycles todo, doing, done and back, rewriting only the status line', async ($, on) => {
    const w = taskWorld(on, FAMILY)
    const ui = await mount($)
    await $.command.run(openPeek(`${TASKS}/c1.md`))
    await drawnText(ui)
    const before = w.files[`${TASKS}/c1.md`] ?? ''
    for (const status of ['doing', 'done', 'todo']) {
      await ui.press({ key: 'task-status' })
      await settle()
      expect(w.files[`${TASKS}/c1.md`]).toBe(before.replace('status: todo', `status: ${status}`))
      expect(await drawnText(ui)).toMatch(new RegExp(`Status +${status}`))
    }
    await ui.unmount()
  })

  test('a write that fails leaves the doc unchanged and shows the reason', async ($, on) => {
    const w = taskWorld(on, FAMILY)
    const ui = await mount($)
    await $.command.run(openPeek(`${TASKS}/c1.md`))
    await drawnText(ui)
    const before = w.files[`${TASKS}/c1.md`]
    w.isMvBroken = true
    await ui.press({ key: 'task-status' })
    await settle()
    expect(w.files[`${TASKS}/c1.md`]).toBe(before)
    expect(w.toasts.at(-1) ?? '').toMatch(/Could not/)
    await ui.unmount()
  })

  test('Set cancelled from the menu writes cancelled through the same path', async ($, on) => {
    const w = taskWorld(on, FAMILY)
    const ui = await mount($)
    await $.command.run(openPeek(`${TASKS}/c1.md`))
    await drawnText(ui)
    await menuPress(ui, $, 'Set cancelled')
    expect(w.files[`${TASKS}/c1.md`]).toContain('status: cancelled')
    await ui.unmount()
  })

  test('a plain task shows no flag; a deliverable missing its due date is flagged (R32)', async ($, on) => {
    const w = taskWorld(on, {
      [`${TASKS}/q.md`]: doc({ name: '"Quick capture"', id: 'q', status: 'todo', creator: 'shawn' }),
      '/repo/docs/plan.md': doc({ name: '"Launch plan"', isTask: 'true', id: 'launch', status: 'todo', creator: 'shawn', parent: 'q', sequence: '{ after: q }', attachments: '[a.png]' }),
    })
    w.tracked = { '/repo': ['docs/plan.md'] }
    const ui = await mount($)
    await menuPress(ui, $, 'Tasks: ')
    const text = await drawnText(ui)
    expect(text).toContain('Quick capture')
    expect(text).toContain('Launch plan')
    expect(text.split('⚑').length - 1).toBe(1)
    await ui.unmount()
  })

  test('a task shows as a card in Gallery and as a row in a group, and each opens to its task page (R12)', async ($, on) => {
    taskWorld(on, FAMILY)
    const ui = await mount($)
    await $.command.run(openPeek(`${TASKS}/c2.md`))
    await drawnText(ui)
    await ui.press({ key: 'mode-gallery' })
    await settle()
    await ui.press({ key: 'item-0' })
    expect(await drawnText(ui)).toContain('CHILD TWO')
    await call($, 'save_group', { title: 'Export', add: [{ target: '.peek/tasks/c1.md' }] })
    await ui.press({ key: 'mode-groups' })
    await settle()
    await ui.press({ key: 'item-0' })
    await settle()
    await ui.press({ key: 'item-0' })
    expect(await drawnText(ui)).toContain('CHILD ONE')
    await ui.unmount()
  })
})

describe('the Tasks page', () => {
  test('with no tasks it says how to make one', async ($, on) => {
    taskWorld(on, {})
    const ui = await mount($)
    await menuPress(ui, $, 'Tasks: ')
    expect(await drawnText(ui)).toContain('No tasks yet. Tell the agent: \\"task: ...\\"')
    await ui.unmount()
  })

  test('opens in focus layout and is reached from a task page header path', async ($, on) => {
    taskWorld(on, FAMILY)
    const ui = await mount($)
    await $.command.run(openPeek(`${TASKS}/c1.md`))
    await drawnText(ui)
    await $.command.run(openPeek(TASKS))
    const text = await drawnText(ui)
    expect(text).toContain('NOW')
    expect(text).toContain('NEXT')
    expect(text).toContain('Ship the export')
    expect(text).toContain('Unrelated')
    await ui.unmount()
  })

  test('a creator filter shows only Shawn\'s tasks, then only one agent\'s (R17)', async ($, on) => {
    taskWorld(on, FAMILY)
    const ui = await mount($)
    await menuPress(ui, $, 'Tasks: ')
    await menuPress(ui, $, 'Filter: creator shawn')
    let text = await drawnText(ui)
    expect(text).toContain('Child one')
    expect(text).not.toContain('Unrelated')
    await menuPress(ui, $, 'Filter: creator session-7')
    text = await drawnText(ui)
    expect(text).toContain('Unrelated')
    expect(text).not.toContain('Child one')
    expect(text).not.toContain('Next step')
    await menuPress(ui, $, 'Filter: creator anyone')
    expect(await drawnText(ui)).toContain('Child one')
    await ui.unmount()
  })

  test('j and k select block rows, Enter opens the selected one, and the new page starts on its first row', async ($, on) => {
    taskWorld(on, {
      [`${TASKS}/a.md`]: doc({ name: '"Alpha task"', id: 'a', status: 'doing', creator: 'shawn' }),
      [`${TASKS}/b.md`]: doc({ name: '"Beta task"', id: 'b', status: 'todo', creator: 'shawn', due: '2026-01-01' }),
      [`${TASKS}/b1.md`]: doc({ name: '"Beta child"', id: 'b1', status: 'todo', creator: 'shawn', parent: 'b', due: '2026-01-02' }),
      [`${TASKS}/b2.md`]: doc({ name: '"Beta second"', id: 'b2', status: 'todo', creator: 'shawn', parent: 'b', due: '2026-01-03' }),
    })
    const ui = await mount($)
    await menuPress(ui, $, 'Tasks: ')
    await drawnText(ui)
    await ui.press({ key: 'next' })
    await drawnText(ui)
    const focused = await ui.find({ key: 'item-1' })
    expect(focused?.props.autoFocus).toBe(true)
    expect(focused?.props.label).toBe('Beta task')
    await ui.press({ key: 'item-1' })
    const text = await drawnText(ui)
    expect(text).toContain('BETA TASK')
    expect((await ui.find({ key: 'item-0' }))?.props.autoFocus).toBe(true)
    expect((await ui.find({ key: 'item-1' }))?.props.autoFocus).toBeUndefined()
    await ui.unmount()
  })

  test('y switches the selected block\'s layout and keeps it for that place', async ($, on) => {
    taskWorld(on, FAMILY)
    const ui = await mount($)
    await menuPress(ui, $, 'Tasks: ')
    expect(await drawnText(ui)).toContain('NOW')
    await ui.press({ key: 'task-layout' })
    expect(await drawnText(ui)).not.toContain('NOW')
    await $.command.run(openPeek(`${TASKS}/p.md`))
    await drawnText(ui)
    await $.command.run(openPeek(TASKS))
    expect(await drawnText(ui)).not.toContain('NOW')
    for (let i = 0; i < 5; i++) {
      await ui.press({ key: 'task-layout' })
      await drawnText(ui)
    }
    expect(await drawnText(ui)).toContain('NOW')
    await ui.unmount()
  })

  test('"Adopt this task" is offered only for a session-ended mirrored task', () => {
    const ended: Item = { id: 'm1', href: '/home/.local/share/claude-peek/mirror/s9/1.md', type: 'task', name: 'Left over', props: { status: 'todo', session_ended: true }, source: 'mirrored' }
    expect(canAdopt(ended)).toBe(true)
    expect(canAdopt({ ...ended, props: { status: 'todo' } })).toBe(false)
    expect(canAdopt({ ...ended, source: 'task-folder' })).toBe(false)
  })

  test('"Adopt this task" on a session-ended task moves it into Shawn\'s list as a takeover doc keeping its id', async ($, on) => {
    const record = '/home/.local/share/claude-peek/mirror/s9/3.md'
    const text = withProp(recordText({ session: 's9', count: 1, item: { id: '3', subject: 'Left over', status: 'pending', blockedBy: [] }, status: 'todo' }), 'session_ended', true)
    const w = taskWorld(on, { [record]: text, '/home/.local/share/claude-peek/mirror/s9/session.json': JSON.stringify({ root: '/repo', endedAt: 1 }) })
    mirrorListState(w, 's9', { 1: { phase: 'folded', foldedAt: 1 } })
    on('clock.every', () => ({ value: undefined }))
    on('session.start', (_$: unknown, e: { cwd: string }) => ({ cwd: e.cwd }) as never)
    await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)
    await settle()
    const ui = await mount($)
    await menuPress(ui, $, 'Tasks: ')
    expect(await drawnText(ui)).toContain('Left over')
    await menuPress(ui, $, 'Adopt this task')
    const taken = Object.keys(w.files).filter(path => path.startsWith(`${TASKS}/`))
    expect(taken.length).toBe(1)
    const props = readFrontmatter(w.files[taken[0] ?? ''] ?? '').props ?? {}
    expect([props.name, props.mirror, props.creator, props.adopted_by]).toEqual(['Left over', 's9/3', 's9', 'shawn'])
    expect(readFrontmatter(w.files[record] ?? '').props?.takeover).toBe(taken[0])
    await ui.unmount()
  })

  test('"Archived sequences" lists this repo\'s archived agent lists newest first, a row opens a page of the list\'s items, and the Tasks page leaves them out', async ($, on) => {
    const OLD = 'aaaaaaaa-0000-4000-8000-000000000000'
    const NEW = 'bbbbbbbb-0000-4000-8000-000000000000'
    const ELSEWHERE = 'cccccccc-0000-4000-8000-000000000000'
    const agentRecord = (session: string, id: string, subject: string, status: string, isEnded = false) => {
      const text = recordText({ session, count: 1, item: { id, subject, status: status === 'todo' ? 'pending' : 'completed', blockedBy: [] }, status })
      return { [`${MIRROR_ROOT}/${session}/${id}.md`]: isEnded ? withProp(text, 'session_ended', true) : text }
    }
    const w = taskWorld(on, {
      ...FAMILY,
      ...agentRecord(OLD, '1', 'Old step one', 'done'),
      ...agentRecord(OLD, '2', 'Old step two', 'todo', true),
      ...agentRecord(NEW, '1', 'New step one', 'done'),
      ...agentRecord(ELSEWHERE, '1', 'Elsewhere step', 'done'),
    })
    mirrorListState(w, OLD, { 1: { phase: 'archived', archivedAt: 100 } })
    mirrorListState(w, NEW, { 1: { phase: 'archived', archivedAt: 300 } })
    mirrorListState(w, ELSEWHERE, { 1: { phase: 'archived', archivedAt: 200 } }, '/other/.git')
    const ui = await mount($)
    await menuPress(ui, $, 'Tasks: ')
    const page = await drawnText(ui)
    expect(page).toContain('Ship the export')
    expect(page).not.toContain('Old step')
    await $.command.run({ command: 'peek-menu' } as never)
    await ui.redraw()
    await ui.input({ key: 'menu-filter', text: 'Archived: ', kind: 'change' })
    const menu = await drawnText(ui)
    expect(menu.indexOf('Archived: Agent tasks bbbbbbbb #1')).toBeGreaterThan(-1)
    expect(menu.indexOf('Archived: Agent tasks aaaaaaaa #1')).toBeGreaterThan(menu.indexOf('Archived: Agent tasks bbbbbbbb #1'))
    expect(menu).not.toContain('cccccccc')
    const row = await ui.find({ type: 'Button', text: /^Archived: Agent tasks aaaaaaaa #1/ })
    await ui.press({ key: String(row?.props.key) })
    await settle()
    const opened = await drawnText(ui)
    expect(opened).toContain('Old step one')
    expect(opened).toContain('Old step two')
    expect(opened).toContain('session ended')
    expect(opened).not.toContain('New step one')
    await ui.unmount()
  })
})

describe('blocks on other pages', () => {
  test('z folds the selected tree parent on a plain file page, which draws the task store', async ($, on) => {
    taskWorld(on, { ...FAMILY, '/repo/notes/board.md': `# Board\n\n${FENCE}peek-tree parent=p\n${FENCE}\n\n${FENCE}peek-tree\n${FENCE}\n` })
    const ui = await mount($)
    await $.command.run(openPeek('/repo/notes/board.md'))
    let text = await drawnText(ui)
    expect(text.split('Child one').length - 1).toBe(2)
    const parent = Number(/^item-(\d+)$/.exec(String((await ui.find({ text: /^Ship the export$/ }))?.props.key))?.[1])
    expect(parent).toBeGreaterThan(0)
    for (let i = 0; i < parent; i++) await ui.press({ key: 'next' })
    await drawnText(ui)
    expect((await ui.find({ key: `item-${parent}` }))?.props.autoFocus).toBe(true)
    await ui.press({ key: 'task-fold' })
    text = await drawnText(ui)
    expect(text.split('Child one').length - 1).toBe(1)
    await ui.unmount()
  })

  test('covers AE5: a tree block in a group description draws the group\'s tasks as a tree', async ($, on) => {
    taskWorld(on, FAMILY)
    await call($, 'save_group', { title: 'Export', description: `Work on the export.\n\n${FENCE}peek-tree parent=p\n${FENCE}`, add: [{ target: '.peek/tasks/p.md' }] })
    const ui = await mount($)
    await ui.press({ key: 'mode-groups' })
    await settle()
    await ui.press({ key: 'item-0' })
    const text = await drawnText(ui)
    expect(text).toContain('Work on the export.')
    expect(text).toContain('Child one')
    expect(text).toContain('Child two')
    expect(text).not.toContain('Unrelated')
    await ui.unmount()
  })
})

describe('place persistence', () => {
  test('saved place choices load at startup, and a change is saved', async () => {
    const saved: Record<string, unknown> = { places: { 'file:///repo/x.md#body-0': { layout: 'tree', folded: ['a'] }, junk: { layout: 'spiral', folded: 'no' } } }
    const io = { storeGet: async (key: string) => saved[key], storeSet: async (key: string, value: unknown) => (saved[key] = value) }
    await wirePlaces(io)
    expect(getPlace('file:///repo/x.md#body-0')).toEqual({ layout: 'tree', folded: ['a'] })
    expect(getPlace('junk')).toBeUndefined()
    noteRow('persist-row', { place: 'file:///repo/y.md#body-0', id: 'r', layout: 'list', hasChildren: false })
    expect(cycleLayoutOfRow('persist-row')).toBe('tree')
    await settle()
    expect((saved.places as Record<string, unknown>)['file:///repo/y.md#body-0']).toEqual({ layout: 'tree', folded: [] })
    onPlaceChange(null)
    setPlace('file:///repo/x.md#body-0', { folded: [] })
  })
})

describe('template', () => {
  test('the built-in definition copy loads, and a placeholder alone on a line becomes its own part', () => {
    const check = readDefinition('task.md', TASK_VIEW)
    expect(check.ok).toBe(true)
    const parts = fillTemplate('# {{name}}\n\n{{description}}\n\n```peek-tree parent={{id}}\n```', { name: 'A *bold* | name', id: 'x1' }, { description: '```peek-list\n```' })
    expect(parts).toEqual([
      { kind: 'template', text: '# A \\*bold\\* \\| name\n' },
      { kind: 'value', text: '```peek-list\n```' },
      { kind: 'template', text: '\n```peek-tree parent=x1\n```' },
    ])
  })
})
