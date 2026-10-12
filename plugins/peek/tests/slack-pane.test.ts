import { expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { CHANNEL_RESULT, THREAD_RESULT } from './fixtures/slack/mcp'

const NOW = 1_792_000_000_000
const PARENT = 'https://acme.slack.com/archives/C0123ABCD/p1791759796763609'
const REPLY = 'https://acme.slack.com/archives/C0123ABCD/p1791761128357239?thread_ts=1791759796.763609&cid=C0123ABCD'
let sessions = 0

function fakeWorld(on: On, options: { isMcpConnected?: boolean } = {}) {
  const calls: { server: string; tool: string }[] = []
  on('session.id', () => ({ value: `slack-pane-${++sessions}` }))
  on('session.cwd', () => ({ value: '/repo' }))
  on('env.get', (_$, e) => ({ value: e.name === 'HOME' ? '/home' : undefined }))
  on('http.fetch', () => ({ value: { status: 404, ok: false, headers: {}, text: '' } }))
  on('clock.now', () => ({ value: NOW }))
  on('ui.open', () => ({ value: { isPlaced: true as const } }))
  on('ui.toast', () => ({ value: undefined }))
  on('fs.stat', (_$, e) => {
    throw new Error(`ENOENT ${e.path}`)
  })
  on('fs.read', (_$, e) => {
    throw new Error(`ENOENT ${e.path}`)
  })
  on('process.run', () => ({ value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  on('mcp.call', (_$, e) => {
    calls.push({ server: e.server, tool: e.tool })
    if (options.isMcpConnected === false) throw new Error(`MCP server "${e.server}" is not connected`)
    const text = e.tool === 'slack_read_thread' ? THREAD_RESULT : CHANNEL_RESULT
    return { value: { content: [{ type: 'text', text }], isError: false } }
  })
  return { calls }
}

const props = {
  title: 'Peek',
  isFocused: true,
  bodyColumns: 100,
  placement: 'dock' as const,
  scroll: { offset: 0, bodyRows: 40 },
  view: {},
}

test('a Slack reply link opens its thread: title, channel, starter, reply count, replies and the source line', async ($, on) => {
  const { calls } = fakeWorld(on)
  await $.command.run({ command: 'peek', args: REPLY } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ text: /Widgets 0\.82 published/ })).toBeDefined()
  expect(await ui.find({ text: /^DETAILS$/ })).toBeDefined()
  expect(await ui.find({ text: 'Ada Lovelace' })).toBeDefined()
  expect(await ui.find({ text: /#release-notes/ })).toBeDefined()
  expect(await ui.find({ text: /^MESSAGE $/ })).toBeDefined()
  expect(await ui.find({ text: /^COMMENTS $/ })).toBeDefined()
  expect(await ui.find({ text: 'Grace Hopper' })).toBeDefined()
  expect(await ui.find({ text: /via Slack MCP · 0s ago/ })).toBeDefined()
  expect(calls[0]).toEqual({ server: 'plugin_slack_slack', tool: 'slack_read_thread' })
  await ui.unmount()
})

test('without the Slack MCP server or a Slack CLI the page says how to connect Slack, with no raw error', async ($, on) => {
  fakeWorld(on, { isMcpConnected: false })
  await $.command.run({ command: 'peek', args: PARENT } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ text: 'Slack is not connected' })).toBeDefined()
  expect(await ui.find({ text: /connect the Slack MCP server/ })).toBeDefined()
  expect(await ui.find({ text: /MCP server "/ })).toBeUndefined()
  expect((await ui.find({ key: 'open' }))?.text).toMatch(/Open in browser/)
  await ui.unmount()
})

test('a thread and a reply link inside it mentioned in the conversation are one Recent row', async ($, on) => {
  fakeWorld(on)
  await $.command.run({ command: 'peek', args: PARENT } as never)
  await $.session.append({ message: { type: 'assistant', content: [{ type: 'text', text: `See ${REPLY} and ${PARENT}.` }] } } as never).catch(() => undefined)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  await ui.press({ key: 'mode-recent' })
  expect(await ui.find({ text: /Widgets 0\.82 published/ })).toBeDefined()
  expect(await ui.find({ text: /acme · #release-notes/ })).toBeDefined()
  expect(await ui.find({ text: / 1 files · session/ })).toBeDefined()
  expect(await ui.find({ text: /^2 replies · 2× · / })).toBeDefined()
  await ui.unmount()
})
