import { expect, mock, test } from 'claude-code/testing'
import { pullView } from './fixtures/github/items'
import { hoverLayers } from './fixtures/overlay'
import { C } from '../hooks/theme'
import { LINEAR, PAGE, PANE_PROPS, PR, call, cardTitles, create, dirOf, editGroup, fakeFs, jsonOf, savedGroup } from './fixtures/world'
import type { Found, RunAnswer, World } from './fixtures/world'


async function recentText($: Parameters<typeof call>[0] & { ui: { mount: (input: never) => Promise<{ press: (q: { key: string }) => Promise<unknown>; drawn: () => Promise<unknown>; unmount: () => Promise<void> }> } }) {
  const props = { title: 'Peek', isFocused: true, bodyColumns: 100, placement: 'dock', scroll: { offset: 0, bodyRows: 40 }, view: {} }
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' } as never)
  await ui.press({ key: 'mode-recent' })
  const text = JSON.stringify(await ui.drawn())
  await ui.unmount()
  return text
}


// Crumbs that link somewhere are drawn by a Client module, so their words live in its props.
async function trailHas(ui: { find: (q: { key: string }) => Promise<{ props: unknown } | undefined> }, pattern: RegExp) {
  const crumbs = await ui.find({ key: 'crumbs' })
  const segments = (crumbs?.props as { props?: { segments?: { text: string }[] } } | undefined)?.props?.segments ?? []
  return segments.some(one => pattern.test(one.text))
}

test('a peek group tool call is not recorded by the capture hook, while a GitHub read is', async ($, on) => {
  fakeFs(on)
  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc
  on('tool.call', async () => ({ result: [{ type: 'text', text: `see ${PR}` }] }) as never)
  const { id } = await create($, [{ target: PR }])
  await call($, 'read_group', { id })
  await call($, 'list_groups', {})
  expect(await recentText($)).not.toContain('widgets')
  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc
  await $.tool.call({ tool: 'mcp__github__get_pull_request', tool_use_id: 'c1', number: 42 } as never)
  expect(await recentText($)).toContain('widgets')
})

test('after the agent creates two groups, the Groups tab lists both as cards, starred first, then most recently updated', async ($, on) => {
  const w = fakeFs(on)
  const alpha = await create($, [{ target: PAGE }, { target: 'docs/plan.md' }], 'Alpha')
  w.now += 60_000
  await call($, 'save_group', { title: 'Beta', description: 'Ship notes\nsecond line', add: [{ target: PR }] })
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: PANE_PROPS, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  expect(await cardTitles(ui)).toEqual(['BETA', 'ALPHA'])
  expect(await ui.find({ text: /^2 groups · 0 starred$/ })).toBeDefined()
  expect(await ui.find({ text: /Ship notes/ })).toBeDefined()
  expect(await ui.find({ text: /second line/ })).toBeDefined()
  expect(await ui.find({ text: /^2 items/ })).toBeDefined()
  editGroup(w, alpha.id, group => (group.starred = true))
  await ui.redraw()
  expect(await cardTitles(ui)).toEqual(['ALPHA', 'BETA'])
  expect(await ui.find({ text: /^2 groups · 1 starred$/ })).toBeDefined()
  expect((await ui.find({ key: 'item-0' }))?.props.label).toBe('\u{f51a}')
  await ui.unmount()
})

test('the Groups tab checks the folder on every render: another session\'s change shows on the next draw', async ($, on) => {
  const w = fakeFs(on)
  const { id } = await create($, [{ target: PAGE }], 'Alpha')
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: PANE_PROPS, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  expect(await cardTitles(ui)).toEqual(['ALPHA'])
  editGroup(w, id, group => (group.title = 'Renamed elsewhere'))
  await ui.redraw()
  expect(await cardTitles(ui)).toEqual(['RENAMED ELSEWHERE'])
  await ui.unmount()
})

test('a render over an unchanged groups folder stats it but reads no group file again', async ($, on) => {
  const w = fakeFs(on)
  await create($, [{ target: PAGE }], 'Alpha')
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: PANE_PROPS, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  expect(await cardTitles(ui)).toEqual(['ALPHA'])
  const dir = dirOf('/repo/.git')
  const groupReads = () => w.reads.filter(one => one.startsWith(`${dir}/`)).length
  const dirStats = () => w.dirStats.filter(one => one === dir).length
  const [readsBefore, statsBefore] = [groupReads(), dirStats()]
  await ui.redraw()
  await ui.redraw()
  expect(await cardTitles(ui)).toEqual(['ALPHA'])
  expect(groupReads()).toBe(readsBefore)
  expect(dirStats()).toBeGreaterThan(statsBefore)
  await ui.unmount()
})

test('a group home that failed to resolve is tried again on the next call', async ($, on) => {
  const w = fakeFs(on)
  w.root = '/solo'
  w.isHomeBroken = true
  const first = await call($, 'list_groups', {}).catch((error: unknown) => `threw: ${String(error)}`)
  expect(first).not.toMatch(/^No groups in this project yet\./)
  expect(await call($, 'list_groups', {})).toMatch(/^No groups in this project yet\./)
})

test('clicking a group card opens its group page; e returns to the list; the hover star stars the group, not a file', async ($, on) => {
  const w = fakeFs(on)
  const storeKeys: string[] = []
  on('store.set', (_$, e, next) => {
    storeKeys.push(e.key)
    return next(e)
  })
  const { id } = await create($, [{ target: PAGE }], 'Alpha')
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: PANE_PROPS, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  const layer = 'hover-groups-0'
  await ui.resize({ columns: 60, rows: 1, in: layer })
  await ui.pointer({ type: 'move', x: 10, y: 0, in: layer })
  expect(JSON.stringify(await ui.drawn({ in: layer }))).toContain('\u{f41e}')
  await ui.pointer({ type: 'down', button: 'left', x: 10, y: 0, in: layer })
  expect((await ui.find({ key: 'group-page-title' }))?.text).toMatch(/Alpha/)
  await ui.press({ key: 'mode-groups' })
  expect(await ui.find({ key: 'group-page-title' })).toBeUndefined()
  expect(await cardTitles(ui)).toEqual(['ALPHA'])
  await ui.resize({ columns: 60, rows: 1, in: layer })
  const before = w.invalidated
  await ui.pointer({ type: 'down', button: 'left', x: 0, y: 0, in: layer })
  expect(savedGroup(w, id)?.starred).toBe(true)
  expect(w.invalidated).toBeGreaterThan(before)
  await ui.redraw()
  expect(await ui.find({ text: /^1 group · 1 starred$/ })).toBeDefined()
  expect(storeKeys).not.toContain('stars')
  await ui.press({ key: 'item-0' })
  expect((await ui.find({ key: 'group-page-title' }))?.text).toMatch(/Alpha/)
  await ui.unmount()
})

test('f on a selected group card toggles its star; o opens it; a deleted group is reported, never starred', async ($, on) => {
  const w = fakeFs(on)
  await create($, [{ target: PAGE }], 'Alpha')
  w.now += 60_000
  const beta = await create($, [{ target: PR }], 'Beta')
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: PANE_PROPS, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  expect((await ui.find({ key: 'star-selected' }))?.props.hotkey).toBe('f')
  await ui.press({ key: 'star-selected' })
  expect(savedGroup(w, beta.id)?.starred).toBe(true)
  await ui.press({ key: 'star-selected' })
  expect(savedGroup(w, beta.id)?.starred).toBe(false)
  await ui.press({ key: 'next' })
  await ui.press({ key: 'open-selected' })
  expect((await ui.find({ key: 'group-page-title' }))?.text).toMatch(/Alpha/)
  await ui.press({ key: 'mode-groups' })
  await ui.press({ key: 'prev' })
  delete w.files[`${dirOf('/repo/.git')}/${beta.id}.json`]
  w.touch(`${dirOf('/repo/.git')}/${beta.id}.json`)
  await ui.press({ key: 'star-selected' })
  expect(w.toasts).toContain('That group was deleted.')
  expect(savedGroup(w, beta.id)).toBeUndefined()
  await ui.unmount()
})

