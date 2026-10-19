import { expect, test } from 'claude-code/testing'

import {
  LEASE,
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
  prompts,
  settle,
  term,
  verbs,
  viewText,
  workEntry,
  world,
} from './test-world'
import type { Pane } from './test-world'

const COMPACTED =
  'programme.py: context was compacted: read the rules in force above, then run `programme.py rules --ack`'

async function press(pane: Pane, key: string) {
  await pane.press({ key })
  await settle()
}

async function type(pane: Pane, key: string, text: string) {
  await pane.input({ key, text })
  await settle()
}

const lineWith = async (pane: Pane, text: string) => {
  const drawn = await lines(pane)
  return drawn.find(line => line.includes(text))
}
const has = async (pane: Pane, text: string) => (await lineWith(pane, text)) !== undefined
const lineAfter = async (pane: Pane, label: string) => {
  const drawn = await lines(pane)
  const at = drawn.findIndex(line => line.trim() === label)
  return at === -1 ? undefined : drawn[at + 1]?.trim()
}

test('proposing cadence every 15 min runs propose-term cadence fixed --seconds 900 as the driving session', async ($, on) => {
  world(on, { [LEASE]: lease(), [VIEW]: viewText() })
  const calls = verbs(on)
  const pane = await contractPane($)
  await press(pane, 'term:cadence')
  await type(pane, 'custom:cadence:minutes', '15')
  await press(pane, 'act:propose')
  expect(calls).toHaveLength(1)
  expect(calls[0]!.argv[0]).toMatch(/\/lib\/programme\.sh$/)
  expect(calls[0]!.argv.slice(1)).toEqual(['propose-term', 'cadence', 'fixed', '--seconds', '900', '--origin', 'ui'])
  expect(calls[0]!.env.CLAUDE_CODE_SESSION_ID).toBe('sess-pm')
})

test('a custom cadence of 20 minutes runs --seconds 1200', async ($, on) => {
  world(on, { [LEASE]: lease(), [VIEW]: viewText() })
  const calls = verbs(on)
  const pane = await contractPane($)
  await press(pane, 'term:cadence')
  await type(pane, 'custom:cadence:minutes', '20')
  await press(pane, 'act:propose')
  expect(calls.map(call => call.argv.slice(1))).toEqual([
    ['propose-term', 'cadence', 'fixed', '--seconds', '1200', '--origin', 'ui'],
  ])
})

test('a cadence that is not a whole number of minutes is refused in the pane and runs nothing', async ($, on) => {
  world(on, { [LEASE]: lease(), [VIEW]: viewText() })
  const calls = verbs(on)
  const pane = await contractPane($)
  await press(pane, 'term:cadence')
  await type(pane, 'custom:cadence:minutes', 'soon')
  expect(await has(pane, 'a whole number of minutes')).toBe(true)
  await press(pane, 'act:propose')
  expect(calls).toHaveLength(0)
})

test('proposing a picked option runs propose-term with that option', async ($, on) => {
  world(on, { [LEASE]: lease(), [VIEW]: viewText() })
  const calls = verbs(on)
  const pane = await contractPane($)
  await press(pane, 'term:autonomy')
  await press(pane, 'option:autonomy:b')
  await press(pane, 'act:propose')
  expect(calls.map(call => call.argv.slice(1))).toEqual([['propose-term', 'autonomy', 'b', '--origin', 'ui']])
  expect(await has(pane, 'proposed autonomy: b')).toBe(true)
})

test('a verb that exits non-zero shows its error and the pane keeps the old state', async ($, on) => {
  world(on, { [LEASE]: lease(), [VIEW]: viewText() })
  const calls = verbs(on, () => ({ exitCode: 2, stderr: "programme.py: 'o3' is not an option of 'cadence'\n" }))
  const pane = await contractPane($)
  await press(pane, 'term:cadence')
  await press(pane, 'option:cadence:o3')
  const before = await lines(pane)
  await press(pane, 'act:propose')
  const after = await lines(pane)
  expect(after.some(line => line.includes("programme.py: 'o3' is not an option of 'cadence'"))).toBe(true)
  expect(after.filter(line => !line.includes('is not an option'))).toEqual(before)
  expect(await has(pane, 'Proposed: on_change · pending')).toBe(true)

  await press(pane, 'act:propose')
  expect(calls.map(call => call.argv.slice(1))).toEqual([
    ['propose-term', 'cadence', 'o3', '--origin', 'ui'],
    ['propose-term', 'cadence', 'o3', '--origin', 'ui'],
  ])
})

