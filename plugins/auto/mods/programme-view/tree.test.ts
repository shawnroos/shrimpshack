import { expect, test } from 'claude-code/testing'

import { viewedKey } from './selection'
import {
  LEASE,
  VIEW,
  buttonKeys,
  findAllNodes,
  findNode,
  lease,
  lines,
  openPane,
  personFocus,
  settle,
  step,
  viewText,
  walk,
  workEntry,
  world,
} from './test-world'
import type { Pane } from './test-world'

// The mod's selection lives in its own module environment, so a test reads it off the draw: the row with the bar,
// whose Button carries autoFocus.
async function selectedRows(pane: Pane): Promise<string[]> {
  const keys: string[] = []
  walk(await pane.drawn(), one => {
    if (one.type === 'Button' && one.props?.autoFocus === true) keys.push(String(one.props.key))
  })
  const barred = (await lines(pane)).filter(line => line.startsWith('▌'))
  expect(barred).toHaveLength(keys.length)
  return keys
}

test('two items draw two trees: done count, current step, numbered planned steps, then the finish', async ($, on) => {
  const second = workEntry('linear:WEB-2', 'Retry watcher', {
    state: 'waiting',
    location: 'AI-Editor › retry-watcher',
    steps: [
      step('done', 'Reproduce stale wait'),
      step('waiting', 'Waiting on CI', 'term:stop_rule'),
      step('planned', 'Check retry result'),
    ],
    finish: 'item closed with evidence',
    watch: { state: 'watcher_live', interval_seconds: null, beat_age_seconds: 40 },
  })
  world(on, { [LEASE]: lease(), [VIEW]: viewText({ work: [workEntry('linear:WEB-1', 'Export owner history'), second] }) })
  const pane = await openPane($)
  const drawn = (await lines(pane)).map(line => line.trim())
  const at = (text: string) => drawn.findIndex(line => line.includes(text))

  expect(drawn[at('Export owner history')]).toContain('AI-Editor › owner-history')
  expect(drawn[at('2 done')]).toContain('last: Add owner history field')
  expect(at('2 done')).toBe(at('Export owner history') + 1)
  expect(at('Write view test')).toBe(at('2 done') + 1)
  expect(drawn[at('Write view test')]).toContain('autonomy')
  expect(drawn[at('1. Run auto suite')]).toBeDefined()
  expect(at('1. Run auto suite')).toBe(at('Write view test') + 1)
  expect(at('2. Open PR')).toBe(at('1. Run auto suite') + 1)
  expect(drawn[at('PR open, CI green')]).toContain('└─')
  expect(at('PR open, CI green')).toBe(at('2. Open PR') + 1)

  expect(at('Retry watcher')).toBeGreaterThan(at('PR open, CI green'))
  expect(drawn[at('Waiting on CI')]).toContain('watcher live · 40s')
  expect(drawn[at('Waiting on CI')]).toContain('stop rule')
  expect(at('1. Check retry result')).toBe(at('Waiting on CI') + 1)
  expect(drawn[at('item closed with evidence')]).toContain('└─')
})

test('a step with no clause shows the warning icon and "no clause"', async ($, on) => {
  const item = workEntry('linear:WEB-3', 'Linux browser check', {
    steps: [step('current', 'Install toolchain', null), step('planned', 'Report', 'term:remit')],
  })
  world(on, { [LEASE]: lease(), [VIEW]: viewText({ work: [item] }) })
  const pane = await openPane($)
  const drawn = await lines(pane)
  expect(drawn.find(line => line.includes('Install toolchain'))).toContain('\uF421 no clause')
  expect(drawn.find(line => line.includes('Report'))).not.toContain('no clause')
  const warning = await findNode(pane, one => one.type === 'Text' && one.props?.color === 'warning' && String(one.children?.[0]).includes('\uF421'))
  expect(warning).toBeDefined()
})

test('waiting steps read their watch state, and nothing watching is a warning', async ($, on) => {
  const waits = [
    { state: 'reporter_only', reporter: 'ci-bot' },
    { state: 'retry_never_started' },
    { state: 'nothing_watching' },
    { state: 'watcher_live', interval_seconds: 900, beat_age_seconds: null },
  ].map((watch, i) =>
    workEntry(`linear:W-${i}`, `Wait ${i}`, { state: 'waiting', steps: [step('waiting', `Wait step ${i}`)], watch }),
  )
  world(on, { [LEASE]: lease(), [VIEW]: viewText({ work: waits }) })
  const pane = await openPane($)
  const drawn = await lines(pane)
  const row = (i: number) => drawn.find(line => line.includes(`Wait step ${i}`)) ?? ''
  expect(row(0)).toContain('named reporter only')
  expect(row(0)).not.toContain('watcher live')
  expect(row(1)).toContain('retry never started')
  expect(row(2)).toContain('nothing watching')
  expect(row(3)).toContain('watcher live · every 15m')
  expect(row(2)).toContain('\uF421 nothing watching')
  const warnings = await findAllNodes(pane, one => one.type === 'Text' && one.props?.color === 'warning')
  expect(warnings.map(one => String(one.children?.join('')).trim())).toEqual(['\uF421'])
})