test('starring a card in the Groups tab keeps that group selected as the list re-sorts, so f again unstars it', async ($, on) => {
  const w = fakeFs(on)
  const alpha = await create($, [{ target: PAGE }], 'Alpha')
  w.now += 60_000
  const beta = await create($, [{ target: PR }], 'Beta')
  w.now += 60_000
  const gamma = await create($, [{ target: LINEAR }], 'Gamma')
  editGroup(w, alpha.id, group => (group.starred = true))
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: PANE_PROPS, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  expect(await cardTitles(ui)).toEqual(['ALPHA', 'GAMMA', 'BETA'])
  await ui.press({ key: 'next' })
  await ui.press({ key: 'star-selected' })
  expect(savedGroup(w, gamma.id)?.starred).toBe(true)
  await ui.redraw()
  expect(await cardTitles(ui)).toEqual(['GAMMA', 'ALPHA', 'BETA'])
  await ui.press({ key: 'star-selected' })
  expect(savedGroup(w, gamma.id)?.starred).toBe(false)
  expect(savedGroup(w, alpha.id)?.starred).toBe(true)
  expect(savedGroup(w, beta.id)?.starred).toBe(false)
  await ui.unmount()
})

test('a mouse star on another card in the Groups tab keeps the cursor on the group it was on', async ($, on) => {
  const w = fakeFs(on)
  const alpha = await create($, [{ target: PAGE }], 'Alpha')
  w.now += 60_000
  const beta = await create($, [{ target: PR }], 'Beta')
  w.now += 60_000
  const gamma = await create($, [{ target: LINEAR }], 'Gamma')
  editGroup(w, alpha.id, group => (group.starred = true))
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: PANE_PROPS, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  await ui.press({ key: 'next' })
  const layer = 'hover-groups-0'
  await ui.resize({ columns: 60, rows: 1, in: layer })
  await ui.pointer({ type: 'down', button: 'left', x: 0, y: 0, in: layer })
  expect(savedGroup(w, alpha.id)?.starred).toBe(false)
  await ui.redraw()
  expect(await cardTitles(ui)).toEqual(['GAMMA', 'BETA', 'ALPHA'])
  await ui.press({ key: 'star-selected' })
  expect(savedGroup(w, gamma.id)?.starred).toBe(true)
  expect(savedGroup(w, beta.id)?.starred).toBe(false)
  await ui.unmount()
})

async function launchGroup($: Parameters<typeof call>[0]) {
  return call($, 'save_group', {
    title: 'Launch',
    description: 'Ship it this week\nwith the notes',
    sections: [{ action: 'add', title: 'Docs' }, { action: 'add', title: 'Links', layout: 'list' }],
    add: [
      { target: 'docs/plan.md', section: 'Docs' },
      { target: 'notes/todo.md', section: 'Docs' },
      { target: '/home/notes.md', section: 'Docs' },
      { target: PAGE, section: 'Links', label: 'The page' },
    ],
  })
}

async function itemNames(ui: { find: (q: { key: string }) => Promise<Found> }, prefix: string, card: number) {
  const names: string[] = []
  for (let n = 0; n < 12; n++) {
    const one = await ui.find({ key: `${prefix}-itname-${card}-${n}` })
    if (one) names.push(one.text.trim())
  }
  return names
}

test('a compact group card shows the title, the description, the first section header and only its first row of items, then MORE', async ($, on) => {
  fakeFs(on)
  await launchGroup($)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: PANE_PROPS, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  expect((await ui.find({ key: 'group-name-0' }))?.text.trim()).toBe('LAUNCH')
  expect(await ui.find({ text: /Ship it this week/ })).toBeDefined()
  expect(await ui.find({ text: /with the notes/ })).toBeDefined()
  expect((await ui.find({ key: 'groups-sec-0-0' }))?.text).toMatch(/Docs/)
  expect(await itemNames(ui, 'groups', 0)).toEqual(['plan.md', 'todo.md'])
  expect(await ui.find({ key: 'groups-sec-0-1' })).toBeUndefined()
  expect((await ui.find({ key: 'groups-more-0' }))?.props.label).toMatch(/MORE ▼/)
  await ui.unmount()
})

test('MORE expands a card in place to every section, cards as item cards and list as lines; m and LESS collapse it', async ($, on) => {
  fakeFs(on)
  await launchGroup($)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: PANE_PROPS, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  await ui.press({ key: 'groups-more-0' })
  await ui.redraw()
  expect(await itemNames(ui, 'groups', 0)).toEqual(['plan.md', 'todo.md', 'notes.md', 'The page'])
  expect((await ui.find({ key: 'groups-sec-0-1' }))?.text).toMatch(/Links/)
  expect((await ui.find({ key: 'groups-more-0' }))?.props.label).toMatch(/LESS ▲/)
  expect(await ui.find({ key: 'groups-card-0-2' })).toBeDefined()
  expect(await ui.find({ key: 'groups-line-0-2' })).toBeUndefined()
  expect(await ui.find({ key: 'groups-line-0-3' })).toBeDefined()
  expect(await ui.find({ key: 'groups-card-0-3' })).toBeUndefined()
  expect((await ui.find({ key: 'expand-selected' }))?.props.hotkey).toBe('m')
  await $.command.run({ command: 'peek-menu' } as never)
  await ui.redraw()
  expect((await ui.find({ key: 'menu-row-key-expand-selected' }))?.text).toMatch(/Expand\/Collapse group ?m$/)
  await $.command.run({ command: 'peek-menu' } as never)
  await ui.press({ key: 'expand-selected' })
  await ui.redraw()
  expect(await itemNames(ui, 'groups', 0)).toEqual(['plan.md', 'todo.md'])
  expect((await ui.find({ key: 'groups-more-0' }))?.props.label).toMatch(/MORE ▼/)
  await ui.press({ key: 'expand-selected' })
  await ui.redraw()
  await ui.press({ key: 'groups-more-0' })
  await ui.redraw()
  expect(await itemNames(ui, 'groups', 0)).toEqual(['plan.md', 'todo.md'])
  await ui.unmount()
})

test('a group card with nothing more to show draws no MORE bar', async ($, on) => {
  fakeFs(on)
  await create($, [{ target: PAGE }], 'Alpha')
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: PANE_PROPS, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  expect(await itemNames(ui, 'groups', 0)).toEqual(['example.test/page'])
  expect(await ui.find({ key: 'groups-more-0' })).toBeUndefined()
  await ui.unmount()
})

test('clicking an item on a card opens it and Back returns to its group page with that item selected', async ($, on) => {
  fakeFs(on)
  await launchGroup($)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: PANE_PROPS, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  await ui.press({ key: 'groups-it-0-1' })
  expect(await ui.find({ key: 'group-page-title' })).toBeUndefined()
  expect(await trailHas(ui, /todo\.md/)).toBe(true)
  await ui.press({ key: 'back' })
  expect((await ui.find({ key: 'group-page-title' }))?.text).toMatch(/Launch/)
  expect(await selectedRow(ui)).toBe(1)
  await ui.press({ key: 'mode-groups' })
  const layer = 'hover-groups-items-0-0'
  await ui.resize({ columns: PANE_PROPS.bodyColumns - 11, rows: 5, in: layer })
  await ui.pointer({ type: 'down', button: 'left', x: 2, y: 2, in: layer })
  expect(await trailHas(ui, /plan\.md/)).toBe(true)
  await ui.press({ key: 'back' })
  expect(await selectedRow(ui)).toBe(0)
  await ui.unmount()
})

test('a group card spans the full text width at 60 and 100 columns', async ($, on) => {
  fakeFs(on)
  await launchGroup($)
  for (const bodyColumns of [60, 100]) {
    const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: { ...PANE_PROPS, bodyColumns }, requestId: 'peek' })
    await ui.press({ key: 'mode-groups' })
    expect((await ui.find({ key: 'groups-0' }))?.props.width).toBe(bodyColumns - 5)
    expect((await ui.find({ key: 'groups-morebar-0' }))?.props.width).toBe(bodyColumns - 9)
    await ui.unmount()
  }
})

