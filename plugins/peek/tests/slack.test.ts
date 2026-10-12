import { describe, expect, test } from 'claude-code/testing'
import type { ProcessRunResult } from 'claude-code'

import { parseRef } from '../hooks/refs'
import type { Ref } from '../hooks/refs'
import { loadSlack, mrkdwnToMarkdown, parseThreadText } from '../hooks/slack'
import type { SlackIo } from '../hooks/slack'
import type { Loaded, RemoteRecord } from '../types'
import { CHANNEL_RESULT, CLI_CHANNEL, CLI_REPLIES, LONE_MESSAGE, THREAD_MORE, THREAD_RESULT, THREAD_TEXT } from './fixtures/slack/mcp'

const NOW = 1_792_000_000_000
const THREAD = 'https://acme.slack.com/archives/C0123ABCD/p1791759796763609'
let sessions = 0

type Call = { server: string; tool: string; args: Record<string, unknown> }
type McpReply = (call: Call) => { content: unknown[]; isError: boolean }

function exited(exitCode: number, stdout = ''): ProcessRunResult {
  return { exitCode, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false }
}

const text = (body: string, isError = false) => ({ content: [{ type: 'text', text: body }], isError })

function world(options: { mcp?: McpReply | 'absent'; cli?: string | null; cliRun?: (argv: readonly string[]) => ProcessRunResult } = {}) {
  const session = `slack-${++sessions}`
  const calls: Call[] = []
  const ran: string[][] = []
  const io: SlackIo = {
    sessionId: async () => session,
    mcpCall: async (server, tool, args) => {
      calls.push({ server, tool, args })
      const mcp = options.mcp ?? 'absent'
      if (mcp === 'absent') throw new Error(`MCP server "${server}" is not connected`)
      return mcp({ server, tool, args })
    },
    run: async argv => {
      ran.push([...argv])
      if (argv[0] === 'sh') return options.cli ? exited(0, `${options.cli}\n`) : exited(0, '')
      return options.cliRun ? options.cliRun(argv) : exited(1)
    },
  }
  return { io, calls, ran }
}

function ref(address: string): Ref {
  const found = parseRef(address)
  if (!found) throw new Error(`bad ref ${address}`)
  return found
}

function record(loaded: Loaded): RemoteRecord {
  if (!loaded.ok) throw new Error(`not loaded: ${JSON.stringify(loaded)}`)
  return loaded.record
}

const meta = (rec: RemoteRecord, label: string) => rec.meta.find(one => one.label === label)?.value

function threadMcp(thread = THREAD_RESULT): McpReply {
  return ({ tool }) => (tool === 'slack_read_thread' ? text(thread) : text(CHANNEL_RESULT))
}

describe('Slack mrkdwn', () => {
  test('links, mentions, emphasis, strike, bullets and entities become markdown', () => {
    expect(mrkdwnToMarkdown('see <https://a.example/x|the doc> or <https://b.example>')).toBe('see [the doc](https://a.example/x) or <https://b.example>')
    expect(mrkdwnToMarkdown('hi <@U0BBB2222|Grace> and <@U0CCC> in <#C0123ABCD|release-notes>')).toBe('hi **@Grace** and **@U0CCC** in **#release-notes**')
    expect(mrkdwnToMarkdown('*bold* _it_ ~gone~')).toBe('**bold** *it* ~~gone~~')
    expect(mrkdwnToMarkdown('• one\n• two')).toBe('- one\n- two')
    expect(mrkdwnToMarkdown('&lt;main&gt; &amp; more')).toBe('<main> & more')
  })

  test('code spans keep their mrkdwn characters', () => {
    expect(mrkdwnToMarkdown('`*not bold*` *bold*')).toBe('`*not bold*` **bold**')
  })
})

describe('parseThreadText', () => {
  test('reads the parent and every reply with author, ts and text', () => {
    const thread = parseThreadText(THREAD_TEXT)
    expect(thread?.parent).toMatchObject({ author: 'Ada Lovelace', ts: '1791759796.763609' })
    expect(thread?.parent.text).toContain('_Widgets 0.82 published_')
    expect(thread?.replies.map(one => [one.author, one.ts])).toEqual([
      ['Grace Hopper', '1791761128.357239'],
      ['Ada Lovelace', '1791763200.000100'],
    ])
    expect(thread?.replies[1]?.text).toBe('Thanks, see <https://example.com/doc>.\nReactions: +1 (1)')
  })

  test('text that is not a thread transcript is not a thread', () => {
    expect(parseThreadText('hello')).toBeNull()
  })
})

