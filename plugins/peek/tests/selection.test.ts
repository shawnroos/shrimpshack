import { expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'
import type { Engine, Mounted } from 'claude-code/testing'
import { PANE_PROPS, call, create, editGroup, fakeFs } from './fixtures/world'
import type { World } from './fixtures/world'

// Selection and scroll on every list screen and the reader. The kit raises no ui.scroll or ui.focus for the
// plugin's own $.ui.scroll and $.ui.focus, so those calls cannot be recorded here. What pins them instead:
// - the item each draw marks selected (the autoFocus item-N button and the keyed boxes around it, one of which
//   is the row the scroll call names), with the cursor and openGroup writes each press makes;
// - the reader's footer position, which the draw computes from the block starts, headings and row estimate it
//   keeps for the jump keys;
// - the first reader draw after a list screen, whose § heading follows the list's row estimate (the scale).

type Ui = Mounted<'terminal', 'Pane'>
type Node = { type?: string; props?: Record<string, unknown>; children?: unknown[] }
type Run = { $: Engine; ui: Ui; w: World; log: string[]; ids: string[] }

const settleMicrotasks = async () => {
  for (let i = 0; i < 1000; i += 1) await Promise.resolve()
}

// One H2 heading per block, one row each: block i starts at row 2i, so the § a draw shows names its top block.
const LONG = Array.from({ length: 120 }, (_, i) => `## H${i}`).join('\n\n')

function short(key: string, value: unknown) {
  if (key === 'view') return (value as { href?: string } | null)?.href ?? 'null'
  if (key === 'mentions') return `${(value as unknown[]).length}`
  return JSON.stringify(value) ?? 'undefined'
}

function normalized(text: string, ids: readonly string[]) {
  return ids.reduce((all, id, index) => all.split(id).join(`GROUP${index}`), text)
}

function walk(node: unknown, visit: (one: Node, keys: readonly string[]) => void, keys: readonly string[] = []) {
  if (!node || typeof node !== 'object') return
  const one = node as Node
  visit(one, keys)
  const key = one.props?.key
  const inner = typeof key === 'string' ? [...keys, key] : keys
  for (const child of one.children ?? []) walk(child, visit, inner)
}

function textOf(node: unknown): string {
  if (typeof node === 'string') return node
  if (!node || typeof node !== 'object') return ''
  return ((node as Node).children ?? []).map(textOf).join('')
}

// The selected item as drawn: its autoFocus button, the keyed boxes it sits in, and the name drawn beside it.
async function selection(ui: Ui) {
  const tree = await ui.drawn()
  const marks: string[] = []
  walk(tree, (one, keys) => {
    const key = String(one.props?.key ?? '')
    if (one.type === 'Button' && one.props?.autoFocus === true) marks.push(`focus ${key} in ${keys.filter(k => !/^(page|body|content)$/.test(k)).join('/')}`)
  })
  const at = /^item-(\d+)$/.exec(marks[0]?.split(' ')[1] ?? '')?.[1]
  if (at !== undefined) {
    for (const key of [`group-item-${at}`, `name-${at}`, `group-name-${at}`]) {
      const named = await ui.find({ key })
      if (named) marks.push(`name ${named.text.trim()}`)
    }
  }
  return marks.length ? marks : ['focus none']
}

async function info(ui: Ui) {
  let found = ''
  walk(await ui.drawn(), one => {
    if (found || !(one.children ?? []).some(child => (child as Node).props?.key === 'footer-keys')) return
    const first = (one.children ?? [])[0] as Node | undefined
    if (first?.type === 'Text' && !textOf(first).includes('⌃k')) found = textOf(first)
  })
  return `info ${found}`
}

function watching(on: On) {
  const log: string[] = []
  on('state.set', (_$, e, next) => {
    const write = e as { key: string; value: unknown }
    const line = `set ${write.key} ${short(write.key, write.value)}`
    // A write that repeats the one just before it leaves the screen as it was, so it is not told apart.
    if (!['menuOpen', 'menuFilter'].includes(write.key) && log.at(-1) !== line) log.push(line)
    return next(e)
  })
  on('ui.scroll', () => ({}))
  on('ui.focus', () => ({}))
  return log
}

async function mounted($: Engine, on: On, columns = 100): Promise<Run> {
  const w = fakeFs(on, {
    '/repo/a.md': 'a\n',
    '/repo/b.md': 'b\n',
    '/repo/c.md': 'c\n',
    '/repo/d.md': 'd\n',
    '/repo/docs/long.md': `${LONG}\n`,
  })
  const log = watching(on)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: { ...PANE_PROPS, bodyColumns: columns }, requestId: 'peek' })
  return { $, ui, w, log, ids: [] }
}

