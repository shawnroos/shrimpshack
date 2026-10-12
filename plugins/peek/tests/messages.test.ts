import { expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'
import type { Engine, Mounted } from 'claude-code/testing'
import { PANE_PROPS, PR, create, editGroup, fakeFs } from './fixtures/world'
import type { World } from './fixtures/world'

// What each client module posts when clicked and what follows: state
// writes, saved stores, toasts, opened and written files, and the next draw. Then the final screen state after each
// navigation. The message and navigation code can move only if every line here stays the same.

type Ui = Mounted<'terminal', 'Pane'>
type Node = { type?: string; props?: Record<string, unknown>; children?: unknown[] }
type Run = { $: Engine; ui: Ui; w: World; log: string[]; ids: string[]; state: Map<string, string> }

const FILES: Record<string, string> = {
  '/repo/docs/plan.md': '# Plan\n\nSee [todo](/repo/notes/todo.md).\n\n- [ ] write it\n- [x] plan it\n',
  '/repo/data/a.txt': 'a\n',
  '/repo/data/b.txt': 'b\n',
}

const settleMicrotasks = async () => {
  for (let i = 0; i < 1000; i += 1) await Promise.resolve()
}

function normalized(text: string, ids: readonly string[]) {
  return ids.reduce((all, id, index) => all.split(id).join(`GROUP${index}`), text).replace(/\.[a-z0-9]+\.staged$/, '.STAGED')
}

function short(key: string, value: unknown) {
  if (key === 'view') {
    const view = value as { href?: string; title?: string; error?: string; remote?: { failure?: string } } | null
    if (!view) return 'null'
    const extra = view.error ? ` error=${view.error}` : view.remote?.failure ? ` failure=${view.remote.failure}` : ''
    return `${view.href} ${view.title}${extra}`
  }
  if (key === 'mentions') return (value as { href: string }[]).map(one => one.href).join(',')
  return JSON.stringify(value) ?? 'undefined'
}

function walk(node: unknown, visit: (one: Node) => void) {
  if (!node || typeof node !== 'object') return
  visit(node as Node)
  for (const child of (node as Node).children ?? []) walk(child, visit)
}

function textOf(node: unknown): string {
  if (typeof node === 'string') return node
  if (!node || typeof node !== 'object') return ''
  return ((node as Node).children ?? []).map(textOf).join('')
}

async function begin($: Engine, on: On, setup: (run: Run) => Promise<void> = async () => undefined): Promise<Run> {
  const w = fakeFs(on, FILES)
  const log: string[] = []
  const state = new Map<string, string>()
  const run = { $, w, log, ids: [] as string[], state } as Run
  on('state.set', (_$, e, next) => {
    const write = e as { key: string; value: unknown }
    state.set(write.key, short(write.key, write.value))
    log.push(`set ${write.key} ${short(write.key, write.value)}`)
    return next(e)
  })
  on('store.set', (_$, e, next) => {
    log.push(`store ${e.key} ${JSON.stringify(e.value)}`)
    return next(e)
  })
  await setup(run)
  run.ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: PANE_PROPS, requestId: 'peek' })
  await settleMicrotasks()
  await run.ui.redraw()
  log.splice(0)
  w.toasts.splice(0)
  w.log.splice(0)
  return run
}

// What the next draw shows: the footer keys (which screen), the group page title, the selected item, the starred
// marks and the first drawn task box.
async function drawn(run: Run) {
  await run.ui.redraw()
  const footer: string[] = []
  const focus: string[] = []
  let stars = 0
  walk(await run.ui.drawn(), one => {
    if (one.props?.key === 'footer-keys') for (const button of (one.children ?? []) as Node[]) footer.push(String(button.props?.key))
    if (one.type === 'Button' && one.props?.autoFocus === true) focus.push(String(one.props.key))
    if (one.type === 'Button' && one.props?.label === '\u{f51a}') stars += 1
  })
  const title = await run.ui.find({ key: 'group-page-title' })
  run.log.push(`draw ${footer.join(',')}`)
  run.log.push(`draw title=${title ? title.text.trim() : '-'} focus=${focus.join(',') || '-'} stars=${stars}`)
}

async function step(run: Run, name: string, act: () => Promise<unknown>) {
  run.log.push(`> ${name}`)
  await act()
  await settleMicrotasks()
  for (const text of run.w.toasts.splice(0)) run.log.push(`toast ${text}`)
  for (const one of run.w.log.splice(0)) if ((one[0] === 'run' && one[1] === 'open') || one[0] === 'write') run.log.push(one.join(' '))
  await drawn(run)
}

async function clientNode(run: Run, pattern: RegExp) {
  const found: Node[] = []
  walk(await run.ui.drawn(), one => {
    if (one.type === 'Client' && pattern.test(String(one.props?.key))) found.push(one)
  })
  if (!found[0]) throw new Error(`no client ${pattern}`)
  return found[0]
}