test('a pinned card in Recent is compact and expands with MORE or m', async ($, on) => {
  const w = fakeFs(on)
  const id = String(jsonOf(await launchGroup($)).id)
  editGroup(w, id, group => (group.starred = true))
  const ui = await mountPane($)
  await ui.press({ key: 'mode-recent' })
  expect((await ui.find({ key: 'starred-sec-0-0' }))?.text).toMatch(/Docs/)
  expect(await itemNames(ui, 'starred', 0)).toEqual(['plan.md', 'todo.md'])
  await ui.press({ key: 'starred-more-0' })
  await ui.redraw()
  expect(await itemNames(ui, 'starred', 0)).toEqual(['plan.md', 'todo.md', 'notes.md', 'The page'])
  expect((await ui.find({ key: 'starred-more-0' }))?.props.label).toMatch(/LESS ▲/)
  await ui.press({ key: 'expand-selected' })
  await ui.redraw()
  expect(await itemNames(ui, 'starred', 0)).toEqual(['plan.md', 'todo.md'])
  await ui.unmount()
})

test('with no groups the tab says the agent makes them', async ($, on) => {
  fakeFs(on)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: PANE_PROPS, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  expect(await ui.find({ text: /^No groups yet\. The agent makes groups: ask it to group related files and links\.$/ })).toBeDefined()
  expect(await ui.find({ text: /^0 groups · 0 starred$/ })).toBeDefined()
  await ui.unmount()
})

test('the Groups tab is reachable from the header tab, the e key and the ctrl+k menu', async ($, on) => {
  fakeFs(on)
  await create($, [{ target: PAGE }], 'Alpha')
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: PANE_PROPS, requestId: 'peek' })
  expect((await ui.find({ key: 'mode-groups' }))?.props.hotkey).toBe('e')
  const right = await ui.find({ key: 'tabs-right' })
  const tabs = (right?.props.props as { tabs: { id: string; label: string }[] }).tabs
  expect(tabs.map(one => one.id)).toEqual(['recent', 'gallery', 'groups'])
  const before = tabs.slice(0, 2).reduce((sum, one) => sum + one.label.length, 0)
  await ui.resize({ columns: Number(right?.props.width), rows: 1, in: 'tabs-right' })
  await ui.pointer({ type: 'down', button: 'left', x: before + 2, y: 0, in: 'tabs-right' })
  expect(await cardTitles(ui)).toEqual(['ALPHA'])
  await ui.press({ key: 'mode-recent' })
  expect(await cardTitles(ui)).toEqual([])
  await ui.press({ key: 'mode-groups' })
  expect(await cardTitles(ui)).toEqual(['ALPHA'])
  await ui.press({ key: 'mode-recent' })
  await $.command.run({ command: 'peek-menu' } as never)
  await ui.redraw()
  expect((await ui.find({ key: 'menu-row-groups' }))?.text).toMatch(/e$/)
  await ui.press({ key: 'menu-groups' })
  expect(await cardTitles(ui)).toEqual(['ALPHA'])
  await $.command.run({ command: 'peek-menu' } as never)
  await ui.redraw()
  expect((await ui.find({ key: 'menu-row-key-star-selected' }))?.text).toMatch(/group ?f$/)
  expect((await ui.find({ key: 'menu-row-key-open-selected' }))?.text).toMatch(/group ?o$/)
  await ui.unmount()
})

type Node = { type?: string; props?: Record<string, unknown>; children?: unknown[] }

function textOfNode(node: unknown): string {
  if (typeof node === 'string') return node
  return ((node as Node)?.children ?? []).map(textOfNode).join('')
}

async function headerFit(ui: { drawn: () => Promise<unknown> }, bodyColumns: number) {
  const tree = (await ui.drawn()) as Node
  const pinned = (tree.children ?? []) as Node[]
  const header = (pinned.find(one => one.props?.position === 'absolute' && one.props?.top === 0)?.children?.[0] ?? {}) as Node
  const parts = (header.children ?? []) as Node[]
  const tabs = parts.filter(one => String(one.props?.key ?? '').startsWith('tabs-'))
  const tabIds = tabs.flatMap(one => ((one.props?.props as { tabs?: { id: string }[] })?.tabs ?? []).map(tab => tab.id))
  const used = parts.reduce((sum, one) => sum + (tabs.includes(one) ? Number(one.props?.width) : [...textOfNode(one)].length), 0)
  return { tabIds, used, bodyColumns }
}

test('at 60, 70 and 100 columns the header draws all four tabs and the crumb shortens so nothing overflows', async ($, on) => {
  const deep = '/repo/a-rather-long-folder-name/another-deeply-nested-folder/a-file-with-quite-a-long-name.md'
  fakeFs(on, { [deep]: '# Deep\n' })
  await $.command.run({ command: 'peek', args: deep } as never)
  for (const bodyColumns of [60, 70, 100]) {
    const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: { ...PANE_PROPS, bodyColumns }, requestId: 'peek' })
    for (const key of ['mode-view', 'mode-groups', 'mode-recent']) {
      await ui.press({ key })
      const fit = await headerFit(ui, bodyColumns)
      expect(fit.tabIds).toEqual(['view', 'recent', 'gallery', 'groups'])
      expect(fit.used).toBeLessThanOrEqual(bodyColumns - 5)
    }
    await ui.unmount()
  }
  const narrow = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: { ...PANE_PROPS, bodyColumns: 59 }, requestId: 'peek' })
  expect((await headerFit(narrow, 59)).tabIds).toEqual([])
  expect((await narrow.find({ key: 'mode-groups' }))?.props.hotkey).toBe('e')
  await narrow.unmount()
})

type PageUi = Awaited<ReturnType<typeof openFirstGroup>>

async function openFirstGroup($: { ui: { mount: (input: never) => Promise<MountedUi> } }) {
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: PANE_PROPS, requestId: 'peek' } as never)
  await ui.press({ key: 'mode-groups' })
  await ui.press({ key: 'item-0' })
  return ui
}

type MountedUi = {
  press: (q: { key: string }) => Promise<unknown>
  find: (q: { key?: string; text?: RegExp | string }) => Promise<Found>
  drawn: () => Promise<unknown>
  redraw: () => Promise<unknown>
  unmount: () => Promise<void>
}

async function rowTexts(ui: PageUi) {
  const texts: string[] = []
  for (let i = 0; i < 20; i++) {
    const one = await ui.find({ key: `group-item-${i}` })
    if (one) texts.push(one.text.trim())
  }
  return texts
}

const selectedRow = async (ui: PageUi) => {
  for (let i = 0; i < 20; i++) if ((await ui.find({ key: `item-${i}` }))?.props.autoFocus === true) return i
  return -1
}

// Remote loads run in the background of a render, so a test redraws until they land.
async function settle(ui: PageUi, isDone: () => Promise<boolean>) {
  for (let i = 0; i < 20 && !(await isDone()); i++) await ui.redraw()
}

const statusShown = (ui: PageUi, status: string) => async () => (await ui.find({ text: status })) !== undefined

function ghWorld(w: World, answer: (line: string) => Promise<RunAnswer | undefined> | RunAnswer | undefined) {
  w.onRun = argv => {
    const line = argv.join(' ')
    if (argv[0] === 'sh') return { exitCode: 0, stdout: 'gh\n' }
    if (line === 'gh auth status') return { exitCode: 0 }
    return argv[0] === 'gh' ? answer(line) : undefined
  }
}

const pull = (n: number) => `https://github.com/acme/widgets/pull/${n}`

