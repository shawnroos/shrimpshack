import { expect, test } from 'claude-code/testing'
import type { Engine, Mounted } from 'claude-code/testing'

import { GLYPH } from './palette'
import { LEASE, VIEW, findNode, lease, lines, openPane, prompts, settle, setupPart, setupStep, viewText, workEntry, world } from './test-world'
import type { Pane } from './test-world'

async function mountPane($: Engine): Promise<Pane> {
  const pane = await $.ui.mount({
    plugin: 'auto',
    surface: 'terminal',
    component: 'Pane',
    requestId: 'programme-view',
    props: { title: 'Programme', isFocused: false, bodyColumns: 100, placement: 'dock', scroll: { offset: 0, bodyRows: 60 }, view: {} },
  } as never)
  await settle()
  return pane as Pane
}

async function mountBand($: Engine): Promise<Mounted<'terminal', 'AbovePrompt'>> {
  return $.ui.mount({
    plugin: 'auto',
    surface: 'terminal',
    component: 'AbovePrompt',
    requestId: 'above-prompt',
    props: { hasSurvey: false, isWorking: false, maxRows: 20, bodyColumns: 120 },
  } as never)
}

async function start($: Engine) {
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
}

const drawn = async (pane: Pane) => (await lines(pane)).join('\n')

test('Covers AE5: /auto:programme with no lease opens a waiting pane, passes the command on, then shows setup', async ($, on) => {
  const files: Record<string, string> = {}
  const mtimes: Record<string, number> = {}
  const { opens, ran, clock } = world(on, files, mtimes)
  await start($)
  const result = await $.command.run({ command: 'auto:programme', args: '' } as never)
  expect(ran).toEqual([{ command: 'auto:programme', args: '' }])
  expect(result.text).toBe('core ran auto:programme')
  expect(result.context).toEqual(['core note'])
  expect(opens.map(open => open.id)).toEqual(['programme-view'])

  const pane = await mountPane($)
  expect(await pane.find({ type: 'Text', text: /Waiting for setup to start/ })).toBeDefined()

  files[LEASE] = lease()
  files[VIEW] = viewText({ setup: setupPart() })
  mtimes[VIEW] = 2000
  await clock.advance(2000)
  await settle()
  expect(await drawn(pane)).toContain('Programme setup')
  expect(await pane.find({ type: 'Text', text: /Waiting for setup/ })).toBeUndefined()
})

test('a waiting pane that sees no programme for a minute says setup has not started and names /auto:programme', async ($, on) => {
  const { clock } = world(on, {})
  await start($)
  await $.command.run({ command: 'auto:programme', args: '' } as never)
  const pane = await mountPane($)
  expect(await pane.find({ type: 'Text', text: /has not started/ })).toBeUndefined()
  await clock.advance(62_000)
  await settle()
  expect(await pane.find({ type: 'Text', text: /Setup has not started.*\/auto:programme/ })).toBeDefined()
})

test('when the pane cannot open, /auto:programme still runs and tells the model to name /programme-view first', async ($, on) => {
  const { ran, unplace } = world(on, {})
  unplace()
  await start($)
  const result = await $.command.run({ command: 'auto:programme', args: '' } as never)
  expect(ran.length).toBe(1)
  expect(result.context?.[0]).toBe('core note')
  expect(result.context?.at(-1)).toContain('/programme-view')
})

test('/programme-view with no lease still refuses and opens nothing', async ($, on) => {
  const { opens } = world(on, {})
  await start($)
  const result = await $.command.run({ command: 'programme-view' } as never)
  expect(result.text).toContain('drives no auto programme')
  expect(opens).toEqual([])
})

