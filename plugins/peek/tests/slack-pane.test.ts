import { expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { exited } from './fixtures/results'
import { PANE_PROPS, PNG_HEAD, baseWorld, fakeHttp, fakeProcess, noDisk } from './fixtures/world'
import { ADA_PIC, CHANNEL_RESULT, FILES_RESULT, THREAD_RESULT, fileResult, usersResult } from './fixtures/slack/mcp'

const NOW = 1_792_000_000_000
const PARENT = 'https://acme.slack.com/archives/C0123ABCD/p1791759796763609'
const REPLY = 'https://acme.slack.com/archives/C0123ABCD/p1791761128357239?thread_ts=1791759796.763609&cid=C0123ABCD'
let sessions = 0

type WorldOptions = { isMcpConnected?: boolean; thread?: string; file?: 'image' | 'refuse'; pic?: boolean }

function fakeWorld(on: On, options: WorldOptions = {}) {
  const calls: { server: string; tool: string }[] = []
  const ran: string[][] = []
  on('session.id', () => ({ value: `slack-pane-${++sessions}` }))
  baseWorld(on)
  fakeHttp(on)
  on('clock.now', () => ({ value: NOW }))
  noDisk(on)
  on('fs.read', (_$, e) => {
    if (e.as === 'bytes' && e.path.endsWith('.png')) return { value: { base64: `${PNG_HEAD}${'A'.repeat(4000)}` } }
    throw new Error(`ENOENT ${e.path}`)
  })
  fakeProcess(
    on,
    argv => {
      const [bin = ''] = argv
      if (bin === 'sh') return exited(0, String(argv[2]).includes('.slack/bin') ? '' : 'curl\n')
      if (bin === 'sips') return exited(0, 'pixelWidth: 800\npixelHeight: 600\n')
      if (bin === '/usr/bin/dscacheutil') return exited(0, 'ip_address: 93.184.216.34\n')
      if (bin === 'curl' && argv.includes('-o')) return exited(0, '200 512 ')
      return exited(0)
    },
    ran,
  )
  on('mcp.call', (_$, e) => {
    calls.push({ server: e.server, tool: e.tool })
    if (options.isMcpConnected === false) throw new Error(`MCP server "${e.server}" is not connected`)
    const text = (body: string) => ({ value: { content: [{ type: 'text', text: body }], isError: false } })
    if (e.tool === 'slack_read_thread') return text(options.thread ?? THREAD_RESULT)
    if (e.tool === 'slack_read_file') {
      if (options.file !== 'image') throw new Error('Permission to use slack_read_file was denied')
      return { value: fileResult(String(e.args?.file_id), `${PNG_HEAD}AAAA`) }
    }
    if (e.tool === 'slack_search_users') return text(usersResult(options.pic ? [{ name: 'Ada Lovelace', id: 'U0AAA1111', pic: ADA_PIC }] : []))
    return text(CHANNEL_RESULT)
  })
  return { calls, ran }
}

const props = PANE_PROPS

test('a Slack reply link opens its thread: title, channel, starter, reply count, replies and the source line', async ($, on) => {
  const { calls } = fakeWorld(on)
  await $.command.run({ command: 'peek', args: REPLY } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ text: /Widgets 0\.82 published/ })).toBeDefined()
  expect(await ui.find({ text: /^DETAILS$/ })).toBeDefined()
  expect(await ui.find({ text: 'Ada Lovelace' })).toBeDefined()
  expect(await ui.find({ text: /#release-notes/ })).toBeDefined()
  expect(await ui.find({ text: /^THREAD $/ })).toBeDefined()
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

test('every message shows its speaker badge and a time that opens that message in Slack; replies sit inset under the first message', async ($, on) => {
  const { ran } = fakeWorld(on)
  await $.command.run({ command: 'peek', args: PARENT } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ text: ' AL ' })).toBeDefined()
  expect(await ui.find({ text: ' GH ' })).toBeDefined()
  expect((await ui.find({ key: 'slack-time-0' }))?.text).toMatch(/^Oct \d+, \d+:\d\d [AP]M$|ago$/)
  expect((await ui.find({ key: 'slack-msg-0' }))?.text).not.toMatch(/^│/)
  expect((await ui.find({ key: 'slack-msg-1' }))?.props).toMatchObject({ flexDirection: 'row', marginLeft: 1 })
  expect((await ui.find({ key: 'slack-msg-1' }))?.text).toMatch(/^│\n│/)
  await ui.press({ key: 'slack-time-1' })
  expect(ran.at(-1)).toEqual(['open', REPLY])
  await ui.unmount()
})

test('files the page may not read show as file rows that open the message in Slack, and the page still draws', async ($, on) => {
  fakeWorld(on, { thread: FILES_RESULT })
  await $.command.run({ command: 'peek', args: 'https://acme.slack.com/archives/C0123ABCD/p1791307392000200' } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ text: /Cutting too early/ })).toBeDefined()
  const tree = JSON.stringify(await ui.drawn())
  expect(tree).toContain('Screenshot 2026-10-06 at 1.22.47 PM.png')
  expect(tree).toContain('spec, v2.pdf · application/pdf · 1.2 MB')
  expect(tree).toContain('[open in Slack](https://acme.slack.com/archives/C0123ABCD/p1791307800000300?thread_ts=1791307392.000200&cid=C0123ABCD)')
  expect(tree.includes(PNG_HEAD)).toBe(false)
  expect((await ui.find({ key: 'slack-file-0-0' }))?.type).toBe('Box')
  await ui.unmount()
})

test('an image file the page may read is drawn inline, beside the picture of a video linked in the message', async ($, on) => {
  fakeWorld(on, { thread: FILES_RESULT.replace('Spec attached.', 'Spec attached.\\n<https://www.youtube.com/watch?v=dQw4w9WgXcQ>'), file: 'image' })
  await $.command.run({ command: 'peek', args: 'https://acme.slack.com/archives/C0123ABCD/p1791307392000200' } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect((await ui.find({ key: 'slack-file-0-0' }))?.type).toBe('Image')
  expect((await ui.find({ key: 'slack-file-1-1' }))?.type).toBe('Image')
  expect((await ui.find({ key: 'slack-file-1-0' }))?.type).toBe('Box')
  expect((await ui.find({ key: 'slack-msg-1-picture-1' }))?.type).toBe('Image')
  expect(JSON.stringify(await ui.drawn())).toContain(PNG_HEAD)
  await ui.unmount()
})

test('a speaker with a profile picture shows it beside the name; one without keeps the initials badge', async ($, on) => {
  fakeWorld(on, { pic: true })
  await $.command.run({ command: 'peek', args: PARENT } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ key: 'slack-avatar-0' })).toBeDefined()
  expect(await ui.find({ text: ' AL ' })).toBeUndefined()
  expect(await ui.find({ text: ' GH ' })).toBeDefined()
  await ui.unmount()
})