test('a group page shows the description, the top block first, then each section header over its items; an empty section says so', async ($, on) => {
  fakeFs(on)
  await call($, 'save_group', {
    title: 'Launch',
    description: 'Everything for the launch',
    sections: [{ action: 'add', title: 'Docs' }, { action: 'add', title: 'Links' }, { action: 'add', title: 'Later' }],
    add: [
      { target: 'docs/plan.md', section: 'Docs' },
      { target: 'https://example.test/launch', section: 'Links', label: 'The launch page' },
      { target: '/home/notes.md' },
      { target: 'notes/todo.md', section: 'Docs' },
    ],
  })
  const ui = await openFirstGroup($)
  expect((await ui.find({ key: 'group-page-title' }))?.text).toMatch(/Launch/)
  expect(await ui.find({ text: /^Everything for the launch$/ })).toBeDefined()
  expect(await rowTexts(ui)).toEqual(['notes.md', 'plan.md', 'todo.md', 'The launch page'])
  expect((await ui.find({ key: 'group-section-0' }))?.text).toMatch(/DOCS/)
  expect((await ui.find({ key: 'group-section-1' }))?.text).toMatch(/LINKS/)
  expect((await ui.find({ key: 'group-section-2' }))?.text).toMatch(/LATER/)
  expect((await ui.find({ key: 'group-empty-2' }))?.text).toMatch(/empty/)
  const tree = JSON.stringify(await ui.drawn())
  const order = ['group-item-0', 'group-section-0', 'group-item-1', 'group-item-2', 'group-section-1', 'group-item-3', 'group-section-2'].map(key => tree.indexOf(`"${key}"`))
  expect(order.every(at => at >= 0)).toBe(true)
  expect([...order].sort((a, b) => a - b)).toEqual(order)
  await settle(ui, statusShown(ui, 'Launch · 4 items · 1 missing'))
  expect(await ui.find({ text: 'Launch · 4 items · 1 missing' })).toBeDefined()
  await ui.unmount()
})

test('an empty group says No items', async ($, on) => {
  fakeFs(on)
  await call($, 'save_group', { title: 'Nothing yet' })
  const ui = await openFirstGroup($)
  expect(await ui.find({ text: /^No items$/ })).toBeDefined()
  expect(await ui.find({ text: 'Nothing yet · 0 items · 0 missing' })).toBeDefined()
  await ui.unmount()
})

test('an item whose file was deleted shows as missing, stays selectable, says the file is gone when opened, and can be removed', async ($, on) => {
  const w = fakeFs(on)
  const { id } = await create($, [{ target: 'docs/plan.md' }, { target: 'notes/todo.md' }])
  delete w.files['/repo/docs/plan.md']
  const ui = await openFirstGroup($)
  expect(await ui.find({ text: 'Launch · 2 items · 1 missing' })).toBeDefined()
  expect((await ui.find({ key: 'group-meta-0' }))?.text).toMatch(/missing/)
  expect((await ui.find({ key: 'group-meta-1' }))?.text ?? '').not.toMatch(/missing/)
  expect(await selectedRow(ui)).toBe(0)
  await ui.press({ key: 'next' })
  expect(await selectedRow(ui)).toBe(1)
  await ui.press({ key: 'prev' })
  expect(await selectedRow(ui)).toBe(0)
  await ui.press({ key: 'open-selected' })
  expect(w.toasts.some(one => /gone/.test(one) && one.includes('plan.md'))).toBe(true)
  expect(await ui.find({ key: 'group-page-title' })).toBeDefined()
  const read = jsonOf(await call($, 'read_group', { id })) as { items: { ref: string; state: string }[] }
  expect(read.items.map(one => `${one.ref}:${one.state}`)).toEqual(['docs/plan.md:missing', 'notes/todo.md:ok'])
  await call($, 'save_group', { id, remove: [{ target: 'docs/plan.md' }] })
  await ui.redraw()
  expect(await rowTexts(ui)).toEqual(['todo.md'])
  expect(await ui.find({ text: 'Launch · 1 item · 0 missing' })).toBeDefined()
  await ui.unmount()
})

test('a remote item whose refresh says not found is missing; one that times out is unavailable and not counted as missing', async ($, on) => {
  const w = fakeFs(on)
  ghWorld(w, line => {
    if (/\b142\b/.test(line)) return { exitCode: 1, stderr: 'GraphQL: Could not resolve to a PullRequest with the number of 142.' }
    if (/\b143\b/.test(line)) return { exitCode: 1, stderr: 'Post "https://api.github.com/graphql": dial tcp 140.82.112.6:443: i/o timeout' }
    return undefined
  })
  const { id } = await create($, [{ target: pull(142) }, { target: pull(143) }])
  const ui = await openFirstGroup($)
  await settle(ui, async () => /unavailable/.test((await ui.find({ key: 'group-meta-1' }))?.text ?? ''))
  expect((await ui.find({ key: 'group-meta-0' }))?.text).toMatch(/missing/)
  expect((await ui.find({ key: 'group-meta-1' }))?.text).toMatch(/unavailable/)
  expect(await ui.find({ text: 'Launch · 2 items · 1 missing' })).toBeDefined()
  const read = jsonOf(await call($, 'read_group', { id })) as { items: { ref: string; state: string }[] }
  expect(read.items.map(one => one.state)).toEqual(['missing', 'unavailable'])
  await ui.unmount()
})

test('a repo-relative item added in worktree A opens worktree B\'s copy when the session runs in B', async ($, on) => {
  const w = fakeFs(on, { '/repo/docs/plan.md': '# Plan from A\n', '/wt/feature/docs/plan.md': '# Plan from B\n' })
  await create($, [{ target: 'docs/plan.md' }])
  w.root = '/wt/feature'
  const ui = await openFirstGroup($)
  expect(await rowTexts(ui)).toEqual(['plan.md'])
  await ui.press({ key: 'open-selected' })
  expect(await ui.find({ text: /Plan from B/ })).toBeDefined()
  expect(await ui.find({ text: /Plan from A/ })).toBeUndefined()
  await ui.unmount()
})

test('back from an opened item returns to the page with that item selected; if it was removed meanwhile, the nearest row', async ($, on) => {
  const w = fakeFs(on)
  const stored: unknown[] = []
  on('store.set', (_$, e, next) => {
    if (e.key === 'stars') stored.push(e.value)
    return next(e)
  })
  const { id } = await create($, [{ target: 'docs/plan.md' }, { target: 'notes/todo.md' }, { target: '/home/notes.md' }])
  const ui = await openFirstGroup($)
  await ui.press({ key: 'next' })
  await ui.press({ key: 'open-selected' })
  expect(await ui.find({ key: 'group-page-title' })).toBeUndefined()
  expect(await trailHas(ui, /todo\.md/)).toBe(true)
  await $.command.run({ command: 'peek-menu' } as never)
  await ui.redraw()
  expect((await ui.find({ key: 'menu-row-key-back' }))?.text).toMatch(/Back to Launch ?b$/)
  await $.command.run({ command: 'peek-menu' } as never)
  await ui.press({ key: 'back' })
  expect(await ui.find({ key: 'group-page-title' })).toBeDefined()
  expect(await selectedRow(ui)).toBe(1)
  await ui.press({ key: 'open-selected' })
  await call($, 'save_group', { id, remove: [{ target: 'notes/todo.md' }] })
  await ui.press({ key: 'back' })
  expect(await rowTexts(ui)).toEqual(['plan.md', 'notes.md'])
  expect(await selectedRow(ui)).toBe(1)
  await ui.press({ key: 'star-selected' })
  expect(stored.at(-1)).toEqual(['file:///home/notes.md'])
  expect(w.toasts).toEqual([])
  await ui.unmount()
})

test('a remote item with no cached title shows the agent\'s label, then its title after the refresh', async ($, on) => {
  const w = fakeFs(on)
  let release = () => {}
  const held = new Promise<void>(resolve => (release = resolve))
  ghWorld(w, async line => {
    if (line.startsWith('gh pr view 144')) {
      await held
      return { exitCode: 0, stdout: JSON.stringify(pullView({ number: 144, title: 'Teach the parser trailing commas' })) }
    }
    if (line.startsWith('gh api repos/acme/widgets/pulls/144')) return { exitCode: 0, stdout: '0' }
    return undefined
  })
  const { id } = await create($, [{ target: pull(144), label: 'Review this first' }])
  const ui = await openFirstGroup($)
  expect(await rowTexts(ui)).toEqual(['Review this first'])
  expect((jsonOf(await call($, 'read_group', { id })).items as { title: unknown }[])[0]?.title).toBeNull()
  release()
  await settle(ui, async () => (await rowTexts(ui))[0] !== 'Review this first')
  expect(await rowTexts(ui)).toEqual(['#144 Teach the parser trailing commas'])
  expect((jsonOf(await call($, 'read_group', { id })).items as { title: unknown }[])[0]?.title).toBe('#144 Teach the parser trailing commas')
  await ui.unmount()
})