// The kit's own ui.scroll and ui.focus take the person's events whole: origin, element and offsets.
const personUi = (run: Run) => run.$.ui as unknown as { scroll: (e: unknown) => Promise<unknown>; focus: (e: unknown) => Promise<unknown> }

// A press, a person's wheel, focus or message, then what the next draw selects.
async function step(run: Run, what: string, act: () => Promise<unknown>) {
  run.log.splice(0)
  run.w.toasts.splice(0)
  await act()
  await settleMicrotasks()
  await run.ui.redraw()
  return [`> ${what}`, ...run.log.map(one => normalized(one, run.ids)), ...run.w.toasts.map(one => `toast ${one}`), ...(await selection(run.ui))]
}

const press = (run: Run, key: string) => step(run, key, async () => {
  if (!(await run.ui.find({ key }))) run.log.push(`no ${key} drawn`)
  else await run.ui.press({ key })
})

const wheel = (run: Run, by: number) =>
  step(run, `wheel ${by}`, () => personUi(run).scroll({ component: 'Pane', requestId: 'peek', offset: 0, by, bodyRows: 40, contentRows: 80, origin: { kind: 'person' } }))

const focus = (run: Run, element: string) =>
  step(run, `focus ${element}`, () => personUi(run).focus({ component: 'Pane', requestId: 'peek', element, origin: { kind: 'person' } }))

// A scroll the person makes with the given content height: it sets the page and the rows the next draw scales by.
async function scrolled(run: Run, offset: number, contentRows: number) {
  await personUi(run).scroll({ component: 'Pane', requestId: 'peek', offset, by: 3, bodyRows: 40, contentRows, origin: { kind: 'person' } })
  await settleMicrotasks()
  await run.ui.redraw()
}

// The list's row estimate, read through the first reader draw after it: realBody is one row, so the scale is
// 1 / estimate and the top block is the last whose start is within the estimate.
async function estimateAfter(run: Run) {
  await scrolled(run, 0, 8)
  await run.$.command.run({ command: 'peek', args: '/repo/docs/long.md' } as never)
  await settleMicrotasks()
  await run.ui.redraw()
  return [`> long.md after the list`, await info(run.ui)]
}

async function threeItemGroup(run: Run, title = 'Launch') {
  const { id } = await create(run.$ as never, [{ target: 'a.md' }, { target: 'b.md' }, { target: 'c.md' }], title)
  run.ids.push(id)
  return id
}