test('an engine refusal shows as an error, not as success', async ($, on) => {
  world(on, { [LEASE]: lease(), [VIEW]: viewText() })
  verbs(on, () => ({ deny: 'commands are off in this session' }))
  const pane = await contractPane($)
  await press(pane, 'term:autonomy')
  await press(pane, 'option:autonomy:b')
  await press(pane, 'act:propose')
  const error = await lineWith(pane, 'commands are off in this session')
  expect(error).toContain('✗')
  expect(error).toContain('not run')
  expect(await has(pane, 'proposed autonomy')).toBe(false)
})

test('x clears the proposal on the open term', async ($, on) => {
  world(on, { [LEASE]: lease(), [VIEW]: viewText() })
  const calls = verbs(on)
  const pane = await contractPane($)
  await press(pane, 'term:cadence')
  await press(pane, 'act:clear')
  expect(calls.map(call => call.argv.slice(1))).toEqual([['clear-proposal', 'cadence', '--origin', 'ui']])
  expect(await has(pane, 'proposal cleared')).toBe(true)
})

test('n opens a note field; Enter saves the note and an empty note clears them', async ($, on) => {
  world(on, { [LEASE]: lease(), [VIEW]: viewText() })
  const calls = verbs(on)
  const pane = await contractPane($)
  await press(pane, 'term:cadence')
  expect(await findNode(pane, one => one.type === 'Input' && one.props?.key === 'note:cadence')).toBeUndefined()
  await press(pane, 'act:note')
  const field = await findNode(pane, one => one.type === 'Input' && one.props?.key === 'note:cadence')
  expect(field?.props?.autoFocus).toBe(true)
  await type(pane, 'note:cadence', 'check again friday')
  await press(pane, 'act:note')
  await type(pane, 'note:cadence', '')
  expect(calls.map(call => call.argv.slice(1))).toEqual([
    ['note-term', 'cadence', 'check again friday', '--origin', 'ui'],
    ['note-term', 'cadence', '--clear', '--origin', 'ui'],
  ])
  expect(await findNode(pane, one => one.type === 'Input' && one.props?.key === 'note:cadence')).toBeUndefined()
})

test('e asks the PM to re-read and the pane shows "re-read requested"', async ($, on) => {
  world(on, { [LEASE]: lease(), [VIEW]: viewText() })
  const calls = verbs(on)
  const pane = await contractPane($)
  expect(await has(pane, 're-read requested')).toBe(false)
  await press(pane, 'act:reread')
  expect(calls.map(call => call.argv.slice(1))).toEqual([['request-reread', '--origin', 'ui']])
  expect(await has(pane, 're-read requested')).toBe(true)
})

test('f on an instruction closes it as fulfilled with the why typed into the field', async ($, on) => {
  world(on, { [LEASE]: lease(), [VIEW]: viewText() })
  const calls = verbs(on)
  const pane = await contractPane($)
  expect(await pane.find({ key: 'act:fulfil' })).toBeUndefined()
  await personFocus($, 'instruction:i1')
  await settle()
  await press(pane, 'act:fulfil')
  await type(pane, 'why:i1', 'closed in PR 12')
  expect(calls.map(call => call.argv.slice(1))).toEqual([
    ['close-instruction', 'i1', '--as', 'fulfilled', '--why', 'closed in PR 12', '--origin', 'ui'],
  ])
  expect(await has(pane, 'instruction closed as fulfilled')).toBe(true)
})

test('while the compact flag is set, close as fulfilled shows the compaction error and keeps the instruction', async ($, on) => {
  world(on, { [LEASE]: lease(), [VIEW]: viewText() })
  verbs(on, () => ({ exitCode: 1, stdout: 'Rules in force:\n  cadence: fixed\n', stderr: `${COMPACTED}\n` }))
  const pane = await contractPane($)
  await personFocus($, 'instruction:i1')
  await settle()
  await press(pane, 'act:fulfil')
  await type(pane, 'why:i1', 'done')
  expect(await has(pane, 'context was compacted')).toBe(true)
  expect(await has(pane, 'Rules in force')).toBe(false)
  expect(await has(pane, '"ask before closing"')).toBe(true)
})