test('when the open group\'s file is gone at the next render, the pane returns to the Groups tab with a toast', async ($, on) => {
  const w = fakeFs(on)
  const { id } = await create($, [{ target: 'docs/plan.md' }])
  const ui = await openFirstGroup($)
  expect(await ui.find({ key: 'group-page-title' })).toBeDefined()
  delete w.files[`${dirOf('/repo/.git')}/${id}.json`]
  w.touch(`${dirOf('/repo/.git')}/${id}.json`)
  await ui.redraw()
  await ui.redraw()
  expect(await ui.find({ key: 'group-page-title' })).toBeUndefined()
  expect(await ui.find({ text: /^No groups yet/ })).toBeDefined()
  expect(w.toasts.filter(one => one === 'That group was deleted.')).toHaveLength(1)
  await ui.unmount()
})

test('the open group\'s remote items join the background refresh', async ($, on) => {
  const clock = mock.clock(on, { now: 10 * 3600_000 })
  const w = fakeFs(on, {}, { isClockMocked: true })
  let views = 0
  ghWorld(w, line => {
    if (line.startsWith('gh pr view 145')) {
      views++
      return { exitCode: 0, stdout: JSON.stringify(pullView({ number: 145 })) }
    }
    if (line.startsWith('gh api repos/acme/widgets/pulls/145')) return { exitCode: 0, stdout: '0' }
    return undefined
  })
  await create($, [{ target: pull(145) }])
  const ui = await openFirstGroup($)
  await settle(ui, async () => views > 0 && /Teach/.test((await rowTexts(ui))[0] ?? ''))
  expect(views).toBe(1)
  await $.session.append({ message: { type: 'user', content: [{ type: 'text', text: 'still here' }] } } as never).catch(() => undefined)
  await clock.advance(5 * 60_000 + 15_000)
  expect(views).toBe(2)
  await ui.unmount()
})

async function openMenu($: { command: { run: (input: never) => Promise<unknown> } }, ui: MountedUi) {
  await $.command.run({ command: 'peek-menu' } as never)
  await ui.redraw()
}

function keysIn(node: unknown, out: string[] = []): string[] {
  const key = (node as Node)?.props?.key
  if (typeof key === 'string') out.push(key)
  for (const child of (node as Node)?.children ?? []) keysIn(child, out)
  return out
}

const menuKeys = async (ui: MountedUi, prefix: string) => keysIn(await ui.drawn()).filter(one => one.startsWith(prefix))

const menuLabel = async (ui: MountedUi, key: string) => (await ui.find({ key }))?.props.label

type MenuUi = MountedUi & { input: (q: { key: string; text: string; kind?: 'change' | 'submit' }) => Promise<unknown> }

async function mountPane($: { ui: { mount: (input: never) => Promise<unknown> } }): Promise<MenuUi> {
  return (await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: PANE_PROPS, requestId: 'peek' } as never)) as MenuUi
}

test('Star this group in the ctrl+k menu, on a group page and on a card, toggles the group star shown in the Groups tab', async ($, on) => {
  const w = fakeFs(on)
  const { id } = await create($, [{ target: 'docs/plan.md' }], 'Alpha')
  const ui = await openFirstGroup($)
  await openMenu($, ui)
  expect(await menuLabel(ui, 'menu-group-star')).toBe('Star this group')
  await ui.press({ key: 'menu-group-star' })
  expect(savedGroup(w, id)?.starred).toBe(true)
  await ui.press({ key: 'mode-groups' })
  expect(await ui.find({ text: /^1 group · 1 starred$/ })).toBeDefined()
  await openMenu($, ui)
  expect(await menuLabel(ui, 'menu-group-star')).toBe('Unstar this group')
  await ui.press({ key: 'menu-group-star' })
  expect(savedGroup(w, id)?.starred).toBe(false)
  expect(await ui.find({ text: /^1 group · 0 starred$/ })).toBeDefined()
  await ui.unmount()
})

test('adding the viewed file through ctrl+k puts it in the unsectioned block; read_group says the person added it', async ($, on) => {
  const w = fakeFs(on)
  const { id } = await create($, [{ target: PAGE }], 'Launch')
  await call($, 'save_group', { id, sections: [{ action: 'add', title: 'Docs' }], add: [{ target: PR, section: 'Docs' }] })
  await $.command.run({ command: 'peek', args: '/repo/docs/plan.md' } as never)
  const ui = await mountPane($)
  await openMenu($, ui)
  expect(await menuLabel(ui, `menu-group-add-${id}`)).toBe('Add to group: Launch')
  expect(await ui.find({ key: `menu-group-remove-${id}` })).toBeUndefined()
  await ui.press({ key: `menu-group-add-${id}` })
  expect(w.toasts).toContain('Added to Launch')
  const read = jsonOf(await call($, 'read_group', { id })) as { items: { ref: string; addedBy: string; section: string | null }[] }
  expect(read.items.find(one => one.ref === 'docs/plan.md')).toMatchObject({ addedBy: 'person', section: null })
  await ui.press({ key: 'mode-groups' })
  await ui.press({ key: 'item-0' })
  expect(await rowTexts(ui)).toContain('plan.md')
  await ui.unmount()
})

test('after the person removes an agent item from the group page, an agent re-add is skipped and reported', async ($, on) => {
  const w = fakeFs(on)
  const { id } = await create($, [{ target: 'docs/plan.md' }, { target: 'notes/todo.md' }])
  const ui = await openFirstGroup($)
  await ui.press({ key: 'next' })
  await openMenu($, ui)
  expect(await menuLabel(ui, 'menu-group-remove-here')).toBe('Remove from this group')
  await ui.press({ key: 'menu-group-remove-here' })
  expect(w.toasts).toContain('Removed from Launch')
  expect(await rowTexts(ui)).toEqual(['plan.md'])
  const text = await call($, 'save_group', { id, add: [{ target: 'notes/todo.md' }] })
  const outcome = (jsonOf(text).outcomes as { status: string; reason: string; needsForce?: boolean }[])[0]
  expect(outcome).toMatchObject({ status: 'refused', needsForce: true })
  expect(outcome?.reason).toMatch(/person removed/)
  expect(savedGroup(w, id)?.items.map(one => one.ref)).toEqual(['docs/plan.md'])
  await ui.unmount()
})

test('an agent update after the person added an item keeps that item', async ($, on) => {
  const w = fakeFs(on)
  const { id } = await create($, [{ target: PAGE }])
  await $.command.run({ command: 'peek', args: '/repo/notes/todo.md' } as never)
  const ui = await mountPane($)
  await openMenu($, ui)
  await ui.press({ key: `menu-group-add-${id}` })
  await call($, 'save_group', { id, title: 'Launch v2', sections: [{ action: 'add', title: 'Later' }], add: [{ target: 'docs/plan.md', section: 'Later' }], remove: [{ target: PAGE }] })
  expect(savedGroup(w, id)?.items).toEqual([
    expect.objectContaining({ ref: 'notes/todo.md', addedBy: 'person' }),
    expect.objectContaining({ ref: 'docs/plan.md', addedBy: 'agent' }),
  ])
  expect(savedGroup(w, id)?.title).toBe('Launch v2')
  await ui.unmount()
})

test('Remove from group shows only for groups holding the viewed item, matched by the same normalisation the agent uses', async ($, on) => {
  const w = fakeFs(on)
  const a = await create($, [{ target: 'docs/plan.md' }], 'Alpha')
  w.now += 1000
  const b = await create($, [{ target: PAGE }], 'Beta')
  w.now += 1000
  const c = await create($, [{ target: '/repo/docs/plan.md' }], 'Gamma')
  await $.command.run({ command: 'peek', args: '/repo/docs/plan.md' } as never)
  const ui = await mountPane($)
  await openMenu($, ui)
  expect(await menuKeys(ui, 'menu-group-')).toEqual([`menu-group-remove-${c.id}`, `menu-group-add-${b.id}`, `menu-group-remove-${a.id}`])
  expect(await menuLabel(ui, `menu-group-remove-${a.id}`)).toBe('Remove from group: Alpha')
  await ui.press({ key: `menu-group-remove-${a.id}` })
  expect(w.toasts).toContain('Removed from Alpha')
  expect(savedGroup(w, a.id)?.items).toEqual([])
  await openMenu($, ui)
  expect(await ui.find({ key: `menu-group-add-${a.id}` })).toBeDefined()
  await ui.unmount()
})

