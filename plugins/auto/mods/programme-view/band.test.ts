import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'
import type { Engine, Mounted } from 'claude-code/testing'
import { GLYPH, bandLayout, lineText, moveSelection, readWork } from './band.tsx'
import type { BandEntry, Span } from './band.tsx'

const DATA = '/data'
const HOME = `${DATA}/programmes/prog-1`
const VIEW = `${HOME}/views/view.json`
const LEASE = `${DATA}/programmes/leases/default__w2.json`

type Kind = 'done' | 'current' | 'waiting' | 'planned'

function step(kind: Kind, title: string) {
  return { kind, title, clause: null, clause_label: 'no clause', no_clause: true, note: null }
}

function task(id: string, over: Record<string, unknown> = {}) {
  return {
    id,
    title: `Owner history task ${id}`,
    state: 'open',
    location: `Tab-${id} › pane-${id}`,
    session_id: 'sess-w',
    no_plan: false,
    steps: [step('done', 'Read code'), step('current', 'Write test'), step('planned', 'Run suite'), step('planned', 'Open PR')],
    finish: 'PR open, CI green',
    age_seconds: 60,
    faded: false,
    change_hash: null,
    changed_since_first: false,
    watch: null,
    ...over,
  }
}

function entries(raw: unknown[]): BandEntry[] {
  return readWork(raw)
}

function world(on: On, work: unknown[], store: Record<string, unknown> = {}) {
  const files: Record<string, string> = {
    [LEASE]: JSON.stringify({ session_id: 'sess-pm', run: 'prog-1', home: HOME }),
    [VIEW]: JSON.stringify({ view_format: 2, run: 'prog-1', generated_at: '2026-10-19T00:00:00Z', model: {}, rows: [], work }),
  }
  mock.env(on, { CLAUDE_AUTO_DATA_DIR: DATA })
  mock.clock(on)
  on('ui.render', ($, e) => $.ui.resolve(e).Text({ children: 'beneath the band' }))
  on('session.id', () => ({ value: 'sess-pm' }))
  on('command.register', () => ({ value: { command: 'programme-view' } }))
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('store.get', (_$, e) => ({ value: store[e.key] }))
  on('store.set', (_$, e) => {
    store[e.key] = e.value
    return { value: undefined }
  })
  on('fs.list', (_$, e) => ({
    value: Object.keys(files)
      .filter(path => path.startsWith(`${e.path}/`))
      .map(path => ({ name: path.slice(e.path.length + 1), kind: 'file' as const, size: 1, mtimeMs: 1, isLink: false })),
  }))
  on('fs.read', (_$, e) => {
    if (!(e.path in files)) throw new Error('ENOENT')
    return { value: files[e.path] ?? '' }
  })
  on('fs.stat', (_$, e) => {
    if (!(e.path in files)) throw new Error('ENOENT')
    return { value: { kind: 'file' as const, size: 1, mtimeMs: 1, isLink: false } }
  })
  return store
}

async function opened($: Engine) {
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  await $.command.run({ command: 'programme-view' } as never)
}

async function mountBand($: Engine, over: Record<string, unknown> = {}): Promise<Mounted<'terminal', 'AbovePrompt'>> {
  return $.ui.mount({
    plugin: 'auto',
    surface: 'terminal',
    component: 'AbovePrompt',
    requestId: 'above-prompt',
    props: { hasSurvey: false, isWorking: false, maxRows: 20, bodyColumns: 120, ...over },
  } as never)
}

function texts(lines: Span[][]): string[] {
  return lines.map(line => lineText(line))
}

function withText(spans: Span[], text: string): Span[] {
  return spans.filter(span => span.text.includes(text))
}

function width(text: string): number {
  return [...text].length
}

test('five tasks at 120 columns fill at most 2 lines, then "+N more" with the right N', () => {
  const work = entries(['1', '2', '3', '4', '5'].map(id => task(id)))
  const layout = bandLayout(work, 120, {})
  expect(layout.lines.length).toBeLessThanOrEqual(2)
  for (const line of texts(layout.lines)) expect(width(line)).toBeLessThanOrEqual(120)
  const shown = layout.shown.length
  expect(shown).toBeLessThan(5)
  expect(layout.more).toBe(5 - shown)
  expect(texts(layout.lines).at(-1)).toContain(`+${5 - shown} more`)
})

test('at 80 columns a 60-character title truncates and the band still fits 2 lines', () => {
  const long = 'x'.repeat(60)
  const work = entries([task('1', { title: long }), task('2'), task('3')])
  const layout = bandLayout(work, 80, {})
  const all = texts(layout.lines).join('\n')
  expect(all).not.toContain(long)
  expect(all).toContain(`${'x'.repeat(23)}…`)
  expect(layout.lines.length).toBeLessThanOrEqual(2)
  for (const line of texts(layout.lines)) expect(width(line)).toBeLessThanOrEqual(80)
})