describe('loadSlack through the Slack MCP server', () => {
  test('a thread page names the channel, who started it, the reply count, and lists replies as comments', async () => {
    const { io, calls } = world({ mcp: threadMcp() })
    const loaded = await loadSlack(io, ref(THREAD), NOW)
    const rec = record(loaded)
    expect(loaded.ok && loaded.tier).toBe('mcp')
    expect(rec.kind).toBe('slack-thread')
    expect(rec.title).toBe('Widgets 0.82 published')
    expect(rec.trail).toEqual(['acme', '#release-notes'])
    expect(rec.status).toBe('2 replies')
    expect(meta(rec, 'Channel')).toBe('#release-notes')
    expect(meta(rec, 'Started by')).toBe('Ada Lovelace')
    expect(meta(rec, 'Replies')).toBe('2')
    expect(rec.body).toContain('[widgets #147](https://github.com/acme/widgets/pull/147)')
    expect(rec.body).toContain('- **Contract change:**')
    expect(rec.comments?.total).toBe(2)
    expect(rec.comments?.shown.map(one => one.author)).toEqual(['Grace Hopper', 'Ada Lovelace'])
    expect(rec.comments?.shown[0]?.at).toBe(new Date(1791761128357).toISOString())
    expect(rec.comments?.shown[0]?.body).toBe('Text only: ~~old~~ new wording.')
    expect(rec.browserUrl).toBe(THREAD)
    const read = calls.find(one => one.tool === 'slack_read_thread')
    expect(read?.args).toMatchObject({ channel_id: 'C0123ABCD', message_ts: '1791759796.763609' })
  })

  test('a reply link loads its parent thread', async () => {
    const { io, calls } = world({ mcp: threadMcp() })
    await loadSlack(io, ref('https://acme.slack.com/archives/C0123ABCD/p1791761128357239?thread_ts=1791759796.763609'), NOW)
    expect(calls.find(one => one.tool === 'slack_read_thread')?.args.message_ts).toBe('1791759796.763609')
  })

  test('a thread with more pages says so in the reply count', async () => {
    const { io } = world({ mcp: threadMcp(THREAD_MORE) })
    const rec = record(await loadSlack(io, ref(THREAD), NOW))
    expect(rec.status).toBe('2+ replies')
  })

  test('the channel name is optional: a failed channel read still shows the thread', async () => {
    const { io } = world({ mcp: ({ tool }) => (tool === 'slack_read_thread' ? text(THREAD_RESULT) : text('execution_failed: not_in_channel', true)) })
    const rec = record(await loadSlack(io, ref(THREAD), NOW))
    expect(rec.trail).toEqual(['acme', 'C0123ABCD'])
    expect(rec.comments?.total).toBe(2)
  })

  test('a single message with no replies is a thread of one', async () => {
    const { io } = world({ mcp: threadMcp(LONE_MESSAGE) })
    const loaded = await loadSlack(io, ref(THREAD), NOW)
    const rec = record(loaded)
    expect(rec.status).toBe('no replies')
    expect(rec.body).toBe('hello')
  })

  test('Slack errors map to fixed failure kinds', async () => {
    const cases: [string, string][] = [
      ['execution_failed: thread_not_found', 'gone'],
      ['execution_failed: channel_not_found\n\nThe channel could not be found.', 'not-found-or-no-access'],
      ['execution_failed: ratelimited', 'rate-limited'],
    ]
    for (const [message, failure] of cases) {
      const { io } = world({ mcp: () => text(message, true) })
      expect(await loadSlack(io, ref(THREAD), NOW)).toEqual({ ok: false, failure })
    }
  })

  test('a server that answers with something other than a thread is a peek bug, not a crash', async () => {
    const { io } = world({ mcp: () => text('{"surprise": true}') })
    expect(await loadSlack(io, ref(THREAD), NOW)).toEqual({ ok: false, failure: 'query-bug' })
  })
})

describe('loadSlack without the MCP server', () => {
  test('with no Slack CLI the page asks to connect Slack, and nothing else runs', async () => {
    const { io, ran } = world({ mcp: 'absent', cli: null })
    expect(await loadSlack(io, ref(THREAD), NOW)).toEqual({ ok: false, failure: 'slack-unavailable' })
    expect(ran.filter(argv => argv[0] !== 'sh')).toEqual([])
  })

  test('an MCP server that refuses the token falls through to the CLI check', async () => {
    const { io } = world({ mcp: () => text('execution_failed: invalid_auth', true), cli: null })
    expect(await loadSlack(io, ref(THREAD), NOW)).toEqual({ ok: false, failure: 'slack-unavailable' })
  })

  test('the Slack CLI reads conversations.replies and conversations.info, never with a token flag', async () => {
    const cliRun = (argv: readonly string[]) => {
      if (argv[2] === 'conversations.replies') return exited(0, CLI_REPLIES)
      if (argv[2] === 'conversations.info') return exited(0, CLI_CHANNEL)
      return exited(1)
    }
    const { io, ran } = world({ mcp: 'absent', cli: '/home/.slack/bin/slack', cliRun })
    const loaded = await loadSlack(io, ref(THREAD), NOW)
    const rec = record(loaded)
    expect(loaded.ok && loaded.tier).toBe('cli')
    expect(rec.trail).toEqual(['acme', '#release-notes'])
    expect(meta(rec, 'Started by')).toBe('Ada Lovelace')
    expect(rec.body).toBe('Parent **text**')
    expect(rec.comments?.shown).toEqual([{ author: 'U0BBB2222', at: new Date(1791761128357).toISOString(), body: 'A reply' }])
    const replies = ran.find(argv => argv[2] === 'conversations.replies')
    expect(replies).toEqual(['/home/.slack/bin/slack', 'api', 'conversations.replies', 'channel=C0123ABCD', 'ts=1791759796.763609', 'limit=200'])
    expect(ran.flat().some(arg => arg.startsWith('--token'))).toBe(false)
  })

  test('a CLI answer with ok false maps like the MCP error', async () => {
    const cliRun = () => exited(0, JSON.stringify({ ok: false, error: 'thread_not_found' }))
    const { io } = world({ mcp: 'absent', cli: '/usr/local/bin/slack', cliRun })
    expect(await loadSlack(io, ref(THREAD), NOW)).toEqual({ ok: false, failure: 'gone' })
  })

  test('CLI output that is not JSON is a peek bug', async () => {
    const { io } = world({ mcp: 'absent', cli: '/usr/local/bin/slack', cliRun: () => exited(0, 'Usage: slack api …') })
    expect(await loadSlack(io, ref(THREAD), NOW)).toEqual({ ok: false, failure: 'query-bug' })
  })
})
