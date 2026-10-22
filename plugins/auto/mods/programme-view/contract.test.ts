import { expect, test } from 'claude-code/testing'

import {
  LEASE,
  LEASES,
  VIEW,
  buttonKeys,
  contractPane,
  contractPart,
  defaultTerms,
  findNode,
  lease,
  lines,
  openPane,
  personFocus,
  settle,
  term,
  viewText,
  world,
} from './test-world'

test('the contract view lists the four Scope terms with their setting and description, and no autonomy', async ($, on) => {
  world(on, { [LEASE]: lease(), [VIEW]: viewText() })
  const pane = await contractPane($)
  const terms = (await buttonKeys(pane)).filter(key => key.startsWith('term:'))
  expect(terms).toEqual(['term:remit', 'term:stop_rule', 'term:cadence', 'term:tools_of_record'])
  const drawn = await lines(pane)
  const cadence = drawn.find(line => line.includes('cadence ')) ?? ''
  expect(cadence).toContain('fixed, seconds 900')
  expect(cadence).toContain('what cadence controls')
  expect(drawn.some(line => line.includes('"ask before closing"'))).toBe(true)
  expect(drawn.some(line => line.includes('Applies to the whole programme (inherited) · decided, no kind · 1 step relies on this'))).toBe(true)
  expect(drawn.some(line => line.includes('Rulings'))).toBe(true)
  expect(drawn.some(line => /autonomy|instruction|correction|project term/i.test(line))).toBe(false)
})

test('opening cadence shows binding, reliant steps, set by, notes, proposal and options with the active one marked', async ($, on) => {
  world(on, { [LEASE]: lease(), [VIEW]: viewText() })
  const pane = await contractPane($)
  await pane.press({ key: 'term:cadence' })
  await settle()
  const drawn = await lines(pane)
  const has = (text: string) => drawn.some(line => line.includes(text))
  expect(has('Checked in code')).toBe(true)
  expect(has('3 steps rely on this')).toBe(true)
  expect(has('Set by shawn')).toBe(true)
  expect(has('early in the project')).toBe(true)
  expect(has('Your note: revisit after first week')).toBe(true)
  expect(has('Proposed: on_change · pending')).toBe(true)
  expect(drawn.find(line => line.includes('fixed') && line.includes('what fixed means'))).toContain('active')
  expect(drawn.find(line => line.includes('what on_change means'))).not.toContain('active')
  const options = (await buttonKeys(pane)).filter(key => key.startsWith('option:cadence:'))
  expect(options).toHaveLength(10)
})

test('a term with no binding or notes says so', async ($, on) => {
  world(on, { [LEASE]: lease(), [VIEW]: viewText() })
  const pane = await contractPane($)
  await pane.press({ key: 'term:tools_of_record' })
  await settle()
  const drawn = await lines(pane)
  expect(drawn.some(line => line.includes('Nothing reads it'))).toBe(true)
  expect(drawn.some(line => line.includes('No step relies on this'))).toBe(true)
  expect(drawn.some(line => line.includes('Options  (choose any)'))).toBe(true)
  expect(drawn.find(line => line.includes('what tracker means'))).toContain('\uF046')
  expect(drawn.find(line => line.includes('what plans means'))).toContain('\uF096')
})

test('opening a second term closes the first', async ($, on) => {
  world(on, { [LEASE]: lease(), [VIEW]: viewText() })
  const pane = await contractPane($)
  await pane.press({ key: 'term:cadence' })
  await settle()
  await pane.press({ key: 'term:stop_rule' })
  await settle()
  const keys = await buttonKeys(pane)
  expect(keys.some(key => key.startsWith('option:cadence:'))).toBe(false)
  expect(keys.filter(key => key.startsWith('option:stop_rule:'))).toEqual(['option:stop_rule:a', 'option:stop_rule:b'])
  expect((await lines(pane)).some(line => line.includes('choose any'))).toBe(false)
  expect((await lines(pane)).find(line => line.includes('what a means'))).toContain('\uF192')
  expect((await lines(pane)).some(line => line.includes('Written guidance only'))).toBe(true)

  await pane.press({ key: 'term:stop_rule' })
  await settle()
  expect((await buttonKeys(pane)).some(key => key.startsWith('option:'))).toBe(false)
})

// The kit raises no ui.scroll for a plugin's own $.ui.scroll (peek's selection.test.ts says the same), so the
// scroll call is pinned through what it names: the row the draw marks focused, below a 12-row window.
test('in a 12-row pane the focused option row is the one the draw marks, below the first window', async ($, on) => {
  world(on, { [LEASE]: lease(), [VIEW]: viewText() })
  const pane = await contractPane($, true, 12)
  await pane.press({ key: 'term:cadence' })
  await settle()
  await personFocus($, 'option:cadence:o10')
  await settle()
  const drawn = await lines(pane)
  const row = drawn.findIndex(line => line.includes('what o10 means'))
  expect(row).toBeGreaterThan(11)
  expect(drawn[row]).toContain('›')
  expect(drawn.filter(line => line.includes('›'))).toHaveLength(1)
  const focused = await findNode(pane, one => one.type === 'Button' && one.props?.autoFocus === true)
  expect(focused?.props?.key).toBe('option:cadence:o10')
})