test('a task with 12 steps renders the shortened track with "…"', () => {
  const steps = [
    ...Array.from({ length: 5 }, (_, index) => step('done', `Done ${index}`)),
    step('current', 'Now'),
    ...Array.from({ length: 6 }, (_, index) => step('planned', `Plan ${index}`)),
  ]
  const layout = bandLayout(entries([task('1', { steps })]), 120, {})
  const line = lineText(layout.lines[0] ?? [])
  expect(line).toContain('…')
  const glyphs = [...line].filter(c => [GLYPH.done, GLYPH.current, GLYPH.planned].includes(c))
  expect(glyphs).toEqual([GLYPH.done, GLYPH.current, GLYPH.planned])
  expect(line).toContain(GLYPH.goal)
})

test('a task with no trajectory renders its title and "no plan yet"', () => {
  const layout = bandLayout(entries([task('1', { no_plan: true, steps: [], finish: null, location: null })]), 120, {})
  expect(lineText(layout.lines[0] ?? [])).toContain('Owner history task 1')
  expect(lineText(layout.lines[0] ?? [])).toContain('no plan yet')
})

test('focusing the seventh task while 4 are visible swaps it into the last visible slot', () => {
  const work = entries(['1', '2', '3', '4', '5', '6', '7'].map(id => task(id)))
  const plain = bandLayout(work, 120, {})
  expect(plain.shown.length).toBe(4)
  const focused = bandLayout(work, 120, { item: '7' })
  expect(focused.shown.at(-1)).toBe('7')
  expect(focused.shown.slice(0, -1)).toEqual(plain.shown.slice(0, focused.shown.length - 1))
  expect(focused.more).toBe(7 - focused.shown.length)
})

test('a collapsed entry shows title, dots and deliverable with no location; the focused one adds it dimmed', () => {
  const work = entries([task('1'), task('2')])
  const collapsed = texts(bandLayout(work, 120, {}).lines).join('\n')
  expect(collapsed).toContain('Owner history task 1')
  expect(collapsed).toContain(GLYPH.done)
  expect(collapsed).toContain('PR open')
  expect(collapsed).not.toContain('Tab-1 › pane-1')
  expect(collapsed).not.toContain(GLYPH.pane)

  const focused = bandLayout(work, 120, { item: '1' })
  const spans = focused.lines.flat()
  const where = spans.find(s => s.text.includes('Tab-1 › pane-1'))
  expect(where?.dim).toBe(true)
  expect(texts(focused.lines).join('\n')).not.toContain('Tab-2 › pane-2')
  const pill = spans.find(s => s.inverse)
  expect(pill?.text).toContain('Write test')
})

test('glyphs: done filled, current pill or play, planned open, finish goal, waiting current uses the timer', () => {
  const collapsed = lineText(bandLayout(entries([task('1')]), 120, {}).lines[0] ?? [])
  expect(collapsed).toContain(GLYPH.done)
  expect(collapsed).toContain(GLYPH.current)
  expect(collapsed).toContain(GLYPH.planned)
  expect(collapsed).toContain(GLYPH.goal)

  const focused = bandLayout(entries([task('1')]), 120, { item: '1' }).lines.flat()
  expect(focused.some(s => s.text === GLYPH.capLeft)).toBe(true)
  expect(focused.some(s => s.text === GLYPH.capRight)).toBe(true)

  const waitingSteps = [step('done', 'Repro'), step('waiting', 'Waiting on CI'), step('planned', 'Check')]
  const waiting = lineText(bandLayout(entries([task('1', { state: 'waiting', steps: waitingSteps })]), 120, {}).lines[0] ?? [])
  expect(waiting).toContain(GLYPH.waiting)
  expect(waiting).not.toContain(GLYPH.current)
})

test('steps past the next one carry no colour', () => {
  const work = entries([task('1')])
  for (const selection of [{}, { item: '1' }, { item: '1', step: 3 }]) {
    const spans = bandLayout(work, 120, selection).lines.flat()
    expect(withText(spans, GLYPH.done).every(s => s.color === 'success')).toBe(true)
    const planned = spans.filter(s => s.step === 2 || s.step === 3)
    expect(planned.find(s => s.step === 2 && s.color)).toBeDefined()
    expect(planned.filter(s => s.step === 3).every(s => s.color === undefined)).toBe(true)
    expect(withText(spans, GLYPH.goal).every(s => s.color === undefined)).toBe(true)
    expect(spans.filter(s => s.step === undefined && s.text.includes('Owner history task 1')).every(s => s.color === undefined)).toBe(true)
  }
})