test('a PR read in Recent matches a group holding its /files URL; adding in Recent acts on the selected entry', async ($, on) => {
  const w = fakeFs(on)
  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc
  on('tool.call', async () => ({ result: [{ type: 'text', text: `see ${PR}` }] }) as never)
  const held = await create($, [{ target: `${PR}/files` }], 'Alpha')
  w.now += 1000
  const empty = await create($, [{ target: PAGE }], 'Beta')
  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc
  await $.tool.call({ tool: 'mcp__github__get_pull_request', tool_use_id: 'c1', number: 42 } as never)
  await $.command.run({ command: 'peek', args: '/repo/docs/plan.md' } as never)
  const ui = await mountPane($)
  await ui.press({ key: 'mode-recent' })
  await openMenu($, ui)
  expect(await menuKeys(ui, 'menu-group-')).toEqual([`menu-group-add-${empty.id}`, `menu-group-remove-${held.id}`])
  await openMenu($, ui)
  await ui.press({ key: 'next' })
  await openMenu($, ui)
  expect(await menuKeys(ui, 'menu-group-')).toEqual([`menu-group-add-${empty.id}`, `menu-group-add-${held.id}`])
  await ui.press({ key: `menu-group-add-${empty.id}` })
  expect(savedGroup(w, empty.id)?.items.map(one => one.ref)).toEqual([PAGE, 'docs/plan.md'])
  await ui.unmount()
})

test('a folder view adds the folder itself, never its .. row; an error view lists no add rows', async ($, on) => {
  const w = fakeFs(on)
  const { id } = await create($, [{ target: PAGE }], 'Alpha')
  await $.command.run({ command: 'peek', args: '/repo/docs' } as never)
  const ui = await mountPane($)
  await openMenu($, ui)
  await ui.press({ key: `menu-group-add-${id}` })
  expect(savedGroup(w, id)?.items.map(one => one.ref)).toEqual([PAGE, 'docs'])
  await $.command.run({ command: 'peek', args: 'https://example.test/broken' } as never)
  await openMenu($, ui)
  expect(await ui.find({ text: /Could not open|HTTP 404|Not found/ })).toBeDefined()
  expect(await menuKeys(ui, 'menu-group-')).toEqual([])
  await ui.unmount()
})

test('with 12 groups the menu shows 8 add rows, most recently updated first, and typing finds the others', async ($, on) => {
  const w = fakeFs(on)
  const ids: string[] = []
  for (let i = 1; i <= 12; i++) {
    w.now += 1000
    ids.push((await create($, [{ target: PAGE }], `Set ${String(i).padStart(2, '0')}`)).id)
  }
  await $.command.run({ command: 'peek', args: '/repo/docs/plan.md' } as never)
  const ui = await mountPane($)
  await openMenu($, ui)
  const shown = await menuKeys(ui, 'menu-group-add-')
  expect(shown).toEqual(ids.slice(4).reverse().map(one => `menu-group-add-${one}`))
  const rowKeys = await menuKeys(ui, 'menu-row-')
  expect(rowKeys.filter(one => one.startsWith('menu-row-group-'))).toHaveLength(8)
  expect(new Set(rowKeys).size).toBe(rowKeys.length)
  await ui.input({ key: 'menu-filter', text: 'set 02', kind: 'change' })
  expect(await menuKeys(ui, 'menu-group-add-')).toEqual([`menu-group-add-${ids[1]}`])
  await ui.input({ key: 'menu-filter', text: 'set 02' })
  expect(w.toasts).toContain('Added to Set 02')
  expect(savedGroup(w, ids[1] ?? '')?.items.map(one => one.ref)).toEqual([PAGE, 'docs/plan.md'])
  await ui.unmount()
})

test('a person add to a deleted group is refused with a toast; a failed write never says Added', async ($, on) => {
  const w = fakeFs(on)
  const gone = await create($, [{ target: PAGE }], 'Alpha')
  const kept = await create($, [{ target: PAGE }], 'Beta')
  await $.command.run({ command: 'peek', args: '/repo/docs/plan.md' } as never)
  const ui = await mountPane($)
  await openMenu($, ui)
  delete w.files[`${dirOf('/repo/.git')}/${gone.id}.json`]
  w.touch(`${dirOf('/repo/.git')}/${gone.id}.json`)
  await ui.press({ key: `menu-group-add-${gone.id}` })
  expect(w.toasts).toEqual(['That group was deleted.'])
  expect(savedGroup(w, gone.id)).toBeUndefined()
  w.isMvBroken = true
  await openMenu($, ui)
  await ui.press({ key: `menu-group-add-${kept.id}` })
  expect(w.toasts.at(-1)).toMatch(/^Could not add to Beta: /)
  expect(w.toasts.some(one => one.startsWith('Added'))).toBe(false)
  expect(savedGroup(w, kept.id)?.items.map(one => one.ref)).toEqual([PAGE])
  await ui.unmount()
})

test('an add row pressed after another writer already added the item says Already in, and adds nothing twice', async ($, on) => {
  const w = fakeFs(on)
  const { id } = await create($, [{ target: PAGE }], 'Launch')
  await $.command.run({ command: 'peek', args: '/repo/docs/plan.md' } as never)
  const ui = await mountPane($)
  await openMenu($, ui)
  editGroup(w, id, group => (group.items as unknown[]).push({ ref: 'docs/plan.md', addedBy: 'agent', addedAt: w.now }))
  await ui.press({ key: `menu-group-add-${id}` })
  expect(w.toasts).toEqual(['Already in Launch'])
  expect(savedGroup(w, id)?.items.map(one => one.ref)).toEqual([PAGE, 'docs/plan.md'])
  await ui.unmount()
})

const drawnText = async (ui: MountedUi) => JSON.stringify(await ui.drawn())

test('a starred group sits above Favourites in Recent; f on it unstars the group, not a file, and it leaves the block', async ($, on) => {
  const w = fakeFs(on)
  const storeKeys: string[] = []
  on('store.set', (_$, e, next) => {
    storeKeys.push(e.key)
    return next(e)
  })
  const alpha = await create($, [{ target: PAGE }], 'Alpha')
  w.now += 60_000
  await create($, [{ target: PR }], 'Beta')
  editGroup(w, alpha.id, group => (group.starred = true))
  await call($, 'star', { target: '/repo/docs/plan.md' })
  expect(storeKeys).toContain('stars')
  storeKeys.length = 0
  const ui = await mountPane($)
  await ui.press({ key: 'mode-recent' })
  const text = await drawnText(ui)
  expect(text.indexOf('STARRED GROUPS')).toBeGreaterThan(-1)
  expect(text.indexOf('STARRED GROUPS')).toBeLessThan(text.indexOf('FAVOURITES'))
  expect(await cardTitles(ui)).toEqual(['ALPHA'])
  expect((await ui.find({ key: 'item-0' }))?.props.label).toBe('\u{f51a}')
  expect(await ui.find({ key: 'hover-starred-0' })).toBeDefined()
  await openMenu($, ui)
  expect(await menuLabel(ui, 'menu-group-star')).toBe('Unstar this group')
  expect(await menuKeys(ui, 'menu-group-add-')).toEqual([])
  await openMenu($, ui)
  await ui.press({ key: 'star-selected' })
  expect(savedGroup(w, alpha.id)?.starred).toBe(false)
  expect(storeKeys).not.toContain('stars')
  await ui.redraw()
  expect(await drawnText(ui)).not.toContain('STARRED GROUPS')
  expect(await ui.find({ text: /FAVOURITES/ })).toBeDefined()
  await ui.unmount()
})