// x and y count from the item's own corner: the row for a row list, the card for a card grid.
async function click(run: Run, pattern: RegExp, index: number, x: number, y: number) {
  const node = await clientNode(run, pattern)
  const key = String(node.props?.key)
  const props = (node.props?.props ?? {}) as { kind?: string; cardWidth?: number; gap?: number }
  const at = props.kind === 'cards' ? { x: index * ((props.cardWidth ?? 0) + (props.gap ?? 0)) + x, y } : { x, y: index + y }
  run.log.push(`click ${key} ${at.x},${at.y}`)
  await run.ui.resize({ columns: Number(node.props?.width), rows: Number(node.props?.height), in: key })
  await run.ui.pointer({ type: 'move', ...at, in: key })
  await run.ui.pointer({ type: 'down', button: 'left', ...at, in: key })
}

async function clientDrawn(run: Run, key: string) {
  const text = await run.ui
    .drawn({ in: key })
    .then(tree => JSON.stringify(tree))
    .catch((error: unknown) => `threw ${String(error).split(':')[0]}`)
  run.log.push(`client ${key} ${text}`)
}

async function finalState(run: Run, name: string, act: () => Promise<unknown>) {
  await step(run, name, act)
  run.log.push(`state ${[...run.state].sort(([a], [b]) => a.localeCompare(b)).map(([key, value]) => `${key}=${value}`).join(' ')}`)
}

function result(run: Run) {
  return run.log.map(one => normalized(one, run.ids))
}

async function twoGroups(run: Run) {
  const launch = await create(run.$ as never, [{ target: 'docs/plan.md' }, { target: 'notes/todo.md' }], 'Launch')
  run.w.now += 60_000
  const spare = await create(run.$ as never, [{ target: 'docs/plan.md' }], 'Spare')
  run.ids.push(launch.id, spare.id)
  editGroup(run.w, launch.id, group => (group.starred = true))
  await run.$.command.run({ command: 'peek', args: '/repo/notes/todo.md' } as never)
  await run.$.command.run({ command: 'peek', args: '/repo/docs/plan.md' } as never)
}

async function clickTab(run: Run, id: string) {
  const right = await run.ui.find({ key: 'tabs-right' })
  const tabs = (right?.props.props as { tabs: { id: string; label: string }[] }).tabs
  const at = tabs.findIndex(one => one.id === id)
  await click(run, /^tabs-right$/, 0, tabs.slice(0, at).reduce((sum, one) => sum + one.label.length, 0) + 1, 0)
}