test('a faded item shows its age and is dimmed', async ($, on) => {
  const item = workEntry('linear:WEB-4', 'Old work', { recorded_at: '2026-10-19T09:20:00Z', age_seconds: 2400, faded: true })
  world(on, { [LEASE]: lease(), [VIEW]: viewText({ work: [item, workEntry('linear:WEB-5', 'Fresh work')] }) })
  const pane = await openPane($)
  const drawn = await lines(pane)
  expect(drawn.find(line => line.includes('Old work'))).toContain('40m')
  const title = await findNode(pane, one => one.type === 'Text' && one.children?.[0] === 'Old work')
  expect(title?.props?.dimColor).toBe(true)
  const fresh = await findNode(pane, one => one.type === 'Text' && one.children?.[0] === 'Fresh work')
  expect(fresh?.props?.dimColor).not.toBe(true)
})

test('age and fade follow the clock, not the view build: a stalled PM still fades', async ($, on) => {
  const item = workEntry('linear:WEB-4', 'Stalled work', { recorded_at: '2026-10-19T09:20:00Z', age_seconds: 5, faded: false })
  world(on, { [LEASE]: lease(), [VIEW]: viewText({ work: [item] }) })
  const pane = await openPane($)
  const drawn = await lines(pane)
  expect(drawn.find(line => line.includes('Stalled work'))).toContain('40m')
  const title = await findNode(pane, one => one.type === 'Text' && one.children?.[0] === 'Stalled work')
  expect(title?.props?.dimColor).toBe(true)
})

test('the pane redraws as a minute passes with no view change', async ($, on) => {
  const item = workEntry('linear:WEB-4', 'Ticking work', { recorded_at: '2026-10-19T09:59:00Z', age_seconds: 5 })
  const { clock } = world(on, { [LEASE]: lease(), [VIEW]: viewText({ work: [item] }) })
  const pane = await openPane($)
  expect((await lines(pane)).find(line => line.includes('Ticking work'))).toContain('1m')
  await clock.advance(61_000)
  expect((await lines(pane)).find(line => line.includes('Ticking work'))).toContain('2m')
})

test('an item with no trajectory reads "no plan yet"', async ($, on) => {
  const item = workEntry('linear:WEB-6', 'Unplanned', { no_plan: true, steps: [], finish: null, age_seconds: null })
  world(on, { [LEASE]: lease(), [VIEW]: viewText({ work: [item] }) })
  const pane = await openPane($)
  expect((await lines(pane)).some(line => line.includes('no plan yet'))).toBe(true)
})

test('the plan-changed marker shows until the item is selected, stays cleared on the same hash, returns on a new one', async ($, on) => {
  const files = {
    [LEASE]: lease(),
    [VIEW]: viewText({ work: [workEntry('linear:WEB-1', 'Export owner history', { change_hash: 'c1', changed_since_first: true })] }),
  }
  const mtimes: Record<string, number> = { [VIEW]: 1 }
  const { store } = world(on, files, mtimes)
  const pane = await openPane($)
  const marked = async () => (await lines(pane)).some(line => line.includes('plan changed'))
  expect(await marked()).toBe(true)

  await pane.press({ key: 'item:linear:WEB-1' })
  await settle()
  expect(await selectedRows(pane)).toEqual(['item:linear:WEB-1'])
  expect(store.get(viewedKey('linear:WEB-1'))).toBe('c1')
  expect(await marked()).toBe(false)

  await pane.redraw()
  expect(await marked()).toBe(false)

  files[VIEW] = viewText({ work: [workEntry('linear:WEB-1', 'Export owner history', { change_hash: 'c2', changed_since_first: true })] })
  await pane.redraw()
  expect(await marked()).toBe(true)
})

test('a first recording never shows the marker', async ($, on) => {
  world(on, {
    [LEASE]: lease(),
    [VIEW]: viewText({ work: [workEntry('linear:WEB-1', 'First', { change_hash: null, changed_since_first: false })] }),
  })
  const pane = await openPane($)
  expect((await lines(pane)).some(line => line.includes('plan changed'))).toBe(false)
})

test('a person-origin focus walk steps through the rows in order and selects each', async ($, on) => {
  world(on, {
    [LEASE]: lease(),
    [VIEW]: viewText({ work: [workEntry('linear:WEB-1', 'One'), workEntry('linear:WEB-2', 'Two', { steps: [step('current', 'Only step')] })] }),
  })
  const pane = await openPane($)
  const rows = (await buttonKeys(pane)).filter(key => key.startsWith('item:') || key.startsWith('step:'))
  expect(rows).toEqual([
    'item:linear:WEB-1',
    'step:linear:WEB-1:1',
    'step:linear:WEB-1:2',
    'step:linear:WEB-1:3',
    'step:linear:WEB-1:4',
    'item:linear:WEB-2',
    'step:linear:WEB-2:0',
  ])
  expect(await selectedRows(pane)).toEqual([])
  const seen: string[][] = []
  for (const key of rows) {
    await personFocus($, key)
    await settle()
    seen.push(await selectedRows(pane))
  }
  expect(seen).toEqual(rows.map(key => [key]))
})