test('the setup view marks done, current and upcoming steps, groups them, and lists what is in and out', async ($, on) => {
  world(on, { [LEASE]: lease(), [VIEW]: viewText({ setup: setupPart() }) })
  const pane = await openPane($, false, 60)
  const all = await lines(pane)
  const text = all.join('\n')
  expect(text).toContain('Programme setup')
  expect(text).toContain('draft, not accepted')

  const inLine = all.find(line => line.startsWith('In'))
  const outLine = all.find(line => line.startsWith('Out'))
  expect(inLine).toContain('shrimpshack, ai-chat-backend')
  expect(inLine).toContain('WEB')
  expect(outLine).toContain('Infra')
  expect(outLine).toContain('ai-editor-backend')
  const where = all.findIndex(line => line.includes('Where'))
  const sources = all.findIndex(line => line.includes('Sources'))
  expect(where).toBeGreaterThan(-1)
  expect(all.indexOf(inLine ?? '')).toBeLessThan(where)

  const scope = all.findIndex(line => line.trim() === 'Scope')
  const pacing = all.findIndex(line => line.trim() === 'Pacing')
  expect(scope).toBeGreaterThan(-1)
  expect(scope).toBeLessThan(where)
  expect(where).toBeLessThan(sources)
  expect(sources).toBeLessThan(pacing)

  const cadence = all.findIndex(line => line.includes('Cadence'))
  expect(all[where]).toContain(GLYPH.done)
  expect(all[sources]).toContain(GLYPH.current)
  expect(all[cadence]).toContain(GLYPH.planned)
  expect(all[cadence]).not.toContain(GLYPH.done)
  const doneMark = await findNode(pane, one => one.type === 'Text' && one.children?.[0] === `${GLYPH.done}  `)
  expect(doneMark?.props?.color).toBe('success')
  expect(all[sources]).toContain('current')
  expect(all[where]).toContain('AI-Editor')
  expect(text).toContain('Recommended: tracker, tasks, plans · plugin default')
  expect(text).toContain('Owner history')
})

test('a step that needs a typed reply shows "Type this:" and the reply, and no picker hint', async ($, on) => {
  const setup = setupPart()
  setup.current = 'rulings'
  setup.steps = setup.steps.map(step =>
    step.key === 'sources' ? { ...step, state: 'done' } : step.key === 'rulings' ? { ...step, state: 'current' } : step,
  )
  world(on, { [LEASE]: lease(), [VIEW]: viewText({ setup }) })
  const pane = await openPane($, false, 60)
  const all = await lines(pane)
  const rulings = all.findIndex(line => line.includes('Rulings and reserved areas'))
  expect(rulings).toBeGreaterThan(-1)
  expect(all[rulings + 1]?.trim()).toBe('Type this:')
  expect(all[rulings + 2]?.trim()).toBe('approve the proposed rulings')
  const accept = all.findIndex(line => line.includes('Accept') && line.includes('not accepted'))
  expect(accept).toBeGreaterThan(rulings)
  expect(all[accept + 1]?.trim()).toBe('Type this:')
  expect(all[accept + 2]?.trim()).toBe('accept the agreement')
  expect(all.join('\n')).not.toContain('Answer in the chat')
})

test('pending decisions show with the reply to type when the data carries one', async ($, on) => {
  const model = {
    decisions_for_shawn: [
      { kind: 'handed', item: 'WEB-1', question: 'merge the owner history PR?', reply: 'merge WEB-1' },
      { kind: 'proposed_rule', item: null, question: 'adopt rule r1?' },
      { kind: 'agreement', item: null, question: 'accept the agreement?' },
    ],
  }
  world(on, { [LEASE]: lease(), [VIEW]: viewText({ setup: setupPart(), model }) })
  const pane = await openPane($, false, 80)
  const all = await lines(pane)
  const text = all.join('\n')
  expect(text).toContain('merge the owner history PR?')
  expect(text).toContain('adopt rule r1?')
  expect(text).not.toContain('accept the agreement?')
  const merge = all.findIndex(line => line.includes('merge the owner history PR?'))
  expect(all[merge + 1]?.trim()).toBe('Type this:')
  expect(all[merge + 2]?.trim()).toBe('merge WEB-1')
})

test('the work view shows pending decisions with their reply to type', async ($, on) => {
  const model = { decisions_for_shawn: [{ kind: 'handed', item: 'WEB-1', question: 'ship the owner history PR?', reply: 'ship WEB-1' }] }
  world(on, { [LEASE]: lease(), [VIEW]: viewText({ work: [workEntry('WEB-1', 'Owner history')], model }) })
  const pane = await openPane($, false, 80)
  const all = await lines(pane)
  expect(all.join('\n')).not.toContain('Programme setup')
  const ship = all.findIndex(line => line.includes('ship the owner history PR?'))
  expect(ship).toBeGreaterThan(all.findIndex(line => line.includes('Owner history')))
  expect(all[ship + 1]?.trim()).toBe('Type this:')
  expect(all[ship + 2]?.trim()).toBe('ship WEB-1')
})