const CASES: Record<string, (run: Run) => Promise<void>> = {
  'tabs: mode': async run => {
    await step(run, 'mode-recent key', () => run.ui.press({ key: 'mode-recent' }))
    await step(run, 'click Gallery tab', () => clickTab(run, 'gallery'))
    await step(run, 'click Groups tab', () => clickTab(run, 'groups'))
    await step(run, 'click Groups tab again', () => clickTab(run, 'groups'))
    await step(run, 'click Recent tab', () => clickTab(run, 'recent'))
  },
  'hover-layer rows in Recent: star, open': async run => {
    await step(run, 'mode-recent key', () => run.ui.press({ key: 'mode-recent' }))
    await step(run, 'click star of row 1', () => click(run, /^hover-(?!starred|groups|group-|favs)/, 1, 0, 0))
    await step(run, 'click row 0', () => click(run, /^hover-(?!starred|groups|group-|favs)/, 0, 8, 0))
  },
  'hover-layer cards in Gallery: star, open': async run => {
    await step(run, 'mode-gallery key', () => run.ui.press({ key: 'mode-gallery' }))
    await step(run, 'click star of card 0', () => click(run, /^hover-(?!starred|groups|group-|favs)/, 0, 2, 1))
    await step(run, 'click card 0', () => click(run, /^hover-(?!starred|groups|group-|favs)/, 0, 6, 3))
  },
  'hover-layer group cards: starGroup, openGroup': async run => {
    await step(run, 'mode-groups key', () => run.ui.press({ key: 'mode-groups' }))
    await step(run, 'click star of group 1 in the Groups tab', () => click(run, /^hover-groups-1$/, 0, 0, 0))
    await step(run, 'click group 1', () => click(run, /^hover-groups-1$/, 0, 10, 0))
    await step(run, 'mode-recent key', () => run.ui.press({ key: 'mode-recent' }))
    await step(run, 'click star of the pinned group in Recent', () => click(run, /^hover-starred-0$/, 0, 0, 0))
    await step(run, 'mode-recent key', () => run.ui.press({ key: 'mode-recent' }))
    await step(run, 'click the pinned group in Recent', () => click(run, /^hover-starred-0$/, 0, 10, 0))
  },
  'hover-layer item cards: star, open with inGroup and key': async run => {
    await step(run, 'mode-groups key', () => run.ui.press({ key: 'mode-groups' }))
    await step(run, 'click star of item card 1', () => click(run, /^hover-groups-items-0-/, 1, 2, 1))
    await step(run, 'click item card 1', () => click(run, /^hover-groups-items-0-/, 1, 6, 2))
    await step(run, 'back key', () => run.ui.press({ key: 'back' }))
  },
  'hover-layer group page rows: star, open': async run => {
    await step(run, 'mode-groups key', () => run.ui.press({ key: 'mode-groups' }))
    await step(run, 'open-selected key', () => run.ui.press({ key: 'open-selected' }))
    await step(run, 'click star of row 1', () => click(run, /^hover-group-0$/, 1, 0, 0))
    await step(run, 'click row 1', () => click(run, /^hover-group-0$/, 1, 8, 0))
    await step(run, 'back key', () => run.ui.press({ key: 'back' }))
  },
  'rows in a folder view: star, open': async run => {
    await step(run, 'peek the folder', () => run.$.command.run({ command: 'peek', args: '/repo/data' } as never))
    await step(run, 'click star of row 1', () => click(run, /^rows-0$/, 1, 0, 0))
    await step(run, 'click row 2', () => click(run, /^rows-0$/, 2, 6, 0))
  },
  'tasks: toggle': async run => {
    await step(run, 'click task 0', () => click(run, /^tasks-/, 0, 2, 0))
    await step(run, 'click task 1', () => click(run, /^tasks-/, 1, 2, 0))
  },
  'posts that are not a click, and liveInput': async run => {
    const post = (data: unknown) => step(run, `post ${JSON.stringify(data)}`, () => run.ui.post(data as never, { in: 'tabs-right' }))
    for (const data of [null, 'star', [1, 2], {}, { nothing: 1 }, { star: 5 }, { toggle: false }, { mode: 'bogus' }, { mode: 7 }, { openGroup: 1 }, { starGroup: null }, { open: 3 }, { liveInput: 'x' }, { liveInput: { seq: 1 } }]) await post(data)
    await clientDrawn(run, 'tabs-right')
    await post({ open: '/repo/nowhere.md', inGroup: 7 })
    await post({ open: 'file:///repo/data/a.txt', inGroup: 'missing-group', key: 5 })
    await post({ open: 'file:///repo/data/a.txt', inGroup: 'missing-group' })
    await post({ mode: 'bogus', open: 'file:///repo/data/b.txt' })
    await post({ star: 'file:///repo/data/a.txt', open: 'file:///repo/data/b.txt', mode: 'gallery' })
    await post({ toggle: 'file:///repo/data/b.txt', mode: 'gallery', openGroup: 'x' })
    await post({ mode: 'gallery', openGroup: 'x', starGroup: 'y' })
    await post({ openGroup: 'x', starGroup: 'y', open: 'file:///repo/data/b.txt' })
    await post({ starGroup: 'y', open: 'file:///repo/data/b.txt', inGroup: 'missing-group' })
    await clientDrawn(run, 'tabs-right')
    // A liveInput post is answered with the live-input props, whichever Client posted it: here the tab strip.
    await post({ liveInput: [], star: 'file:///repo/data/b.txt' })
    await clientDrawn(run, 'tabs-right')
    await post({ liveInput: [{ seq: 1, type: 'key', key: 'a' }] })
  },
  'a post from the UI gallery pane is not peek\'s': async run => {
    await run.$.command.run({ command: 'peek-ui' } as never)
    const gallery = await run.$.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: PANE_PROPS, requestId: 'peek-ui' })
    for (const data of [{ star: 'file:///repo/data/a.txt' }, { mode: 'gallery' }, { liveInput: [] }, { open: 'file:///repo/data/b.txt' }]) {
      await step(run, `post ${JSON.stringify(data)} from g-client`, () => gallery.post(data as never, { in: 'g-client' }))
      run.log.push(`g-client ${JSON.stringify(await gallery.drawn({ in: 'g-client' }))}`)
    }
    await gallery.unmount()
  },
}

for (const [name, act] of Object.entries(CASES)) {
  test(`message: ${name}`, async ($, on) => {
    const run = await begin($, on, twoGroups)
    await act(run)
    await run.ui.unmount()
    expect(result(run)).toEqual(EXPECTED[`message: ${name}`])
  })
}

const NAVIGATIONS: Record<string, (run: Run) => Promise<void>> = {
  'show a file, a remote page, a link from a page, then Back': async run => {
    await finalState(run, 'show file', () => run.$.command.run({ command: 'peek', args: '/repo/docs/plan.md' } as never))
    await finalState(run, 'show remote', () => run.$.command.run({ command: 'peek', args: PR } as never))
    await finalState(run, 'show file again', () => run.$.command.run({ command: 'peek', args: '/repo/docs/plan.md' } as never))
    await finalState(run, 'follow a link from the page', () => run.ui.post({ toggle: 'file:///repo/notes/todo.md' }, { in: 'tabs-right' }))
    await finalState(run, 'back to the page', () => run.ui.press({ key: 'back' }))
  },
  'open a group page, an item from it, Back, then switch modes': async run => {
    await finalState(run, 'switch to groups', () => run.ui.press({ key: 'mode-groups' }))
    await finalState(run, 'open group page', () => click(run, /^hover-groups-0$/, 0, 10, 0))
    await finalState(run, 'open its second item', async () => {
      await run.ui.press({ key: 'next' })
      await run.ui.press({ key: 'open-selected' })
    })
    await finalState(run, 'back to the group page', () => run.ui.press({ key: 'back' }))
    await finalState(run, 'switch to groups from the group page', () => run.ui.press({ key: 'mode-groups' }))
    await finalState(run, 'switch to gallery', () => run.ui.press({ key: 'mode-gallery' }))
    await finalState(run, 'open group page from the menu-less message', () => run.ui.post({ openGroup: run.ids[1] ?? '' }, { in: 'tabs-right' }))
    await finalState(run, 'switch to recent', () => run.ui.press({ key: 'mode-recent' }))
    await finalState(run, 'switch to view', () => run.ui.press({ key: 'mode-view' }))
  },
}