const EXPECTED: Record<string, string[]> = {
  "group page via o": [
    "> mode-groups",
    "set mode \"groups\"",
    "set page 0",
    "focus item-0 in groups-0",
    "name LAUNCH",
    "> open-selected",
    "set openGroup {\"id\":\"GROUP0\",\"item\":null}",
    "set mode \"groups\"",
    "set page 0",
    "focus item-0 in group-top/group-block-0/group-row-0",
    "name a.md",
    "> next",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"b.md\"}",
    "set cursor 1",
    "focus item-1 in group-top/group-block-0/group-row-1",
    "name b.md",
    "> next",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"c.md\"}",
    "set cursor 2",
    "focus item-2 in group-top/group-block-0/group-row-2",
    "name c.md",
    "> next",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"c.md\"}",
    "set cursor 2",
    "focus item-2 in group-top/group-block-0/group-row-2",
    "name c.md",
    "> prev",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"b.md\"}",
    "set cursor 1",
    "focus item-1 in group-top/group-block-0/group-row-1",
    "name b.md",
    "> left",
    "no left drawn",
    "focus item-1 in group-top/group-block-0/group-row-1",
    "name b.md",
    "> right",
    "no right drawn",
    "focus item-1 in group-top/group-block-0/group-row-1",
    "name b.md",
    "> prev",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"a.md\"}",
    "set cursor 0",
    "focus item-0 in group-top/group-block-0/group-row-0",
    "name a.md",
    "> prev",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"a.md\"}",
    "set cursor 0",
    "focus item-0 in group-top/group-block-0/group-row-0",
    "name a.md",
    "> wheel 1",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"b.md\"}",
    "set cursor 1",
    "focus item-1 in group-top/group-block-0/group-row-1",
    "name b.md",
    "> wheel 1",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"c.md\"}",
    "set cursor 2",
    "focus item-2 in group-top/group-block-0/group-row-2",
    "name c.md",
    "> wheel -1",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"b.md\"}",
    "set cursor 1",
    "focus item-1 in group-top/group-block-0/group-row-1",
    "name b.md",
    "> focus item-2",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"c.md\"}",
    "set cursor 2",
    "focus item-2 in group-top/group-block-0/group-row-2",
    "name c.md",
    "> prev",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"b.md\"}",
    "set cursor 1",
    "focus item-1 in group-top/group-block-0/group-row-1",
    "name b.md",
    "> focus item-0",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"a.md\"}",
    "set cursor 0",
    "focus item-0 in group-top/group-block-0/group-row-0",
    "name a.md",
    "> open message for b.md",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"b.md\"}",
    "set cursor 1",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"b.md\"}",
    "set view file:///repo/b.md",
    "set mentions 1",
    "set page 0",
    "set mode \"view\"",
    "set view file:///repo/b.md",
    "focus none",
    "> back",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"b.md\"}",
    "set mode \"groups\"",
    "set page 0",
    "focus item-1 in group-top/group-block-0/group-row-1",
    "name b.md",
    "> star-selected",
    "set stars [\"file:///repo/b.md\"]",
    "focus item-1 in group-top/group-block-0/group-row-1",
    "name b.md",
    "> open-selected",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"b.md\"}",
    "set cursor 1",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"b.md\"}",
    "set view file:///repo/b.md",
    "set mentions 1",
    "set page 0",
    "set mode \"view\"",
    "set view file:///repo/b.md",
    "focus none",
    "> back",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"b.md\"}",
    "set mode \"groups\"",
    "set page 0",
    "focus item-1 in group-top/group-block-0/group-row-1",
    "name b.md",
    "> long.md after the list",
    "info 100% · § H4"
  ],
  "group page via a card item": [
    "> mode-groups",
    "set mode \"groups\"",
    "set page 0",
    "focus item-0 in groups-0",
    "name BETA",
    "> next",
    "set cursor 1",
    "focus item-1 in groups-1",
    "name ALPHA",
    "> groups-it-0-1",
    "set cursor 0",
    "set openGroup {\"id\":\"GROUP1\",\"item\":\"b.md\"}",
    "set view file:///repo/b.md",
    "set mentions 1",
    "set page 0",
    "set mode \"view\"",
    "set view file:///repo/b.md",
    "focus none",
    "> back",
    "set openGroup {\"id\":\"GROUP1\",\"item\":\"b.md\"}",
    "set mode \"groups\"",
    "set page 0",
    "focus item-1 in group-top/group-block-0/group-row-1",
    "name b.md",
    "> next",
    "set openGroup {\"id\":\"GROUP1\",\"item\":\"c.md\"}",
    "set cursor 2",
    "focus item-2 in group-top/group-block-0/group-row-2",
    "name c.md",
    "> mode-groups",
    "set openGroup null",
    "set mode \"groups\"",
    "set page 0",
    "focus none",
    "> groups-it-0-1",
    "set cursor 0",
    "set openGroup {\"id\":\"GROUP1\",\"item\":\"b.md\"}",
    "set view file:///repo/b.md",
    "set mentions 1",
    "set page 0",
    "set mode \"view\"",
    "set view file:///repo/b.md",
    "focus none",
    "> b.md removed by another session",
    "focus none",
    "> back",
    "set openGroup {\"id\":\"GROUP1\",\"item\":\"b.md\"}",
    "set mode \"groups\"",
    "set page 0",
    "focus item-0 in group-top/group-block-0/group-row-0",
    "name a.md",
    "> prev",
    "set openGroup {\"id\":\"GROUP1\",\"item\":\"a.md\"}",
    "set cursor 0",
    "focus item-0 in group-top/group-block-0/group-row-0",
    "name a.md",
    "> next",
    "set openGroup {\"id\":\"GROUP1\",\"item\":\"c.md\"}",
    "set cursor 1",
    "focus item-1 in group-top/group-block-0/group-row-1",
    "name c.md"
  ],
  "item removed between draws": [
    "> mode-groups",
    "set mode \"groups\"",
    "set page 0",
    "focus item-0 in groups-0",
    "name LAUNCH",
    "> open-selected",
    "set openGroup {\"id\":\"GROUP1\",\"item\":null}",
    "set mode \"groups\"",
    "set page 0",
    "focus item-0 in group-top/group-block-0/group-row-0",
    "name a.md",
    "> next",
    "set openGroup {\"id\":\"GROUP1\",\"item\":\"b.md\"}",
    "set cursor 1",
    "focus item-1 in group-top/group-block-0/group-row-1",
    "name b.md",
    "> next",
    "set openGroup {\"id\":\"GROUP1\",\"item\":\"c.md\"}",
    "set cursor 2",
    "focus item-2 in group-top/group-block-0/group-row-2",
    "name c.md",
    "> a.md removed",
    "focus item-1 in group-top/group-block-0/group-row-1",
    "name c.md",
    "> prev",
    "set openGroup {\"id\":\"GROUP1\",\"item\":\"b.md\"}",
    "set cursor 0",
    "focus item-0 in group-top/group-block-0/group-row-0",
    "name b.md",
    "> next",
    "set openGroup {\"id\":\"GROUP1\",\"item\":\"c.md\"}",
    "set cursor 1",
    "focus item-1 in group-top/group-block-0/group-row-1",
    "name c.md",
    "> c.md removed",
    "focus item-0 in group-top/group-block-0/group-row-0",
    "name b.md",
    "> redraw",
    "focus item-0 in group-top/group-block-0/group-row-0",
    "name b.md",
    "> next",
    "set openGroup {\"id\":\"GROUP1\",\"item\":\"b.md\"}",
    "set cursor 0",
    "focus item-0 in group-top/group-block-0/group-row-0",
    "name b.md",
    "> prev",
    "set openGroup {\"id\":\"GROUP1\",\"item\":\"b.md\"}",
    "set cursor 0",
    "focus item-0 in group-top/group-block-0/group-row-0",
    "name b.md",
    "> every item removed",
    "focus none",
    "> next",
    "focus none",
    "> prev",
    "focus none",
    "> star-selected",
    "focus none",
    "> open-selected",
    "toast That file is gone: ",
    "focus none",
    "> a.md, b.md and c.md added",
    "focus item-1 in group-top/group-block-0/group-row-1",
    "name b.md",
    "> next",
    "set openGroup {\"id\":\"GROUP1\",\"item\":\"c.md\"}",
    "set cursor 2",
    "focus item-2 in group-top/group-block-0/group-row-2",
    "name c.md",
    "> next",
    "set openGroup {\"id\":\"GROUP1\",\"item\":\"c.md\"}",
    "set cursor 2",
    "focus item-2 in group-top/group-block-0/group-row-2",
    "name c.md",
    "> mode-view",
    "set mode \"view\"",
    "set page 0",
    "focus none",
    "> c.md removed while the page is not shown",
    "focus none",
    "> mode-groups",
    "set mode \"groups\"",
    "set page 0",
    "focus item-1 in group-top/group-block-0/group-row-1",
    "name b.md",
    "> prev",
    "set openGroup {\"id\":\"GROUP1\",\"item\":\"a.md\"}",
    "set cursor 0",
    "focus item-0 in group-top/group-block-0/group-row-0",
    "name a.md"
  ],
  "groups tab, expanded cards": [
    "> mode-groups",
    "set mode \"groups\"",
    "set page 0",
    "focus item-0 in groups-0",
    "name THREE",
    "> expand-selected",
    "focus item-0 in groups-0",
    "name THREE",
    "> next",
    "set cursor 1",
    "focus item-1 in groups-1",
    "name TWO",
    "> expand-selected",
    "focus item-1 in groups-1",
    "name TWO",
    "> next",
    "set cursor 2",
    "focus item-2 in groups-2",
    "name ONE",
    "> next",
    "set cursor 2",
    "focus item-2 in groups-2",
    "name ONE",
    "> prev",
    "set cursor 1",
    "focus item-1 in groups-1",
    "name TWO",
    "> left",
    "set cursor 1",
    "focus item-1 in groups-1",
    "name TWO",
    "> right",
    "set cursor 1",
    "focus item-1 in groups-1",
    "name TWO",
    "> prev",
    "set cursor 0",
    "focus item-0 in groups-0",
    "name THREE",
    "> prev",
    "set cursor 0",
    "focus item-0 in groups-0",
    "name THREE",
    "> wheel 1",
    "set cursor 1",
    "focus item-1 in groups-1",
    "name TWO",
    "> focus item-2",
    "set cursor 2",
    "focus item-2 in groups-2",
    "name ONE",
    "> star-selected",
    "set cursor 0",
    "focus item-0 in groups-0",
    "name ONE",
    "> long.md after the list",
    "info 100% · § H24"
  ],
  "recent with pinned groups": [
    "> mode-recent",
    "set mode \"recent\"",
    "set page 0",
    "focus item-0 in starred-0",
    "name PINNED TWO",
    "> star-selected",
    "focus item-0 in starred-0",
    "name PINNED ONE",
    "> expand-selected",
    "focus item-0 in starred-0",
    "name PINNED ONE",
    "> next",
    "set cursor 1",
    "focus item-1 in group-touched/touched-0/touched-0-0",
    "name d.md",
    "> next",
    "set cursor 2",
    "focus item-2 in group-touched/touched-0/touched-0-1",
    "name c.md",
    "> next",
    "set cursor 3",
    "focus item-3 in group-touched/touched-0/touched-0-2",
    "name b.md",
    "> next",
    "set cursor 4",
    "focus item-4 in group-touched/touched-0/touched-0-3",
    "name a.md",
    "> left",
    "set cursor 4",
    "focus item-4 in group-touched/touched-0/touched-0-3",
    "name a.md",
    "> right",
    "set cursor 4",
    "focus item-4 in group-touched/touched-0/touched-0-3",
    "name a.md",
    "> next",
    "set cursor 4",
    "focus item-4 in group-touched/touched-0/touched-0-3",
    "name a.md",
    "> next",
    "set cursor 4",
    "focus item-4 in group-touched/touched-0/touched-0-3",
    "name a.md",
    "> next",
    "set cursor 4",
    "focus item-4 in group-touched/touched-0/touched-0-3",
    "name a.md",
    "> next",
    "set cursor 4",
    "focus item-4 in group-touched/touched-0/touched-0-3",
    "name a.md",
    "> prev",
    "set cursor 3",
    "focus item-3 in group-touched/touched-0/touched-0-2",
    "name b.md",
    "> prev",
    "set cursor 2",
    "focus item-2 in group-touched/touched-0/touched-0-1",
    "name c.md",
    "> wheel -1",
    "set cursor 1",
    "focus item-1 in group-touched/touched-0/touched-0-0",
    "name d.md",
    "> focus item-1",
    "set cursor 1",
    "focus item-1 in group-touched/touched-0/touched-0-0",
    "name d.md",
    "> open-selected",
    "set view file:///repo/d.md",
    "set mentions 4",
    "set page 0",
    "set mode \"view\"",
    "set view file:///repo/d.md",
    "focus none",
    "> mode-recent",
    "set mode \"recent\"",
    "set page 0",
    "focus item-1 in group-touched/touched-0/touched-0-0",
    "name d.md",
    "> long.md after the list",
    "info 100% · § H14"
  ],
  "gallery wrapped": [
    "> mode-gallery",
    "set mode \"gallery\"",
    "set page 0",
    "focus item-0 in group-touched/touched-0/touched-0-0",
    "name d.md",
    "> right",
    "set cursor 1",
    "focus item-1 in group-touched/touched-0/touched-0-1",
    "name c.md",
    "> right",
    "set cursor 1",
    "focus item-1 in group-touched/touched-0/touched-0-1",
    "name c.md",
    "> right",
    "set cursor 1",
    "focus item-1 in group-touched/touched-0/touched-0-1",
    "name c.md",
    "> next",
    "set cursor 3",
    "focus item-3 in group-touched/touched-1/touched-1-1",
    "name a.md",
    "> next",
    "set cursor 3",
    "focus item-3 in group-touched/touched-1/touched-1-1",
    "name a.md",
    "> left",
    "set cursor 2",
    "focus item-2 in group-touched/touched-1/touched-1-0",
    "name b.md",
    "> left",
    "set cursor 2",
    "focus item-2 in group-touched/touched-1/touched-1-0",
    "name b.md",
    "> prev",
    "set cursor 0",
    "focus item-0 in group-touched/touched-0/touched-0-0",
    "name d.md",
    "> right",
    "set cursor 1",
    "focus item-1 in group-touched/touched-0/touched-0-1",
    "name c.md",
    "> next",
    "set cursor 3",
    "focus item-3 in group-touched/touched-1/touched-1-1",
    "name a.md",
    "> prev",
    "set cursor 1",
    "focus item-1 in group-touched/touched-0/touched-0-1",
    "name c.md",
    "> prev",
    "set cursor 1",
    "focus item-1 in group-touched/touched-0/touched-0-1",
    "name c.md",
    "> wheel 1",
    "set cursor 3",
    "focus item-3 in group-touched/touched-1/touched-1-1",
    "name a.md",
    "> focus item-3",
    "set cursor 3",
    "focus item-3 in group-touched/touched-1/touched-1-1",
    "name a.md",
    "> star-selected",
    "set stars [\"file:///repo/a.md\"]",
    "focus item-3 in group-touched/touched-1/touched-1-0",
    "name b.md",
    "> next",
    "set cursor 3",
    "focus item-3 in group-touched/touched-1/touched-1-0",
    "name b.md",
    "> long.md after the list",
    "info 100% · § H13"
  ],
  "long markdown": [
    "info 100% · § H0",
    "> next",
    "focus none",
    "> prev",
    "focus none",
    "> left",
    "no left drawn",
    "focus none",
    "> right",
    "no right drawn",
    "focus none",
    "> scrolled to 0 of 300",
    "set page 0",
    "info 0% · § H0",
    "> scrolled to 3 of 300",
    "set page 3",
    "info 1% · § H1",
    "> scrolled to 10 of 300",
    "set page 10",
    "info 4% · § H4",
    "> scrolled to 57 of 300",
    "set page 57",
    "info 22% · § H23",
    "> scrolled to 400 of 300",
    "set page 260",
    "info 100% · § H106",
    "> scrolled to 20 of 150",
    "set page 20",
    "info 18% · § H17",
    "> scrolled to 20 of 60",
    "set page 20",
    "info 100% · § H47",
    "> next",
    "focus none",
    "> prev",
    "focus none"
  ],
  "pinned card item removed": [
    "> mode-groups",
    "set mode \"groups\"",
    "set page 0",
    "focus item-0 in groups-0",
    "name PINNED",
    "> open-selected",
    "set openGroup {\"id\":\"GROUP0\",\"item\":null}",
    "set mode \"groups\"",
    "set page 0",
    "focus item-0 in group-top/group-block-0/group-row-0",
    "name a.md",
    "> next",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"b.md\"}",
    "set cursor 1",
    "focus item-1 in group-top/group-block-0/group-row-1",
    "name b.md",
    "> next",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"c.md\"}",
    "set cursor 2",
    "focus item-2 in group-top/group-block-0/group-row-2",
    "name c.md",
    "> mode-recent",
    "set mode \"recent\"",
    "set page 0",
    "focus none",
    "> starred-it-0-0",
    "set cursor 0",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"a.md\"}",
    "set view file:///repo/a.md",
    "set mentions 1",
    "set page 0",
    "set mode \"view\"",
    "set view file:///repo/a.md",
    "focus none",
    "> a.md removed",
    "focus none",
    "> back",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"a.md\"}",
    "set mode \"groups\"",
    "set page 0",
    "focus item-1 in group-top/group-block-0/group-row-1",
    "name c.md",
    "> prev",
    "set openGroup {\"id\":\"GROUP0\",\"item\":\"b.md\"}",
    "set cursor 0",
    "focus item-0 in group-top/group-block-0/group-row-0",
    "name b.md"
  ]
}