test('Covers AE6: /auto:programme-status with no args and a lease focuses the pane and answers in one line', async ($, on) => {
  const { opens, ran } = world(on, { [LEASE]: lease(), [VIEW]: viewText() })
  await start($)
  const result = await $.command.run({ command: 'auto:programme-status', args: '' } as never)
  expect(ran).toEqual([])
  expect(opens).toEqual([{ id: 'programme-view', focus: true }])
  expect(result.text?.split('\n').length).toBe(1)
  expect(result.text).toContain('Programme pane')
})

test('/auto:programme-status with a run id passes through to the command', async ($, on) => {
  const { opens, ran } = world(on, { [LEASE]: lease(), [VIEW]: viewText() })
  await start($)
  const result = await $.command.run({ command: 'auto:programme-status', args: 'prog-2' } as never)
  expect(ran).toEqual([{ command: 'auto:programme-status', args: 'prog-2' }])
  expect(result.text).toBe('core ran auto:programme-status')
  expect(opens).toEqual([])
})

test('/auto:programme-status with no lease passes through to the command', async ($, on) => {
  const { opens, ran } = world(on, {})
  await start($)
  await $.command.run({ command: 'auto:programme-status', args: '' } as never)
  expect(ran.length).toBe(1)
  expect(opens).toEqual([])
})

test('/auto:programme-status passes through when no pane can be placed', async ($, on) => {
  const { ran, unplace } = world(on, { [LEASE]: lease(), [VIEW]: viewText() })
  unplace()
  await start($)
  await $.command.run({ command: 'auto:programme-status', args: '' } as never)
  expect(ran.length).toBe(1)
})

test('the band shows setup progress while the setup part exists', async ($, on) => {
  world(on, { [LEASE]: lease(), [VIEW]: viewText({ setup: setupPart(), work: [workEntry('WEB-1', 'Owner history')] }) })
  on('ui.render', ($$, e) => $$.ui.resolve(e).Text({ children: 'beneath the band' }))
  await openPane($)
  const band = await mountBand($)
  expect(await band.find({ type: 'Client' })).toBeUndefined()
  expect(await band.find({ type: 'Text', text: /Setup 2\/7 · sources ▸ cadence ▸ .* ▸ accept/ })).toBeDefined()
})

test('after acceptance the pane shows the work view and the band shows work tracks', async ($, on) => {
  world(on, { [LEASE]: lease(), [VIEW]: viewText({ work: [workEntry('WEB-1', 'Owner history')] }) })
  on('ui.render', ($$, e) => $$.ui.resolve(e).Text({ children: 'beneath the band' }))
  const pane = await openPane($, false)
  const text = await drawn(pane)
  expect(text).not.toContain('Programme setup')
  expect(text).toContain('Owner history')
  const band = await mountBand($)
  expect(await band.find({ type: 'Client', key: 'band' })).toBeDefined()
  expect(await band.find({ type: 'Text', text: /Setup \d/ })).toBeUndefined()
})

test('a malformed setup part does not break the view', async ($, on) => {
  const setup = { current: 3, steps: [null, 'x', setupStep('where', 'scope', 'bogus')], scope: 'nope' }
  world(on, { [LEASE]: lease(), [VIEW]: viewText({ setup, work: [workEntry('WEB-1', 'Owner history')] }) })
  const pane = await openPane($, false)
  const text = await drawn(pane)
  expect(text).toContain('Programme setup')
  expect(text).toContain('where')
})

test('no action in the setup view submits, suggests or fills a prompt', async ($, on) => {
  world(on, { [LEASE]: lease(), [VIEW]: viewText({ setup: setupPart() }) })
  const sent = prompts(on)
  await start($)
  await $.command.run({ command: 'auto:programme', args: '' } as never)
  await $.command.run({ command: 'auto:programme-status', args: '' } as never)
  const pane = await openPane($)
  await pane.press({ key: 'view:contract' })
  await settle()
  await pane.press({ key: 'view:work' })
  await settle()
  expect(sent).toEqual([])
})
