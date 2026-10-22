import { expect, test } from 'claude-code/testing'

import { LEASE, VIEW, contractPane, lease, lines, personFocus, prompts, settle, verbs, viewText, world } from './test-world'

// The kit's sandbox has no file access, so this guard proves the rule by driving every action; the source scan
// for the same calls lives in tests/unit/programme-view-mod.test.sh.
test('no action in the pane submits, suggests or fills a prompt', async ($, on) => {
  const model = { remit: { spaces: [{ server: 'default', workspace: 'w3' }] } }
  world(on, { [LEASE]: lease(), [VIEW]: viewText({ model }) })
  const calls = verbs(on)
  const sent = prompts(on)
  const pane = await contractPane($)
  const press = async (key: string) => {
    await pane.press({ key })
    await settle()
  }
  const type = async (key: string, text: string) => {
    await pane.input({ key, text })
    await settle()
  }

  const picks = { cadence: 'o3', tools_of_record: 'plans', remit: 'b', stop_rule: 'b' }
  for (const [key, pick] of Object.entries(picks)) {
    await press(`term:${key}`)
    await press(`option:${key}:${pick}`)
    if (key === 'cadence') await type('custom:cadence:minutes', '15')
    if (key === 'remit') await type('custom:remit:space', 'default.w3')
    if (key === 'stop_rule') await type('custom:stop_rule:until', '2026-10-20T18:00:00Z')
    if (key === 'tools_of_record') {
      await press('custom:tools:add')
      await type('custom:tools:name', 'sentry')
      await type('custom:tools:description', 'Error reports')
    }
    await press('act:propose')
    if (key === 'cadence') await press('act:clear')
    await press('act:note')
    await type(`note:${key}`, 'a note')
  }
  await press('act:reread')
  await personFocus($, 'ruling:i1')
  await settle()
  await press('act:fulfil')
  await type('why:i1', 'done')

  expect(calls.length).toBe(11)
  const drawn = await lines(pane)
  expect(drawn.some(line => line.includes('Type this:'))).toBe(true)
  expect(sent).toEqual([])
})
