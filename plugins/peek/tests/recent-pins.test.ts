import { describe, expect, test } from 'claude-code/testing'

import { recordText, withProp } from '../hooks/mirror/records'
import { HOME, PANE_PROPS, call, fakeFs } from './fixtures/world'
import type { World } from './fixtures/world'

const TASKS = '/repo/.peek/tasks'
const MIRROR = `${HOME}/.local/share/claude-peek/mirror`

function task(w: World, id: string, props: { status?: string; creator?: string } = {}) {
  const path = `${TASKS}/${id}.md`
  w.files[path] = ['---', `name: "Task ${id}"`, `id: ${id}`, `status: ${props.status ?? 'todo'}`, `creator: ${props.creator ?? 'shawn'}`, '---', ''].join('\n')
  w.touch(path)
}

// One mirrored agent list: `open` items still to do and `done` finished ones, written last so it is the most recent.
function agentList(w: World, session: string, open: number, done = 0, isEnded = false) {
  for (let n = 0; n < open + done; n++) {
    const status = n < open ? 'todo' : 'done'
    const item = { id: String(n + 1), subject: `Step ${n + 1} of ${session}`, status: n < open ? 'pending' : 'completed', blockedBy: [] }
    const text = recordText({ session, count: 1, item, status })
    const path = `${MIRROR}/${session}/${n + 1}.md`
    w.files[path] = isEnded ? withProp(text, 'session_ended', true) : text
    w.touch(path)
  }
}

const sessionOf = (n: number) => `${String(n).repeat(8)}-0000-4000-8000-000000000000`

type Mounted = {
  press: (q: { key: string }) => Promise<unknown>
  redraw: () => Promise<unknown>
  drawn: () => Promise<unknown>
  find: (q: { key?: string; text?: string | RegExp }) => Promise<{ props: Record<string, unknown>; text: string } | undefined>
  unmount: () => Promise<void>
}

async function recent($: { ui: { mount: (input: never) => Promise<unknown> } }): Promise<Mounted> {
  const ui = (await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: PANE_PROPS, requestId: 'peek' } as never)) as Mounted
  await ui.press({ key: 'mode-recent' })
  return ui
}

const settle = async () => {
  for (let i = 0; i < 50; i++) await Promise.resolve()
}

async function drawnText(ui: Mounted) {
  await settle()
  await ui.redraw()
  return JSON.stringify(await ui.drawn())
}

// Press handles are renumbered on every draw, so a before/after comparison leaves them out.
const withoutHandles = (text: string) => text.replace(/"handle":\d+/g, '"handle":0')

async function rowNames(ui: Mounted, count = 14) {
  await drawnText(ui)
  const names: string[] = []
  for (let i = 0; i < count; i++) {
    const one = await ui.find({ key: `name-${i}` })
    if (one) names.push(one.text.trim())
  }
  return names
}

describe('open work pinned at the top of Recent (R31)', () => {
  test('seven open tasks of Shawn\'s show five rows, doing first, and a "more" row; done, cancelled and agent tasks stay out', async ($, on) => {
    const w = fakeFs(on)
    for (const id of ['a', 'b', 'c', 'd', 'e', 'f']) task(w, id)
    task(w, 'g', { status: 'doing' })
    task(w, 'x', { status: 'done' })
    task(w, 'y', { status: 'cancelled' })
    task(w, 'z', { creator: sessionOf(9) })
    await call($, 'star', { target: '/repo/docs/plan.md' })
    const ui = await recent($)
    const names = await rowNames(ui)
    expect(names.slice(0, 6)).toEqual(['Task g', 'Task a', 'Task b', 'Task c', 'Task d', 'More on the Tasks page'])
    const text = await drawnText(ui)
    expect(text).toContain('OPEN WORK')
    expect(text).toContain('2 more tasks')
    for (const gone of ['Task e', 'Task f', 'Task x', 'Task y', 'Task z']) expect(text).not.toContain(gone)
    expect(text.indexOf('OPEN WORK')).toBeLessThan(text.indexOf('FAVOURITES'))
    await ui.unmount()
  })

  test('a task row opens the task and the "more" row opens the Tasks page', async ($, on) => {
    const w = fakeFs(on)
    for (const id of ['a', 'b', 'c', 'd', 'e', 'f']) task(w, id)
    const ui = await recent($)
    await rowNames(ui)
    await ui.press({ key: 'item-0' })
    const page = await drawnText(ui)
    expect(page).toContain('a.md')
    expect(page).not.toContain('OPEN WORK')
    await ui.press({ key: 'mode-recent' })
    await rowNames(ui)
    await ui.press({ key: 'item-5' })
    const tasks = await drawnText(ui)
    expect(tasks).toContain('Task f')
    expect(tasks).not.toContain('More on the Tasks page')
    await ui.unmount()
  })

  test('two active agent sequences show as two lines with their open counts, not their items; an ended or finished list does not', async ($, on) => {
    const w = fakeFs(on)
    agentList(w, sessionOf(1), 2, 1)
    agentList(w, sessionOf(2), 3)
    agentList(w, sessionOf(3), 0, 2)
    agentList(w, sessionOf(4), 2, 0, true)
    const ui = await recent($)
    const names = await rowNames(ui)
    expect(names.slice(0, 2)).toEqual(['Agent tasks 22222222 #1', 'Agent tasks 11111111 #1'])
    const text = await drawnText(ui)
    expect(text).toContain('3 open')
    expect(text).toContain('2 open')
    expect(text).not.toContain('Step 1 of')
    expect(text).not.toContain('33333333')
    expect(text).not.toContain('44444444')
    expect(text).not.toContain('More on the Tasks page')
    await ui.press({ key: 'item-0' })
    expect(await drawnText(ui)).toContain('Step 1 of')
    await ui.unmount()
  })

  test('eight active sequences show the three most recent and a "more" row, and favourites stay on the first screen', async ($, on) => {
    const w = fakeFs(on)
    for (let n = 1; n <= 8; n++) agentList(w, sessionOf(n), 1)
    await call($, 'star', { target: '/repo/docs/plan.md' })
    const ui = await recent($)
    const names = await rowNames(ui)
    expect(names.slice(0, 4)).toEqual(['Agent tasks 88888888 #1', 'Agent tasks 77777777 #1', 'Agent tasks 66666666 #1', 'More on the Tasks page'])
    const text = await drawnText(ui)
    expect(text).toContain('5 more agents')
    expect(text).not.toContain('55555555')
    expect(await ui.find({ text: /^FAVOURITES/ })).toBeDefined()
    expect(names[4]).toMatch(/plan/)
    await ui.unmount()
  })

  test('with no open tasks of Shawn\'s and no active agent list, Recent looks as it does today', async ($, on) => {
    const w = fakeFs(on)
    await call($, 'star', { target: '/repo/docs/plan.md' })
    const ui = await recent($)
    const before = withoutHandles(await drawnText(ui))
    task(w, 'x', { status: 'done' })
    task(w, 'y', { status: 'cancelled' })
    task(w, 'z', { creator: sessionOf(9) })
    agentList(w, sessionOf(3), 0, 2)
    expect(withoutHandles(await drawnText(ui))).toBe(before)
    expect(before).not.toContain('OPEN WORK')
    await ui.unmount()
  })
})