test('pinned group cards come first in Recent\'s keyboard order; o and a click open the group page', async ($, on) => {
  const w = fakeFs(on)
  const alpha = await create($, [{ target: PAGE }], 'Alpha')
  editGroup(w, alpha.id, group => (group.starred = true))
  await call($, 'star', { target: '/repo/docs/plan.md' })
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: PANE_PROPS, requestId: 'peek' })
  await ui.press({ key: 'mode-recent' })
  await ui.press({ key: 'open-selected' })
  expect((await ui.find({ key: 'group-page-title' }))?.text).toMatch(/Alpha/)
  await ui.press({ key: 'mode-recent' })
  await ui.press({ key: 'item-0' })
  expect((await ui.find({ key: 'group-page-title' }))?.text).toMatch(/Alpha/)
  await ui.press({ key: 'mode-recent' })
  const layer = 'hover-starred-0'
  await ui.resize({ columns: 60, rows: 1, in: layer })
  await ui.pointer({ type: 'down', button: 'left', x: 10, y: 0, in: layer })
  expect((await ui.find({ key: 'group-page-title' }))?.text).toMatch(/Alpha/)
  await ui.press({ key: 'mode-recent' })
  await ui.press({ key: 'next' })
  await ui.press({ key: 'star-selected' })
  expect(savedGroup(w, alpha.id)?.starred).toBe(true)
  await ui.redraw()
  expect(await ui.find({ text: /FAVOURITES/ })).toBeUndefined()
  await ui.unmount()
})

test('with 6 starred groups Recent pins the 4 most recently updated; the Groups tab lists all 6', async ($, on) => {
  const w = fakeFs(on)
  for (let n = 1; n <= 6; n++) {
    const { id } = await create($, [{ target: PAGE }], `Set ${n}`)
    editGroup(w, id, group => (group.starred = true))
    w.now += 60_000
  }
  const ui = await mountPane($)
  await ui.press({ key: 'mode-recent' })
  expect(await cardTitles(ui)).toEqual(['SET 6', 'SET 5', 'SET 4', 'SET 3'])
  expect(await ui.find({ text: /4 of 6/ })).toBeDefined()
  await ui.press({ key: 'mode-groups' })
  expect(await cardTitles(ui)).toHaveLength(6)
  await ui.unmount()
})

test('the pinned block ignores Recent\'s scope and role filters, shows only this project, and is absent when nothing is starred', async ($, on) => {
  const w = fakeFs(on)
  const alpha = await create($, [{ target: PAGE }], 'Alpha')
  const ui = await mountPane($)
  await ui.press({ key: 'mode-recent' })
  expect(await drawnText(ui)).not.toContain('STARRED GROUPS')
  editGroup(w, alpha.id, group => (group.starred = true))
  await ui.press({ key: 'scope' })
  await ui.press({ key: 'role' })
  expect(await ui.find({ text: /Show: artifacts/ })).toBeDefined()
  expect(await cardTitles(ui)).toEqual(['ALPHA'])
  expect(await drawnText(ui)).toContain('STARRED GROUPS')
  w.root = '/other'
  await ui.redraw()
  expect(await drawnText(ui)).not.toContain('STARRED GROUPS')
  await ui.unmount()
})

test('deleting a starred group with force removes it from Recent', async ($, on) => {
  const w = fakeFs(on)
  const alpha = await create($, [{ target: PAGE }], 'Alpha')
  editGroup(w, alpha.id, group => (group.starred = true))
  const ui = await mountPane($)
  await ui.press({ key: 'mode-recent' })
  expect(await cardTitles(ui)).toEqual(['ALPHA'])
  expect(await call($, 'delete_group', { id: alpha.id, force: true })).toMatch(/^Deleted group "Alpha"/)
  await ui.redraw()
  expect(await cardTitles(ui)).toEqual([])
  expect(await drawnText(ui)).not.toContain('STARRED GROUPS')
  await ui.unmount()
})

test('the hover star paints over group cards, every row of item cards, list rows, pinned cards and group page rows; its click stars there', async ($, on) => {
  const w = fakeFs(on)
  const launch = jsonOf(await launchGroup($)).id as string
  w.now += 60_000
  const beta = await create($, [{ target: PR }], 'Beta')
  editGroup(w, launch, group => (group.starred = true))
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: PANE_PROPS, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  await ui.press({ key: 'groups-more-0' })
  await ui.redraw()
  const tab = hoverLayers(await ui.drawn())
  expect(tab.onTop).toEqual(expect.arrayContaining(['hover-groups-0', 'hover-groups-1', 'hover-groups-items-0-0', 'hover-groups-items-0-1', 'hover-groups-items-0-2']))
  expect(tab.buried).toEqual([])

  const secondCards = 'hover-groups-items-0-1'
  await ui.resize({ columns: PANE_PROPS.bodyColumns - 11, rows: 5, in: secondCards })
  await ui.pointer({ type: 'move', x: 5, y: 3, in: secondCards })
  const card = JSON.stringify(await ui.drawn({ in: secondCards }))
  expect(card).toContain('\u{f41e}')
  expect(card).toContain('"top":1,"left":2')
  await ui.pointer({ type: 'down', button: 'left', x: 2, y: 1, in: secondCards })
  expect((await ui.find({ key: 'groups-it-0-2' }))?.props.label).toBe('\u{f51a}')

  const list = 'hover-groups-items-0-2'
  await ui.resize({ columns: PANE_PROPS.bodyColumns - 11, rows: 1, in: list })
  await ui.pointer({ type: 'move', x: 12, y: 0, in: list })
  expect(JSON.stringify(await ui.drawn({ in: list }))).toContain('\u{f41e}')

  const second = 'hover-groups-1'
  await ui.resize({ columns: 60, rows: 1, in: second })
  await ui.pointer({ type: 'move', x: 20, y: 0, in: second })
  expect(JSON.stringify(await ui.drawn({ in: second }))).toContain('\u{f41e}')
  await ui.pointer({ type: 'down', button: 'left', x: 0, y: 0, in: second })
  expect(savedGroup(w, beta.id)?.starred).toBe(true)

  await ui.press({ key: 'mode-recent' })
  const recent = hoverLayers(await ui.drawn())
  expect(recent.onTop).toContain('hover-starred-0')
  expect(recent.buried).toEqual([])

  await ui.press({ key: 'mode-groups' })
  await ui.press({ key: 'item-1' })
  expect((await ui.find({ key: 'group-page-title' }))?.text).toMatch(/Launch/)
  const page = hoverLayers(await ui.drawn())
  expect(page.onTop).toEqual(expect.arrayContaining(['hover-group-1', 'hover-group-2']))
  expect(page.buried).toEqual([])
  await ui.unmount()
})

test('the MORE bar is a quiet strip one step off the card, a blank row below the content, and a click on it still toggles', async ($, on) => {
  fakeFs(on)
  await launchGroup($)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: PANE_PROPS, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  const card = await ui.find({ key: 'groups-0' })
  const bar = await ui.find({ key: 'groups-morebar-0' })
  expect(bar?.props.backgroundColor).not.toBe(C.accent)
  expect(bar?.props.backgroundColor).not.toBe(card?.props.backgroundColor)
  expect([C.surface0, C.surface1]).toContain(bar?.props.backgroundColor)
  expect((await ui.find({ key: 'groups-more-0' }))?.props.dimColor).toBe(true)
  expect(JSON.stringify(await ui.drawn())).toContain('{"type":"Box","props":{"key":"groups-moregap-0","height":1}},{"type":"Box","props":{"key":"groups-morebar-0"')
  await ui.press({ key: 'groups-more-0' })
  await ui.redraw()
  expect((await ui.find({ key: 'groups-more-0' }))?.props.label).toMatch(/LESS ▲/)
  expect(await itemNames(ui, 'groups', 0)).toEqual(['plan.md', 'todo.md', 'notes.md', 'The page'])
  await ui.unmount()
})

test('an untitled Slack thread is named by its channel in Recent but by its address on a group page, and a group label outranks both', async ($, on) => {
  fakeFs(on)
  const thread = 'https://acme.slack.com/archives/C0123ABCD/p1700000000123456'
  const web = 'https://www.example.test/docs/start'
  await create($, [{ target: thread }, { target: web, label: 'Start here' }, { target: PR }])
  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc
  await $.tool.call({ tool: 'mcp__peek__star', tool_use_id: 's1', target: thread } as never)
  const recent = await recentText($)
  expect(recent).toContain('Thread in C0123ABCD')
  expect(recent).toContain('acme.slack.com')

  const ui = await openFirstGroup($ as never)
  const rows = await rowTexts(ui)
  expect(rows[0]).toStartWith('acme.slack.com/archives/C0123ABCD/p')
  expect(rows).toContain('Start here')
  expect(rows).not.toContain('Thread in C0123ABCD')
  expect(await ui.find({ text: /acme\/widgets/ })).toBeDefined()
  await ui.unmount()
})