test('a refused proposal shows "refused" and its reason; a superseded one shows "superseded"', async ($, on) => {
  const terms = defaultTerms()
  terms[1] = term('stop_rule', {
    proposal: { value: 'only_when_done', at: '2026-10-19T09:00:00Z', origin: 'ui', state: 'refused', reason: 'the prompt was a suggestion, not typed' },
  })
  terms[3] = term('tools_of_record', {
    proposal: { value: ['tracker'], at: '2026-10-19T09:00:00Z', origin: 'ui', state: 'superseded', settled_at: '2026-10-19T09:30:00Z' },
  })
  terms[0] = term('remit', { proposal: { value: 'tabs', at: '2026-10-19T09:00:00Z', origin: 'pm', state: 'accepted' } })
  world(on, { [LEASE]: lease(), [VIEW]: viewText({ contract: contractPart(terms) }) })
  const pane = await contractPane($)
  const drawn = await lines(pane)
  expect(drawn.find(line => line.includes('stop rule '))).toContain('refused: the prompt was a suggestion, not typed')
  expect(drawn.find(line => line.includes('tools of record '))).toContain('superseded')
  expect(drawn.find(line => line.includes('remit '))).toContain('accepted')
  expect(drawn.find(line => line.includes('cadence '))).toContain('proposed: on_change')

  await pane.press({ key: 'term:stop_rule' })
  await settle()
  expect((await lines(pane)).some(line => line.includes('Proposed: only_when_done · refused: the prompt was a suggestion, not typed'))).toBe(true)
})

test('the re-read line shows the last re-read, the terms changed since, and a pending request', async ($, on) => {
  const at = '2026-10-19T09:10:00Z'
  const hhmm = new Date(at).toTimeString().slice(0, 5)
  world(on, {
    [LEASE]: lease(),
    [VIEW]: viewText({ reread: { last_at: at, changed_since: ['stop_rule', 'cadence'], requested: true, requested_at: '2026-10-19T09:20:00Z' } }),
  })
  const pane = await contractPane($)
  const drawn = await lines(pane)
  expect(drawn.some(line => line.includes(`PM last re-read the rules at ${hhmm}`))).toBe(true)
  expect(drawn.some(line => line.includes('2 terms changed since then: stop rule, cadence'))).toBe(true)
  expect(drawn.some(line => line.includes('re-read requested'))).toBe(true)
})

test('hotkeys are not armed while the pane is unfocused', async ($, on) => {
  world(on, { [LEASE]: lease(), [VIEW]: viewText() })
  const pane = await openPane($, false)
  const armed = await findNode(pane, one => one.type === 'Button' && one.props?.hotkey !== undefined)
  expect(armed).toBeUndefined()
  expect(await pane.find({ key: 'view:contract' })).toBeUndefined()

  await pane.redraw({ title: 'Programme', isFocused: true, bodyColumns: 100, placement: 'dock', scroll: { offset: 0, bodyRows: 40 }, view: {} } as never)
  await settle()
  const contract = await findNode(pane, one => one.type === 'Button' && one.props?.key === 'view:contract')
  expect(contract?.props?.hotkey).toBe('c')
  const work = await findNode(pane, one => one.type === 'Button' && one.props?.key === 'view:work')
  expect(work?.props?.hotkey).toBe('w')
})

test('w and c switch between the work and contract views', async ($, on) => {
  world(on, { [LEASE]: lease(), [VIEW]: viewText() })
  const pane = await openPane($)
  expect((await buttonKeys(pane)).some(key => key.startsWith('term:'))).toBe(false)
  await pane.press({ key: 'view:contract' })
  await settle()
  expect((await buttonKeys(pane)).some(key => key.startsWith('term:'))).toBe(true)
  await pane.press({ key: 'view:work' })
  await settle()
  expect((await buttonKeys(pane)).some(key => key.startsWith('term:'))).toBe(false)
})

test("another session's lease renders nothing", async ($, on) => {
  world(on, { [`${LEASES}/default__w2.json`]: lease('sess-other'), [VIEW]: viewText() })
  const pane = await openPane($)
  expect(await buttonKeys(pane)).toEqual([])
  expect(await lines(pane)).toEqual([])
  expect(await pane.find({ type: 'Text', text: /drives no auto programme/ })).toBeDefined()
})

test('a fixed-cadence proposal names its interval, and action labels carry no doubled hotkey', async ($, on) => {
  const terms = contractPart().terms.map(one => ({ ...one }))
  const at = terms.findIndex(one => one.key === 'cadence')
  terms[at] = term('cadence', { proposal: { value: 'fixed', extras: { seconds: 900 }, at: '2026-10-19T09:00:00Z', origin: 'ui', state: 'pending' } })
  world(on, { [LEASE]: lease(), [VIEW]: viewText({ contract: contractPart(terms) }) })
  const pane = await contractPane($)
  expect((await lines(pane)).find(line => line.includes('cadence '))).toContain('proposed: fixed every 15 min')
  const reread = await findNode(pane, one => one.type === 'Button' && one.props?.key === 'act:reread')
  expect(reread?.props?.label).toBe('ask the PM to re-read the rules')
})

test('a stop-time proposal names its time in the row and in the reply to type', async ($, on) => {
  const terms = contractPart().terms.map(one => ({ ...one }))
  const at = terms.findIndex(one => one.key === 'stop_rule')
  const extras = { until: '2026-10-20T18:00:00Z' }
  terms[at] = term('stop_rule', { proposal: { value: 'until_time', extras, at: '2026-10-19T09:00:00Z', origin: 'ui', state: 'pending' } })
  world(on, { [LEASE]: lease(), [VIEW]: viewText({ contract: contractPart(terms) }) })
  const pane = await contractPane($)
  expect((await lines(pane)).find(line => line.includes('stop rule '))).toContain('proposed: until_time until 2026-10-20T18:00:00Z')
  await pane.press({ key: 'term:stop_rule' })
  await settle()
  const drawn = await lines(pane)
  expect(drawn.some(line => line.includes('amend stop rule to until time until 2026-10-20T18:00:00Z'))).toBe(true)
})