test('keys move tasks and steps: Tab wraps, arrows stop at the ends', () => {
  const work = entries([task('1'), task('2')])
  expect(moveSelection(work, { item: '1', step: 1 }, { key: 'tab' })).toEqual({ item: '2', step: 1 })
  expect(moveSelection(work, { item: '2', step: 1 }, { key: 'tab' })).toEqual({ item: '1', step: 1 })
  expect(moveSelection(work, { item: '1', step: 1 }, { key: 'tab', shift: true })).toEqual({ item: '2', step: 1 })
  expect(moveSelection(work, { item: '1', step: 1 }, { key: 'right' })).toEqual({ item: '1', step: 2 })
  expect(moveSelection(work, { item: '1', step: 3 }, { key: 'right' })).toEqual({ item: '1', step: 3 })
  expect(moveSelection(work, { item: '1', step: 0 }, { key: 'left' })).toEqual({ item: '1', step: 0 })
  expect(moveSelection(work, { item: '1', step: 1 }, { key: 'a' })).toBeUndefined()
})

test('with a survey present the band yields', async ($, on) => {
  world(on, [task('1')])
  await opened($)
  const band = await mountBand($, { hasSurvey: true })
  expect(await band.find({ type: 'Client' })).toBeUndefined()
  expect(await band.find({ type: 'Text', text: 'beneath the band' })).toBeDefined()
})

test('with zero open tasks the band renders nothing', async ($, on) => {
  world(on, [])
  await opened($)
  const band = await mountBand($)
  expect(await band.find({ type: 'Client' })).toBeUndefined()
  expect(await band.find({ type: 'Text', text: 'beneath the band' })).toBeDefined()
})

test('before /programme-view opens the band renders nothing', async ($, on) => {
  world(on, [task('1')])
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  const band = await mountBand($)
  expect(await band.find({ type: 'Client' })).toBeUndefined()
  expect(await band.find({ type: 'Text', text: 'beneath the band' })).toBeDefined()
})

test('the band draws every task collapsed through one Client', async ($, on) => {
  world(on, [task('1'), task('2')])
  await opened($)
  const band = await mountBand($)
  expect(await band.find({ type: 'Client', key: 'band' })).toBeDefined()
  expect(await band.find({ type: 'Button' })).toBeUndefined()
  expect(await band.find({ type: 'Text', text: /Owner history task 1/, in: 'band' })).toBeDefined()
  expect(await band.find({ type: 'Text', text: /Tab-1 › pane-1/, in: 'band' })).toBeUndefined()
})

test('AE7: without a click, Tab leaves the band unfocused and selects nothing', async ($, on) => {
  const store = world(on, [task('1'), task('2')])
  await opened($)
  const band = await mountBand($)
  await band.key({ key: 'tab', in: 'band' })
  await band.key({ key: 'right', in: 'band' })
  expect(await band.find({ type: 'Text', text: /Tab-1 › pane-1|Tab-2 › pane-2/, in: 'band' })).toBeUndefined()
  expect(Object.keys(store)).toEqual([])
})

test('after a click Tab moves to the next task, Right to the next step, Left stops at the first, Tab wraps', async ($, on) => {
  const store = world(on, [task('1', { change_hash: 'h1' }), task('2', { change_hash: 'h2' })])
  await opened($)
  const band = await mountBand($)
  await band.pointer({ type: 'down', x: 1, y: 0, button: 'left', in: 'band' })
  await band.pointer({ type: 'up', x: 1, y: 0, button: 'left', in: 'band' })
  expect(await band.find({ type: 'Text', text: /Tab-1 › pane-1/, in: 'band' })).toBeDefined()
  expect(store['viewed:1']).toBe('h1')

  await band.key({ key: 'tab', in: 'band' })
  expect(await band.find({ type: 'Text', text: /Tab-2 › pane-2/, in: 'band' })).toBeDefined()
  expect(await band.find({ type: 'Text', text: /Write test/, in: 'band' })).toBeDefined()
  expect(store['viewed:2']).toBe('h2')

  await band.key({ key: 'right', in: 'band' })
  expect(await band.find({ type: 'Text', text: /Run suite/, in: 'band' })).toBeDefined()

  for (let press = 0; press < 4; press += 1) await band.key({ key: 'left', in: 'band' })
  expect(await band.find({ type: 'Text', text: /Read code/, in: 'band' })).toBeDefined()

  await band.key({ key: 'tab', in: 'band' })
  expect(await band.find({ type: 'Text', text: /Tab-1 › pane-1/, in: 'band' })).toBeDefined()
})