test('ticking two tools and adding "sentry" with a description, then p, runs one propose-term call with all three', async ($, on) => {
  world(on, { [LEASE]: lease(), [VIEW]: viewText() })
  const calls = verbs(on)
  const pane = await contractPane($)
  await press(pane, 'term:tools_of_record')
  await press(pane, 'option:tools_of_record:tasks')
  await press(pane, 'option:tools_of_record:plans')
  expect(await lineWith(pane, 'what tasks means')).toContain('')
  expect(await lineWith(pane, 'what plans means')).toContain('')
  await press(pane, 'custom:tools:add')
  await type(pane, 'custom:tools:name', 'sentry')
  await type(pane, 'custom:tools:description', 'Error reports from Sentry')
  expect(calls).toHaveLength(0)
  await press(pane, 'act:propose')
  expect(calls.map(call => call.argv.slice(1))).toEqual([
    [
      'propose-term',
      'tools_of_record',
      'tracker,plans,sentry',
      '--add',
      'sentry',
      '--description',
      'Error reports from Sentry',
      '--origin',
      'ui',
    ],
  ])
})

test('remit takes any herdr space by name, including one outside the remit, and proposes it', async ($, on) => {
  const model = { remit: { spaces: [{ server: 'default', workspace: 'w2' }] } }
  world(on, { [LEASE]: lease(), [VIEW]: viewText({ model }) })
  const calls = verbs(on)
  const pane = await contractPane($)
  await press(pane, 'term:remit')
  await type(pane, 'custom:remit:space', 'default.w9')
  await press(pane, 'act:propose')
  expect(calls.map(call => call.argv.slice(1))).toEqual([['propose-term', 'remit', '--add', 'default.w9', '--origin', 'ui']])
})

test('the action keys are drawn only while the pane is focused, with their hotkeys', async ($, on) => {
  world(on, { [LEASE]: lease(), [VIEW]: viewText() })
  const pane = await contractPane($)
  await press(pane, 'term:cadence')
  const hotkey = async (key: string) => {
    const button = await findNode(pane, one => one.type === 'Button' && one.props?.key === key)
    return button?.props?.hotkey
  }
  expect(await hotkey('act:propose')).toBe('p')
  expect(await hotkey('act:clear')).toBe('x')
  expect(await hotkey('act:note')).toBe('n')
  expect(await hotkey('act:reread')).toBe('e')
  await personFocus($, 'instruction:i1')
  await settle()
  expect(await hotkey('act:fulfil')).toBe('f')

  await pane.redraw({ title: 'Programme', isFocused: false, bodyColumns: 100, placement: 'dock', scroll: { offset: 0, bodyRows: 40 }, view: {} } as never)
  await settle()
  const keys = await buttonKeys(pane)
  expect(keys.filter(key => key.startsWith('act:'))).toEqual([])
})

test('covers AE4: accept on a pending proposal shows the exact reply and sends nothing', async ($, on) => {
  world(on, { [LEASE]: lease(), [VIEW]: viewText() })
  const calls = verbs(on)
  const sent = prompts(on)
  const pane = await contractPane($)
  await press(pane, 'term:cadence')
  expect(await lineAfter(pane, 'Type this:')).toBe('amend cadence to on change')
  const keys = await buttonKeys(pane)
  expect(keys.some(key => /accept|amend|widen/.test(key))).toBe(false)
  expect(calls).toEqual([])
  expect(sent).toEqual([])
})

test('the accept reply names the interval of a fixed cadence', async ($, on) => {
  const terms = defaultTerms()
  terms[3] = term('cadence', {
    value: 'on_change',
    proposal: { value: 'fixed', extras: { seconds: 900 }, at: '2026-10-19T09:00:00Z', origin: 'ui', state: 'pending' },
  })
  world(on, { [LEASE]: lease(), [VIEW]: viewText({ contract: contractPart(terms) }) })
  const pane = await contractPane($)
  await press(pane, 'term:cadence')
  expect(await lineAfter(pane, 'Type this:')).toBe('amend cadence to fixed every 15 min')
})