function check(name: string, lines: string[]) {
  expect(lines).toEqual(EXPECTED[name])
}

test('group page entered with o: j, k, h, l, the wheel, a focus and an open message move and open the selection', async (e, on) => {
  const run = await mounted(e, on)
  await threeItemGroup(run)
  const lines: string[] = []
  lines.push(...(await press(run, 'mode-groups')))
  lines.push(...(await press(run, 'open-selected')))
  for (const key of ['next', 'next', 'next', 'prev', 'left', 'right', 'prev', 'prev']) lines.push(...(await press(run, key)))
  lines.push(...(await wheel(run, 1)))
  lines.push(...(await wheel(run, 1)))
  lines.push(...(await wheel(run, -1)))
  lines.push(...(await focus(run, 'item-2')))
  lines.push(...(await press(run, 'prev')))
  lines.push(...(await focus(run, 'item-0')))
  lines.push(...(await step(run, 'open message for b.md', () => run.ui.post({ open: 'file:///repo/b.md' }, { in: 'hover-group-0' }))))
  lines.push(...(await press(run, 'back')))
  lines.push(...(await press(run, 'star-selected')))
  lines.push(...(await press(run, 'open-selected')))
  lines.push(...(await press(run, 'back')))
  lines.push(...(await estimateAfter(run)))
  await run.ui.unmount()
  check('group page via o', lines)
})

