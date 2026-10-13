import { expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { PANE_PROPS, call, create, fakeFs, jsonOf } from './fixtures/world'

// Titles as older versions saved them: keyed by the raw address, one pull request under both of its spellings.
const LEGACY = {
  'https://github.com/o/r/issues/1': { title: '#1 Issue spelling', kind: 'gh-issue', updatedAt: 1 },
  'https://github.com/o/r/pull/1': { title: '#1 Pull spelling', kind: 'gh-pr', status: 'open', updatedAt: 2 },
  'https://github.com/o/r/issues/2': { title: '#2 Only an issue', kind: 'gh-issue', status: 'closed', updatedAt: 3 },
  'https://acme.slack.com/archives/C0123ABCD/p1791761128357239?thread_ts=1791759796.763609&cid=C0123ABCD': { title: 'Release thread', kind: 'slack-thread', updatedAt: 4 },
  'https://linear.app/acme/issue/WEB-12': { title: 'WEB-12 Legacy Linear', kind: 'linear-issue', status: 'Todo', trail: ['Web'], updatedAt: 5 },
}

const ITEMS = [
  'https://github.com/o/r/pull/1',
  'https://github.com/o/r/issues/2',
  'https://acme.slack.com/archives/C0123ABCD/p1791759796763609',
  'https://linear.app/acme/issue/WEB-12',
]

function world(on: On, saved: Record<string, unknown>) {
  const w = fakeFs(on)
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('command.run', () => ({ text: '' }))
  on('store.get', (_$, e, next) => (e.key === 'titles' ? { value: saved } : next(e)))
  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc
  on('tool.call', async () => ({ result: [{ type: 'text', text: ITEMS.join('\n') }] }) as never)
  return w
}

test('a store of raw-address titles names its items in a group, on the group page and in Recent', async ($, on) => {
  world(on, LEGACY)
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)
  const { id } = await create($, ITEMS.map(target => ({ target })), 'Legacy')
  const items = jsonOf(await call($, 'read_group', { id })).items as { ref: string; title: string | null }[]
  expect(items.map(one => [one.ref, one.title])).toEqual([
    ['https://github.com/o/r/pull/1', '#1 Pull spelling'],
    ['https://github.com/o/r/issues/2', '#2 Only an issue'],
    ['https://acme.slack.com/archives/C0123ABCD/p1791759796763609', 'Release thread'],
    ['https://linear.app/acme/issue/WEB-12', 'WEB-12 Legacy Linear'],
  ])

  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: PANE_PROPS, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  await ui.press({ key: 'item-0' })
  const page = JSON.stringify(await ui.drawn())
  for (const title of ['#1 Pull spelling', '#2 Only an issue', 'Release thread', 'WEB-12 Legacy Linear']) expect(page).toContain(title)
  expect(page).not.toContain('Issue spelling')

  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc
  await $.tool.call({ tool: 'mcp__github__search_issues', tool_use_id: 'r1', q: 'x' } as never)
  await ui.press({ key: 'mode-recent' })
  const recent = JSON.stringify(await ui.drawn())
  for (const title of ['#1 Pull spelling', '#2 Only an issue', 'Release thread', 'WEB-12 Legacy Linear']) expect(recent).toContain(title)
  expect(recent).not.toContain('Issue spelling')
  await ui.unmount()
})