test('a refused proposal still shows the reply so it can be typed again', async ($, on) => {
  const terms = defaultTerms()
  terms[2] = term('autonomy', {
    proposal: { value: 'b', at: '2026-10-19T09:00:00Z', origin: 'ui', state: 'refused', reason: 'not typed' },
  })
  world(on, { [LEASE]: lease(), [VIEW]: viewText({ contract: contractPart(terms) }) })
  const pane = await contractPane($)
  await press(pane, 'term:autonomy')
  expect(await lineAfter(pane, 'Type this:')).toBe('amend autonomy to b')
})

test('widening the tools of record names every tool that changes, the dropped ones too', async ($, on) => {
  const terms = defaultTerms()
  terms[4] = term('tools_of_record', {
    value: ['tracker', 'tasks'],
    options: [{ name: 'tracker', description: 'd', active: true }, { name: 'tasks', description: 'd', active: true }, { name: 'plans', description: 'd', active: false }],
    proposal: {
      value: ['tracker', 'plans', 'sentry'],
      extras: { add: 'sentry', description: 'Error reports' },
      at: '2026-10-19T09:00:00Z',
      origin: 'ui',
      state: 'pending',
    },
  })
  world(on, { [LEASE]: lease(), [VIEW]: viewText({ contract: contractPart(terms) }) })
  const pane = await contractPane($)
  await press(pane, 'term:tools_of_record')
  expect(await lineAfter(pane, 'Type this:')).toBe('widen tools of record to tracker, plans, sentry and drop tasks')
})

test('widening the remit names the herdr space to add', async ($, on) => {
  const terms = defaultTerms()
  terms[0] = term('remit', {
    proposal: { value: 'space', extras: { add: 'default.w3' }, at: '2026-10-19T09:00:00Z', origin: 'ui', state: 'pending' },
  })
  world(on, { [LEASE]: lease(), [VIEW]: viewText({ contract: contractPart(terms) }) })
  const pane = await contractPane($)
  await press(pane, 'term:remit')
  expect(await lineAfter(pane, 'Type this:')).toBe('widen remit to add herdr space default.w3')
})

test('picking another option on a term with no proposal shows the amend reply', async ($, on) => {
  world(on, { [LEASE]: lease(), [VIEW]: viewText() })
  const sent = prompts(on)
  const pane = await contractPane($)
  await press(pane, 'term:autonomy')
  expect(await has(pane, 'Type this:')).toBe(false)
  await press(pane, 'option:autonomy:b')
  expect(await lineAfter(pane, 'Type this:')).toBe('amend autonomy to b')
  expect(sent).toEqual([])
})

test('the open-instruction template names the selected task', async ($, on) => {
  const work = [workEntry('linear:ENG-1', 'Owner history')]
  world(on, { [LEASE]: lease(), [VIEW]: viewText({ work }) })
  const pane = await openPane($)
  await personFocus($, 'item:linear:ENG-1')
  await settle()
  await press(pane, 'view:contract')
  expect(await lineAfter(pane, 'To add an instruction, type this:')).toBe('Instruction for Owner history:')
  const drawn = await lines(pane)
  expect(drawn.some(line => line.endsWith('Instruction for Owner history: '))).toBe(true)
})

test('with no task selected the template is for the whole programme', async ($, on) => {
  world(on, { [LEASE]: lease(), [VIEW]: viewText() })
  const pane = await contractPane($)
  expect(await lineAfter(pane, 'To add an instruction, type this:')).toBe('Instruction for the whole programme:')
})

test('a focused instruction shows the withdraw reply', async ($, on) => {
  world(on, { [LEASE]: lease(), [VIEW]: viewText() })
  const sent = prompts(on)
  const pane = await contractPane($)
  await personFocus($, 'instruction:i1')
  await settle()
  expect(await lineAfter(pane, 'Type this:')).toBe('Withdraw instruction "ask before closing"')
  expect(sent).toEqual([])
})