test('group page entered from a card item and Back: the selection starts on that item, not on the cursor', async (e, on) => {
  const run = await mounted(e, on)
  await threeItemGroup(run, 'Alpha')
  run.w.now += 60_000
  await threeItemGroup(run, 'Beta')
  const lines: string[] = []
  lines.push(...(await press(run, 'mode-groups')))
  lines.push(...(await press(run, 'next')))
  lines.push(...(await press(run, 'groups-it-0-1')))
  lines.push(...(await press(run, 'back')))
  lines.push(...(await press(run, 'next')))
  lines.push(...(await press(run, 'mode-groups')))
  lines.push(...(await press(run, 'groups-it-0-1')))
  lines.push(...(await step(run, 'b.md removed by another session', () => call(run.$ as never, 'save_group', { id: run.ids[1], remove: [{ target: 'b.md' }] }))))
  lines.push(...(await press(run, 'back')))
  lines.push(...(await press(run, 'prev')))
  lines.push(...(await press(run, 'next')))
  await run.ui.unmount()
  check('group page via a card item', lines)
})

test('an item removed by another session between draws: the selection follows its item, else falls to the nearest row', async (e, on) => {
  const run = await mounted(e, on)
  await create(run.$ as never, [{ target: 'd.md' }], 'Other').then(one => run.ids.push(one.id))
  run.w.now += 60_000
  const id = await threeItemGroup(run)
  const without = (ref: string) => () => editGroup(run.w, id, group => (group.items = (group.items as { ref: string }[]).filter(one => one.ref !== ref)))
  const lines: string[] = []
  lines.push(...(await press(run, 'mode-groups')))
  lines.push(...(await press(run, 'open-selected')))
  lines.push(...(await press(run, 'next')))
  lines.push(...(await press(run, 'next')))
  lines.push(...(await step(run, 'a.md removed', async () => without('a.md')())))
  lines.push(...(await press(run, 'prev')))
  lines.push(...(await press(run, 'next')))
  lines.push(...(await step(run, 'c.md removed', async () => without('c.md')())))
  lines.push(...(await step(run, 'redraw', async () => undefined)))
  lines.push(...(await press(run, 'next')))
  lines.push(...(await press(run, 'prev')))
  lines.push(...(await step(run, 'every item removed', async () => editGroup(run.w, id, group => (group.items = [])))))
  lines.push(...(await press(run, 'next')))
  lines.push(...(await press(run, 'prev')))
  lines.push(...(await press(run, 'star-selected')))
  lines.push(...(await press(run, 'open-selected')))
  lines.push(...(await step(run, 'a.md, b.md and c.md added', async () => editGroup(run.w, id, group => (group.items = ['a.md', 'b.md', 'c.md'].map(ref => ({ ref, addedBy: 'agent', addedAt: 1 })))))))
  lines.push(...(await press(run, 'next')))
  lines.push(...(await press(run, 'next')))
  lines.push(...(await press(run, 'mode-view')))
  lines.push(...(await step(run, 'c.md removed while the page is not shown', async () => without('c.md')())))
  lines.push(...(await press(run, 'mode-groups')))
  lines.push(...(await press(run, 'prev')))
  await run.ui.unmount()
  check('item removed between draws', lines)
})