const TASKS = '/repo/.peek/tasks'

function seedTask(w: World, file: string, props: Record<string, string>) {
  const path = `${TASKS}/${file}`
  w.files[path] = ['---', ...Object.entries(props).map(([key, value]) => `${key}: ${value}`), '---', ''].join('\n')
  w.touch(path)
}

async function sectionTitles(ui: PageUi) {
  const titles: string[] = []
  for (let i = 0; i < 10; i++) {
    const one = await ui.find({ key: `group-section-${i}` })
    if (one) titles.push(one.text.replace(/[─\s\d]+$/u, '').trim())
  }
  return titles
}

test('covers AE9: a rule group page shows a task an agent creates later without anyone adding it, split into status sections', async ($, on) => {
  const w = fakeFs(on)
  const { id } = await create($, [], 'Markdown views')
  editGroup(w, id, group => {
    group.rule = { parent: 'markdown-views-plan' }
    group.split = 'status'
  })
  seedTask(w, 'write-tests-aaaa1111.md', { name: 'Write tests', parent: 'markdown-views-plan', status: 'done' })
  seedTask(w, 'other-bbbb2222.md', { name: 'Unrelated', parent: 'elsewhere', status: 'todo' })
  const ui = await openFirstGroup($)
  expect(await rowTexts(ui)).toEqual(['Write tests'])
  expect(await sectionTitles(ui)).toEqual(['DONE'])
  seedTask(w, 'build-it-cccc3333.md', { name: 'Build it', parent: 'markdown-views-plan', status: 'doing' })
  seedTask(w, 'ship-it-dddd4444.md', { name: 'Ship it', parent: 'markdown-views-plan', status: 'todo' })
  await ui.redraw()
  expect(await rowTexts(ui)).toEqual(['Ship it', 'Build it', 'Write tests'])
  expect(await sectionTitles(ui)).toEqual(['TODO', 'DOING', 'DONE'])
  expect(await ui.find({ text: 'Markdown views · 3 items · 0 missing' })).toBeDefined()
  expect(savedGroup(w, id)?.items).toEqual([])
  await ui.press({ key: 'mode-groups' })
  await ui.press({ key: 'mode-groups' })
  expect(await ui.find({ text: /^3 items/ })).toBeDefined()
  await ui.unmount()
})

test('the person removing a rule-matched task from the group page keeps it out while the rule still matches', async ($, on) => {
  const w = fakeFs(on)
  const { id } = await create($, [], 'Agent one')
  editGroup(w, id, group => (group.rule = { creator: 'agent-1' }))
  seedTask(w, 'a-aaaa1111.md', { name: 'First', creator: 'agent-1' })
  seedTask(w, 'b-bbbb2222.md', { name: 'Second', creator: 'agent-1' })
  const ui = await openFirstGroup($)
  expect(await rowTexts(ui)).toEqual(['First', 'Second'])
  await ui.press({ key: 'next' })
  await openMenu($, ui)
  await ui.press({ key: 'menu-group-remove-here' })
  expect(w.toasts).toContain('Removed from Agent one')
  expect(savedGroup(w, id)).toMatchObject({ items: [], removed: ['.peek/tasks/b-bbbb2222.md'] })
  seedTask(w, 'b-bbbb2222.md', { name: 'Second', creator: 'agent-1', status: 'doing' })
  await ui.redraw()
  expect(await rowTexts(ui)).toEqual(['First'])
  await ui.unmount()
})

test('a group with a hand-added task and a rule matching it shows the task once, with the rule\'s other matches', async ($, on) => {
  const w = fakeFs(on)
  seedTask(w, 'a-aaaa1111.md', { name: 'First', creator: 'agent-1' })
  seedTask(w, 'b-bbbb2222.md', { name: 'Second', creator: 'agent-1' })
  const { id } = await create($, [{ target: `${TASKS}/a-aaaa1111.md` }, { target: 'docs/plan.md' }], 'Mixed')
  editGroup(w, id, group => (group.rule = { creator: 'agent-1' }))
  const ui = await openFirstGroup($)
  expect(await rowTexts(ui)).toEqual(['a-aaaa1111.md', 'plan.md', 'Second'])
  expect(await ui.find({ text: 'Mixed · 3 items · 0 missing' })).toBeDefined()
  await ui.unmount()
})

test('a group split by creator draws one section per creator, and a hand-added item with no creator last', async ($, on) => {
  const w = fakeFs(on)
  const { id } = await create($, [{ target: 'docs/plan.md' }], 'By creator')
  editGroup(w, id, group => {
    group.rule = { isTask: 'true' }
    group.split = 'creator'
  })
  seedTask(w, 'a-aaaa1111.md', { name: 'Zed one', creator: 'zed', isTask: 'true' })
  seedTask(w, 'b-bbbb2222.md', { name: 'Amy one', creator: 'amy', isTask: 'true' })
  seedTask(w, 'c-cccc3333.md', { name: 'Zed two', creator: 'zed', isTask: 'true' })
  const ui = await openFirstGroup($)
  expect(await sectionTitles(ui)).toEqual(['AMY', 'ZED', 'NONE'])
  expect(await rowTexts(ui)).toEqual(['Amy one', 'Zed one', 'Zed two', 'plan.md'])
  await ui.unmount()
})

test('a group file from before rules loads unchanged, and an agent save writes back only what it changed', async ($, on) => {
  const w = fakeFs(on)
  const old = {
    projectKey: '/repo/.git',
    id: 'abcd1234',
    title: 'Old group',
    description: 'From before rules',
    starred: false,
    updatedAt: 1,
    sections: [{ id: 's1', title: 'Docs', layout: 'cards' }],
    items: [{ ref: 'docs/plan.md', section: 's1', addedBy: 'agent', addedAt: 1 }],
    removed: [],
  }
  const file = `${dirOf('/repo/.git')}/abcd1234.json`
  w.files[file] = JSON.stringify(old, null, 2)
  w.touch(file)
  const ui = await openFirstGroup($)
  expect(await rowTexts(ui)).toEqual(['plan.md'])
  expect(await sectionTitles(ui)).toEqual(['DOCS'])
  const read = jsonOf(await call($, 'read_group', { id: 'abcd1234' }))
  expect('rule' in read || 'split' in read).toBe(false)
  const saved = await call($, 'save_group', { id: 'abcd1234', add: [{ target: 'notes/todo.md' }] })
  expect(saved.split('\n')[0]).toMatch(/1 applied, 0 unchanged, 0 refused/)
  expect(JSON.parse(w.files[file] ?? '{}')).toEqual({ ...old, updatedAt: w.now, items: [...old.items, { ref: 'notes/todo.md', addedBy: 'agent', addedAt: w.now }] })
  await ui.unmount()
})

test('a group file with an unreadable rule or split still loads, without them', async ($, on) => {
  const w = fakeFs(on)
  const { id } = await create($, [{ target: 'docs/plan.md' }], 'Broken rule')
  editGroup(w, id, group => {
    group.rule = 'parent=x'
    group.split = 7
  })
  seedTask(w, 'a-aaaa1111.md', { name: 'First', parent: 'x' })
  const ui = await openFirstGroup($)
  expect(await rowTexts(ui)).toEqual(['plan.md'])
  await ui.unmount()
})

test('a rule group also picks up a tracked doc marked isTask outside the tasks folder', async ($, on) => {
  const w = fakeFs(on)
  const { id } = await create($, [], 'Spec work')
  editGroup(w, id, group => (group.rule = { parent: 'spec' }))
  w.tracked = { '/repo': ['docs/spec-task.md', 'docs/plan.md'] }
  w.files['/repo/docs/spec-task.md'] = '---\nname: Spec the API\nisTask: true\nparent: spec\n---\n'
  w.touch('/repo/docs/spec-task.md')
  const ui = await openFirstGroup($)
  expect(await rowTexts(ui)).toEqual(['Spec the API'])
  expect(savedGroup(w, id)?.items).toEqual([])
  await ui.unmount()
})