for (const [name, act] of Object.entries(NAVIGATIONS)) {
  test(`navigation: ${name}`, async ($, on) => {
    const run = await begin($, on, twoGroups)
    await act(run)
    await run.ui.unmount()
    expect(result(run)).toEqual(EXPECTED[`navigation: ${name}`])
  })
}

const EXPECTED: Record<string, string[]> = {
  "message: tabs: mode": [
    "> mode-recent key",
    "set mode \"recent\"",
    "set page 0",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,scope,role,next,prev,left,right,open-selected,star-selected,expand-selected,close",
    "draw title=- focus=item-0 stars=1",
    "> click Gallery tab",
    "click tabs-right 11,0",
    "set mode \"gallery\"",
    "set page 0",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,scope,role,type,sort,next,prev,left,right,open-selected,star-selected,close",
    "draw title=- focus=item-0 stars=0",
    "> click Groups tab",
    "click tabs-right 23,0",
    "set mode \"groups\"",
    "set page 0",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,left,right,open-selected,star-selected,expand-selected,close",
    "draw title=- focus=item-0 stars=1",
    "> click Groups tab again",
    "click tabs-right 23,0",
    "set openGroup null",
    "set mode \"groups\"",
    "set page 0",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,left,right,open-selected,star-selected,expand-selected,close",
    "draw title=- focus=item-0 stars=1",
    "> click Recent tab",
    "click tabs-right 1,0",
    "set mode \"recent\"",
    "set page 0",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,scope,role,next,prev,left,right,open-selected,star-selected,expand-selected,close",
    "draw title=- focus=item-0 stars=1"
  ],
  "message: hover-layer rows in Recent: star, open": [
    "> mode-recent key",
    "set mode \"recent\"",
    "set page 0",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,scope,role,next,prev,left,right,open-selected,star-selected,expand-selected,close",
    "draw title=- focus=item-0 stars=1",
    "> click star of row 1",
    "click hover-touched-0 0,1",
    "set stars [\"file:///repo/notes/todo.md\"]",
    "store stars [\"file:///repo/notes/todo.md\"]",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,scope,role,next,prev,left,right,open-selected,star-selected,expand-selected,close",
    "draw title=- focus=item-0 stars=2",
    "> click row 0",
    "click hover-touched-0 8,0",
    "set view file:///repo/docs/plan.md Loading…",
    "set mentions file:///repo/notes/todo.md,file:///repo/docs/plan.md",
    "set page 0",
    "set mode \"view\"",
    "set view file:///repo/docs/plan.md plan.md",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0"
  ],
  "message: hover-layer cards in Gallery: star, open": [
    "> mode-gallery key",
    "set mode \"gallery\"",
    "set page 0",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,scope,role,type,sort,next,prev,left,right,open-selected,star-selected,close",
    "draw title=- focus=item-0 stars=0",
    "> click star of card 0",
    "click hover-touched-0 2,1",
    "set stars [\"file:///repo/docs/plan.md\"]",
    "store stars [\"file:///repo/docs/plan.md\"]",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,scope,role,type,sort,next,prev,left,right,open-selected,star-selected,close",
    "draw title=- focus=item-0 stars=1",
    "> click card 0",
    "click hover-touched-0 6,3",
    "set view file:///repo/notes/todo.md Loading…",
    "set mentions file:///repo/docs/plan.md,file:///repo/notes/todo.md",
    "set page 0",
    "set mode \"view\"",
    "set view file:///repo/notes/todo.md todo.md",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0"
  ],
  "message: hover-layer group cards: starGroup, openGroup": [
    "> mode-groups key",
    "set mode \"groups\"",
    "set page 0",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,left,right,open-selected,star-selected,expand-selected,close",
    "draw title=- focus=item-0 stars=1",
    "> click star of group 1 in the Groups tab",
    "click hover-groups-1 0,0",
    "set cursor 1",
    "write /home/.local/share/claude-peek/groups/ea199529256b9f85/GROUP1.json.lock/owner",
    "write /home/.local/share/claude-peek/groups/ea199529256b9f85/GROUP1.json.STAGED",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,left,right,open-selected,star-selected,expand-selected,close",
    "draw title=- focus=item-1 stars=2",
    "> click group 1",
    "click hover-groups-1 10,0",
    "set openGroup {\"id\":\"GROUP0\",\"item\":null}",
    "set mode \"groups\"",
    "set page 0",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,open-selected,star-selected,close",
    "draw title= Launch focus=item-0 stars=0",
    "> mode-recent key",
    "set mode \"recent\"",
    "set page 0",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,scope,role,next,prev,left,right,open-selected,star-selected,expand-selected,close",
    "draw title=- focus=item-1 stars=2",
    "> click star of the pinned group in Recent",
    "click hover-starred-0 0,0",
    "write /home/.local/share/claude-peek/groups/ea199529256b9f85/GROUP1.json.lock/owner",
    "write /home/.local/share/claude-peek/groups/ea199529256b9f85/GROUP1.json.STAGED",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,scope,role,next,prev,left,right,open-selected,star-selected,expand-selected,close",
    "draw title=- focus=item-1 stars=1",
    "> mode-recent key",
    "set mode \"recent\"",
    "set page 0",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,scope,role,next,prev,left,right,open-selected,star-selected,expand-selected,close",
    "draw title=- focus=item-1 stars=1",
    "> click the pinned group in Recent",
    "click hover-starred-0 10,0",
    "set openGroup {\"id\":\"GROUP0\",\"item\":null}",
    "set mode \"groups\"",
    "set page 0",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,open-selected,star-selected,close",
    "draw title= Launch focus=item-0 stars=0"
  ],
  "message: hover-layer item cards: star, open with inGroup and key": [
    "> mode-groups key",
    "set mode \"groups\"",
    "set page 0",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,left,right,open-selected,star-selected,expand-selected,close",
    "draw title=- focus=item-0 stars=1",
    "> click star of item card 1",
    "click hover-groups-items-0-0 47,1",
    "set stars [\"file:///repo/notes/todo.md\"]",
    "store stars [\"file:///repo/notes/todo.md\"]",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,left,right,open-selected,star-selected,expand-selected,close",
    "draw title=- focus=item-0 stars=1",
    "> click item card 1",
    "click hover-groups-items-0-0 51,2",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"notes/todo.md\"}",
    "set view file:///repo/notes/todo.md Loading…",
    "set mentions file:///repo/docs/plan.md,file:///repo/notes/todo.md",
    "set page 0",
    "set mode \"view\"",
    "set view file:///repo/notes/todo.md todo.md",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,back,copy,close",
    "draw title=- focus=- stars=0",
    "> back key",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"notes/todo.md\"}",
    "set mode \"groups\"",
    "set page 0",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,open-selected,star-selected,close",
    "draw title= Launch focus=item-1 stars=0"
  ],
  "message: hover-layer group page rows: star, open": [
    "> mode-groups key",
    "set mode \"groups\"",
    "set page 0",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,left,right,open-selected,star-selected,expand-selected,close",
    "draw title=- focus=item-0 stars=1",
    "> open-selected key",
    "set openGroup {\"id\":\"GROUP0\",\"item\":null}",
    "set mode \"groups\"",
    "set page 0",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,open-selected,star-selected,close",
    "draw title= Launch focus=item-0 stars=0",
    "> click star of row 1",
    "click hover-group-0 0,1",
    "set stars [\"file:///repo/notes/todo.md\"]",
    "store stars [\"file:///repo/notes/todo.md\"]",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,open-selected,star-selected,close",
    "draw title= Launch focus=item-0 stars=0",
    "> click row 1",
    "click hover-group-0 8,1",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"notes/todo.md\"}",
    "set cursor 1",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"notes/todo.md\"}",
    "set view file:///repo/notes/todo.md Loading…",
    "set mentions file:///repo/docs/plan.md,file:///repo/notes/todo.md",
    "set page 0",
    "set mode \"view\"",
    "set view file:///repo/notes/todo.md todo.md",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,back,copy,close",
    "draw title=- focus=- stars=0",
    "> back key",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"notes/todo.md\"}",
    "set mode \"groups\"",
    "set page 0",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,open-selected,star-selected,close",
    "draw title= Launch focus=item-1 stars=0"
  ],
  "message: rows in a folder view: star, open": [
    "> peek the folder",
    "set view file:///repo/data Loading…",
    "set mentions file:///repo/notes/todo.md,file:///repo/docs/plan.md,file:///repo/data",
    "set page 0",
    "set mode \"view\"",
    "set view file:///repo/data data",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0",
    "> click star of row 1",
    "click rows-0 0,1",
    "set stars [\"file:///repo/data/a.txt\"]",
    "store stars [\"file:///repo/data/a.txt\"]",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0",
    "> click row 2",
    "click rows-0 6,2",
    "set view file:///repo/data/b.txt Loading…",
    "set mentions file:///repo/notes/todo.md,file:///repo/docs/plan.md,file:///repo/data,file:///repo/data/b.txt",
    "set page 0",
    "set mode \"view\"",
    "set view file:///repo/data/b.txt b.txt",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0"
  ],
  "message: tasks: toggle": [
    "> click task 0",
    "click tasks-3 2,0",
    "set view file:///repo/docs/plan.md plan.md",
    "write /repo/docs/plan.md",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0",
    "> click task 1",
    "click tasks-3 2,1",
    "set view file:///repo/docs/plan.md plan.md",
    "write /repo/docs/plan.md",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0"
  ],
  "message: posts that are not a click, and liveInput": [
    "> post null",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0",
    "> post \"star\"",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0",
    "> post [1,2]",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0",
    "> post {}",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0",
    "> post {\"nothing\":1}",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0",
    "> post {\"star\":5}",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0",
    "> post {\"toggle\":false}",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0",
    "> post {\"mode\":\"bogus\"}",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0",
    "> post {\"mode\":7}",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0",
    "> post {\"openGroup\":1}",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0",
    "> post {\"starGroup\":null}",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0",
    "> post {\"open\":3}",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0",
    "> post {\"liveInput\":\"x\"}",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0",
    "> post {\"liveInput\":{\"seq\":1}}",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0",
    "client tabs-right {\"type\":\"Box\",\"props\":{\"flexDirection\":\"row\"},\"children\":[{\"type\":\"Text\",\"props\":{\"color\":\"#928374\",\"backgroundColor\":\"#282828\",\"bold\":false},\"children\":[\"  RECENT \"]},{\"type\":\"Text\",\"props\":{\"color\":\"#928374\",\"backgroundColor\":\"#282828\",\"bold\":false},\"children\":[\" 󰱬 GALLERY \"]},{\"type\":\"Text\",\"props\":{\"color\":\"#928374\",\"backgroundColor\":\"#282828\",\"bold\":false},\"children\":[\"  GROUPS \"]}]}",
    "> post {\"open\":\"/repo/nowhere.md\",\"inGroup\":7}",
    "set view /repo/nowhere.md Loading…",
    "set mentions file:///repo/notes/todo.md,file:///repo/docs/plan.md,/repo/nowhere.md",
    "set page 0",
    "set mode \"view\"",
    "set view /repo/nowhere.md Could not open error=Invalid URL: /repo/nowhere.md",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0",
    "> post {\"open\":\"file:///repo/data/a.txt\",\"inGroup\":\"missing-group\",\"key\":5}",
    "toast That group was deleted.",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0",
    "> post {\"open\":\"file:///repo/data/a.txt\",\"inGroup\":\"missing-group\"}",
    "toast That group was deleted.",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0",
    "> post {\"mode\":\"bogus\",\"open\":\"file:///repo/data/b.txt\"}",
    "set view file:///repo/data/b.txt Loading…",
    "set mentions file:///repo/notes/todo.md,file:///repo/docs/plan.md,/repo/nowhere.md,file:///repo/data/b.txt",
    "set page 0",
    "set mode \"view\"",
    "set view file:///repo/data/b.txt b.txt",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0",
    "> post {\"star\":\"file:///repo/data/a.txt\",\"open\":\"file:///repo/data/b.txt\",\"mode\":\"gallery\"}",
    "set stars [\"file:///repo/data/a.txt\"]",
    "store stars [\"file:///repo/data/a.txt\"]",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0",
    "> post {\"toggle\":\"file:///repo/data/b.txt\",\"mode\":\"gallery\",\"openGroup\":\"x\"}",
    "set view file:///repo/data/b.txt Loading…",
    "set mentions file:///repo/notes/todo.md,file:///repo/docs/plan.md,/repo/nowhere.md,file:///repo/data/b.txt",
    "set page 0",
    "set mode \"view\"",
    "set view file:///repo/data/b.txt b.txt",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,back,copy,close",
    "draw title=- focus=- stars=0",
    "> post {\"mode\":\"gallery\",\"openGroup\":\"x\",\"starGroup\":\"y\"}",
    "set mode \"gallery\"",
    "set page 0",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,scope,role,type,sort,next,prev,left,right,open-selected,star-selected,close",
    "draw title=- focus=item-0 stars=1",
    "> post {\"openGroup\":\"x\",\"starGroup\":\"y\",\"open\":\"file:///repo/data/b.txt\"}",
    "set openGroup {\"id\":\"x\",\"item\":null}",
    "set mode \"groups\"",
    "set page 0",
    "toast That group was deleted.",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,left,right,open-selected,star-selected,expand-selected,close",
    "draw title=- focus=item-0 stars=1",
    "> post {\"starGroup\":\"y\",\"open\":\"file:///repo/data/b.txt\",\"inGroup\":\"missing-group\"}",
    "toast Could not star the group: y is not a group id.",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,left,right,open-selected,star-selected,expand-selected,close",
    "draw title=- focus=item-0 stars=1",
    "client tabs-right {\"type\":\"Box\",\"props\":{\"flexDirection\":\"row\"},\"children\":[{\"type\":\"Text\",\"props\":{\"color\":\"#928374\",\"backgroundColor\":\"#282828\",\"bold\":false},\"children\":[\"  RECENT \"]},{\"type\":\"Text\",\"props\":{\"color\":\"#928374\",\"backgroundColor\":\"#282828\",\"bold\":false},\"children\":[\" 󰱬 GALLERY \"]},{\"type\":\"Text\",\"props\":{\"color\":\"#1e1e1e\",\"backgroundColor\":\"#d79921\",\"bold\":true},\"children\":[\"  GROUPS \"]}]}",
    "> post {\"liveInput\":[],\"star\":\"file:///repo/data/b.txt\"}",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,left,right,open-selected,star-selected,expand-selected,close",
    "draw title=- focus=item-0 stars=1",
    "client tabs-right threw HooksError",
    "> post {\"liveInput\":[{\"seq\":1,\"type\":\"key\",\"key\":\"a\"}]}",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,left,right,open-selected,star-selected,expand-selected,close",
    "draw title=- focus=item-0 stars=1"
  ],
  "message: a post from the UI gallery pane is not peek's": [
    "> post {\"star\":\"file:///repo/data/a.txt\"} from g-client",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0",
    "g-client {\"type\":\"Box\",\"props\":{\"flexDirection\":\"column\"},\"children\":[{\"type\":\"Text\",\"children\":[{\"type\":\"Text\",\"props\":{\"color\":\"cyan\"},\"children\":[\"⠋\"]},\" frame \",\"0\",\" · keys \",\"0\",\" · last\",\" \",{\"type\":\"Text\",\"props\":{\"bold\":true},\"children\":[\"—\"]}]},{\"type\":\"Text\",\"props\":{\"color\":\"yellow\"},\"children\":[\"●·······································\"]},{\"type\":\"Text\",\"props\":{\"dimColor\":true},\"children\":[\"Click here, then ← → move the dot. Esc gives the keys back.\"]}]}",
    "> post {\"mode\":\"gallery\"} from g-client",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0",
    "g-client {\"type\":\"Box\",\"props\":{\"flexDirection\":\"column\"},\"children\":[{\"type\":\"Text\",\"children\":[{\"type\":\"Text\",\"props\":{\"color\":\"cyan\"},\"children\":[\"⠋\"]},\" frame \",\"0\",\" · keys \",\"0\",\" · last\",\" \",{\"type\":\"Text\",\"props\":{\"bold\":true},\"children\":[\"—\"]}]},{\"type\":\"Text\",\"props\":{\"color\":\"yellow\"},\"children\":[\"●·······································\"]},{\"type\":\"Text\",\"props\":{\"dimColor\":true},\"children\":[\"Click here, then ← → move the dot. Esc gives the keys back.\"]}]}",
    "> post {\"liveInput\":[]} from g-client",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0",
    "g-client {\"type\":\"Box\",\"props\":{\"flexDirection\":\"column\"},\"children\":[{\"type\":\"Text\",\"children\":[{\"type\":\"Text\",\"props\":{\"color\":\"cyan\"},\"children\":[\"⠋\"]},\" frame \",\"0\",\" · keys \",\"0\",\" · last\",\" \",{\"type\":\"Text\",\"props\":{\"bold\":true},\"children\":[\"—\"]}]},{\"type\":\"Text\",\"props\":{\"color\":\"yellow\"},\"children\":[\"●·······································\"]},{\"type\":\"Text\",\"props\":{\"dimColor\":true},\"children\":[\"Click here, then ← → move the dot. Esc gives the keys back.\"]}]}",
    "> post {\"open\":\"file:///repo/data/b.txt\"} from g-client",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0",
    "g-client {\"type\":\"Box\",\"props\":{\"flexDirection\":\"column\"},\"children\":[{\"type\":\"Text\",\"children\":[{\"type\":\"Text\",\"props\":{\"color\":\"cyan\"},\"children\":[\"⠋\"]},\" frame \",\"0\",\" · keys \",\"0\",\" · last\",\" \",{\"type\":\"Text\",\"props\":{\"bold\":true},\"children\":[\"—\"]}]},{\"type\":\"Text\",\"props\":{\"color\":\"yellow\"},\"children\":[\"●·······································\"]},{\"type\":\"Text\",\"props\":{\"dimColor\":true},\"children\":[\"Click here, then ← → move the dot. Esc gives the keys back.\"]}]}"
  ],
  "navigation: show a file, a remote page, a link from a page, then Back": [
    "> show file",
    "set view file:///repo/docs/plan.md Loading…",
    "set mentions file:///repo/notes/todo.md,file:///repo/docs/plan.md",
    "set page 0",
    "set mode \"view\"",
    "set view file:///repo/docs/plan.md plan.md",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0",
    "state mentions=file:///repo/notes/todo.md,file:///repo/docs/plan.md mode=\"view\" page=0 view=file:///repo/docs/plan.md plan.md",
    "> show remote",
    "set view https://github.com/acme/widgets/pull/42 Loading…",
    "set mentions file:///repo/notes/todo.md,file:///repo/docs/plan.md,https://github.com/acme/widgets/pull/42",
    "set page 0",
    "set mode \"view\"",
    "set view https://github.com/acme/widgets/pull/42 github.com/acme/widgets/pull/42 failure=cli-missing",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,refresh,copy,close",
    "draw title=- focus=- stars=0",
    "state mentions=file:///repo/notes/todo.md,file:///repo/docs/plan.md,https://github.com/acme/widgets/pull/42 mode=\"view\" page=0 view=https://github.com/acme/widgets/pull/42 github.com/acme/widgets/pull/42 failure=cli-missing",
    "> show file again",
    "set view file:///repo/docs/plan.md Loading…",
    "set mentions file:///repo/notes/todo.md,https://github.com/acme/widgets/pull/42,file:///repo/docs/plan.md",
    "set page 0",
    "set mode \"view\"",
    "set view file:///repo/docs/plan.md plan.md",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0",
    "state mentions=file:///repo/notes/todo.md,https://github.com/acme/widgets/pull/42,file:///repo/docs/plan.md mode=\"view\" page=0 view=file:///repo/docs/plan.md plan.md",
    "> follow a link from the page",
    "set view file:///repo/notes/todo.md Loading…",
    "set mentions https://github.com/acme/widgets/pull/42,file:///repo/docs/plan.md,file:///repo/notes/todo.md",
    "set page 0",
    "set mode \"view\"",
    "set view file:///repo/notes/todo.md todo.md",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,back,copy,close",
    "draw title=- focus=- stars=0",
    "state mentions=https://github.com/acme/widgets/pull/42,file:///repo/docs/plan.md,file:///repo/notes/todo.md mode=\"view\" page=0 view=file:///repo/notes/todo.md todo.md",
    "> back to the page",
    "set view file:///repo/docs/plan.md plan.md",
    "set mode \"view\"",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0",
    "state mentions=https://github.com/acme/widgets/pull/42,file:///repo/docs/plan.md,file:///repo/notes/todo.md mode=\"view\" page=0 view=file:///repo/docs/plan.md plan.md"
  ],
  "navigation: open a group page, an item from it, Back, then switch modes": [
    "> switch to groups",
    "set mode \"groups\"",
    "set page 0",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,left,right,open-selected,star-selected,expand-selected,close",
    "draw title=- focus=item-0 stars=1",
    "state mentions=file:///repo/notes/todo.md,file:///repo/docs/plan.md mode=\"groups\" page=0 view=file:///repo/docs/plan.md plan.md",
    "> open group page",
    "click hover-groups-0 10,0",
    "set openGroup {\"id\":\"GROUP0\",\"item\":null}",
    "set mode \"groups\"",
    "set page 0",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,open-selected,star-selected,close",
    "draw title= Launch focus=item-0 stars=0",
    "state mentions=file:///repo/notes/todo.md,file:///repo/docs/plan.md mode=\"groups\" openGroup={\"id\":\"GROUP0\",\"item\":null} page=0 view=file:///repo/docs/plan.md plan.md",
    "> open its second item",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"notes/todo.md\"}",
    "set cursor 1",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"notes/todo.md\"}",
    "set cursor 1",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"notes/todo.md\"}",
    "set view file:///repo/notes/todo.md Loading…",
    "set mentions file:///repo/docs/plan.md,file:///repo/notes/todo.md",
    "set page 0",
    "set mode \"view\"",
    "set view file:///repo/notes/todo.md todo.md",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,back,copy,close",
    "draw title=- focus=- stars=0",
    "state cursor=1 mentions=file:///repo/docs/plan.md,file:///repo/notes/todo.md mode=\"view\" openGroup={\"id\":\"GROUP0\",\"item\":\"notes/todo.md\"} page=0 view=file:///repo/notes/todo.md todo.md",
    "> back to the group page",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"notes/todo.md\"}",
    "set mode \"groups\"",
    "set page 0",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,open-selected,star-selected,close",
    "draw title= Launch focus=item-1 stars=0",
    "state cursor=1 mentions=file:///repo/docs/plan.md,file:///repo/notes/todo.md mode=\"groups\" openGroup={\"id\":\"GROUP0\",\"item\":\"notes/todo.md\"} page=0 view=file:///repo/notes/todo.md todo.md",
    "> switch to groups from the group page",
    "set openGroup null",
    "set mode \"groups\"",
    "set page 0",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,left,right,open-selected,star-selected,expand-selected,close",
    "draw title=- focus=item-1 stars=1",
    "state cursor=1 mentions=file:///repo/docs/plan.md,file:///repo/notes/todo.md mode=\"groups\" openGroup=null page=0 view=file:///repo/notes/todo.md todo.md",
    "> switch to gallery",
    "set mode \"gallery\"",
    "set page 0",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,scope,role,type,sort,next,prev,left,right,open-selected,star-selected,close",
    "draw title=- focus=item-1 stars=0",
    "state cursor=1 mentions=file:///repo/docs/plan.md,file:///repo/notes/todo.md mode=\"gallery\" openGroup=null page=0 view=file:///repo/notes/todo.md todo.md",
    "> open group page from the menu-less message",
    "set openGroup {\"id\":\"GROUP1\",\"item\":null}",
    "set mode \"groups\"",
    "set page 0",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,open-selected,star-selected,close",
    "draw title= Spare focus=item-0 stars=0",
    "state cursor=1 mentions=file:///repo/docs/plan.md,file:///repo/notes/todo.md mode=\"groups\" openGroup={\"id\":\"GROUP1\",\"item\":null} page=0 view=file:///repo/notes/todo.md todo.md",
    "> switch to recent",
    "set mode \"recent\"",
    "set page 0",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,scope,role,next,prev,left,right,open-selected,star-selected,expand-selected,close",
    "draw title=- focus=item-1 stars=1",
    "state cursor=1 mentions=file:///repo/docs/plan.md,file:///repo/notes/todo.md mode=\"recent\" openGroup={\"id\":\"GROUP1\",\"item\":null} page=0 view=file:///repo/notes/todo.md todo.md",
    "> switch to view",
    "set mode \"view\"",
    "set page 0",
    "draw mode-view,mode-recent,mode-gallery,mode-groups,next,prev,star,open,copy,close",
    "draw title=- focus=- stars=0",
    "state cursor=1 mentions=file:///repo/docs/plan.md,file:///repo/notes/todo.md mode=\"view\" openGroup={\"id\":\"GROUP1\",\"item\":null} page=0 view=file:///repo/notes/todo.md todo.md"
  ]
}