test('an item opened from a pinned card and removed meanwhile: Back falls to the row the page last selected', async (e, on) => {
  const run = await mounted(e, on)
  const id = await threeItemGroup(run, 'Pinned')
  editGroup(run.w, id, group => (group.starred = true))
  const lines: string[] = []
  lines.push(...(await press(run, 'mode-groups')))
  lines.push(...(await press(run, 'open-selected')))
  lines.push(...(await press(run, 'next')))
  lines.push(...(await press(run, 'next')))
  lines.push(...(await press(run, 'mode-recent')))
  lines.push(...(await press(run, 'starred-it-0-0')))
  lines.push(...(await step(run, 'a.md removed', async () => editGroup(run.w, id, group => (group.items = (group.items as { ref: string }[]).filter(one => one.ref !== 'a.md'))))))
  lines.push(...(await press(run, 'back')))
  lines.push(...(await press(run, 'prev')))
  await run.ui.unmount()
  check('pinned card item removed', lines)
})

test('the Groups tab with an expanded card: j and k walk the cards and m folds them', async (e, on) => {
  const run = await mounted(e, on)
  for (const title of ['One', 'Two', 'Three']) {
    await threeItemGroup(run, title)
    run.w.now += 60_000
  }
  const lines: string[] = []
  lines.push(...(await press(run, 'mode-groups')))
  lines.push(...(await press(run, 'expand-selected')))
  for (const key of ['next', 'expand-selected', 'next', 'next', 'prev', 'left', 'right', 'prev', 'prev']) lines.push(...(await press(run, key)))
  lines.push(...(await wheel(run, 1)))
  lines.push(...(await focus(run, 'item-2')))
  lines.push(...(await press(run, 'star-selected')))
  lines.push(...(await estimateAfter(run)))
  await run.ui.unmount()
  check('groups tab, expanded cards', lines)
})

test('Recent with pinned groups: the keys walk the pinned cards, then favourites, then the file rows', async (e, on) => {
  const run = await mounted(e, on)
  const first = await threeItemGroup(run, 'Pinned one')
  run.w.now += 60_000
  const second = await threeItemGroup(run, 'Pinned two')
  for (const id of [first, second]) editGroup(run.w, id, group => (group.starred = true))
  for (const file of ['a.md', 'b.md', 'c.md', 'd.md']) await run.$.command.run({ command: 'peek', args: `/repo/${file}` } as never)
  const lines: string[] = []
  lines.push(...(await press(run, 'mode-recent')))
  lines.push(...(await press(run, 'star-selected')))
  lines.push(...(await press(run, 'expand-selected')))
  for (const key of ['next', 'next', 'next', 'next', 'left', 'right', 'next', 'next', 'next', 'next', 'prev', 'prev']) lines.push(...(await press(run, key)))
  lines.push(...(await wheel(run, -1)))
  lines.push(...(await focus(run, 'item-1')))
  lines.push(...(await press(run, 'open-selected')))
  lines.push(...(await press(run, 'mode-recent')))
  lines.push(...(await estimateAfter(run)))
  await run.ui.unmount()
  check('recent with pinned groups', lines)
})

test('Gallery with a wrapped second row: h and l move along a row, j and k between rows', async (e, on) => {
  const run = await mounted(e, on, 70)
  for (const file of ['a.md', 'b.md', 'c.md', 'd.md']) await run.$.command.run({ command: 'peek', args: `/repo/${file}` } as never)
  const lines: string[] = []
  lines.push(...(await press(run, 'mode-gallery')))
  for (const key of ['right', 'right', 'right', 'next', 'next', 'left', 'left', 'prev', 'right', 'next', 'prev', 'prev']) lines.push(...(await press(run, key)))
  lines.push(...(await wheel(run, 1)))
  lines.push(...(await focus(run, 'item-3')))
  lines.push(...(await press(run, 'star-selected')))
  lines.push(...(await press(run, 'next')))
  lines.push(...(await estimateAfter(run)))
  await run.ui.unmount()
  check('gallery wrapped', lines)
})

test('a long markdown view: the jump keys and the footer position over the drawn blocks', async (e, on) => {
  const run = await mounted(e, on)
  await run.$.command.run({ command: 'peek', args: '/repo/docs/long.md' } as never)
  await settleMicrotasks()
  await run.ui.redraw()
  const lines: string[] = [await info(run.ui)]
  for (const key of ['next', 'prev', 'left', 'right']) lines.push(...(await press(run, key)))
  for (const [offset, contentRows] of [[0, 300], [3, 300], [10, 300], [57, 300], [400, 300], [20, 150], [20, 60]] as const) {
    run.log.splice(0)
    await scrolled(run, offset, contentRows)
    lines.push(`> scrolled to ${offset} of ${contentRows}`, ...run.log, await info(run.ui))
  }
  for (const key of ['next', 'prev']) lines.push(...(await press(run, key)))
  await run.ui.unmount()
  check('long markdown', lines)
})
