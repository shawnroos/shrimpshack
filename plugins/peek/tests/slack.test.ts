import { describe, expect, test } from 'claude-code/testing'
import type { ProcessRunResult } from 'claude-code'

import { loadSlack, mrkdwnToMarkdown } from '../hooks/sources/slack'
import { initials, whenLabel } from '../hooks/format'
import { parseThreadText } from '../hooks/parsers/slack-transcript'
import { speakerColor } from '../hooks/theme'
import type { SlackIo } from '../hooks/sources/slack'
import { ADA_PIC, CHANNEL_RESULT, CLI_CHANNEL, CLI_REPLIES, FILES_RESULT, FILES_TEXT, LONE_MESSAGE, THREAD_MORE, THREAD_RESULT, fileResult, usersResult } from './fixtures/slack/mcp'
import { exited, meta, record, ref } from './fixtures/results'

const NOW = 1_792_000_000_000
const THREAD = 'https://acme.slack.com/archives/C0123ABCD/p1791759796763609'
const REPLY_LINK = 'https://acme.slack.com/archives/C0123ABCD/p1791761128357239?thread_ts=1791759796.763609&cid=C0123ABCD'
let sessions = 0

type Call = { server: string; tool: string; args: Record<string, unknown> }
type McpReply = (call: Call) => { content: unknown[]; isError: boolean }

const text = (body: string, isError = false) => ({ content: [{ type: 'text', text: body }], isError })

function world(options: { mcp?: McpReply | 'absent'; cli?: string | null; cliRun?: (argv: readonly string[]) => ProcessRunResult; session?: string } = {}) {
  const session = options.session ?? `slack-${++sessions}`
  const calls: Call[] = []
  const ran: string[][] = []
  const stdins: string[] = []
  const downloads: string[] = []
  const io: SlackIo = {
    downloadImage: async url => {
      downloads.push(url)
      return `/tmp/claude-peek/web-${downloads.length}.png`
    },
    sessionId: async () => session,
    mcpCall: async (server, tool, args) => {
      calls.push({ server, tool, args })
      const mcp = options.mcp ?? 'absent'
      if (mcp === 'absent') throw new Error(`MCP server "${server}" is not connected`)
      return mcp({ server, tool, args })
    },
    run: async (argv, init) => {
      ran.push([...argv])
      if (argv[0] === 'base64') stdins.push(String(init?.stdin ?? ''))
      if (argv[0] === 'base64' || argv[0] === 'mkdir') return exited(0)
      if (argv[0] === 'sh') return options.cli ? exited(0, `${options.cli}\n`) : exited(0, '')
      return options.cliRun ? options.cliRun(argv) : exited(1)
    },
  }
  return { io, calls, ran, stdins, downloads }
}

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
    expect(rec.comments?.shown).toEqual([{ author: 'U0BBB2222', authorId: 'U0BBB2222', at: new Date(1791761128357).toISOString(), body: 'A reply', href: REPLY_LINK }])
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

function filesMcp(options: { file?: (id: string) => { content: unknown[]; isError: boolean } | 'reject'; users?: string } = {}): McpReply {
  return ({ tool, args }) => {
    if (tool === 'slack_read_thread') return text(FILES_RESULT)
    if (tool === 'slack_read_channel') return text(CHANNEL_RESULT)
    if (tool === 'slack_read_file') {
      const answer = options.file?.(String(args.file_id)) ?? fileResult(String(args.file_id), 'iVBORw0KGgo=', args.file_id === 'F0EEE5555' ? 'image/jpeg' : 'image/png')
      if (answer === 'reject') throw new Error('permission denied')
      return answer
    }
    if (tool === 'slack_search_users') return text(options.users ?? usersResult([]))
    return text('', true)
  }
}

describe('Slack messages: speakers, links and files', () => {
  test('each message keeps its speaker id and its own permalink; the Files: line becomes files, not text', async () => {
    const thread = parseThreadText(FILES_TEXT)
    expect(thread?.parent.userId).toBe('U0AAA1111')
    expect(thread?.parent.text).toBe('Cutting too early, see the shot.')
    expect(thread?.parent.files).toEqual([{ id: 'F0C7A02R0AY', name: 'Screenshot 2026-10-06 at 1.22.47 PM.png', type: 'image/png', size: '221.4 KB' }])
    expect(thread?.replies[0]?.files).toEqual([
      { id: 'F0DDD4444', name: 'spec, v2.pdf', type: 'application/pdf', size: '1.2 MB' },
      { id: 'F0EEE5555', name: 'crop.jpg', type: 'image/jpeg', size: '80.0 KB' },
    ])
    const { io } = world({ mcp: threadMcp() })
    const rec = record(await loadSlack(io, ref(REPLY_LINK), NOW))
    expect(rec.lead).toMatchObject({ author: 'Ada Lovelace', authorId: 'U0AAA1111', href: THREAD, at: new Date(1791759796764).toISOString() })
    expect(rec.lead?.body).toContain('Widgets 0.82 published')
    expect(rec.lead?.files).toEqual([{ id: 'F0AAA', name: 'notes.mp4', type: 'video/quicktime', size: '2.0 MB' }])
    expect(rec.comments?.shown[0]).toMatchObject({ authorId: 'U0BBB2222', href: REPLY_LINK })
  })

  test('an image file is read once through the server that read the thread and decoded to a scratch picture; other files are not read', async () => {
    const { io, calls, stdins } = world({ mcp: filesMcp() })
    const rec = record(await loadSlack(io, ref(THREAD), NOW))
    const reads = calls.filter(one => one.tool === 'slack_read_file')
    expect(reads.map(one => [one.server, one.args.file_id])).toEqual([
      ['plugin_slack_slack', 'F0C7A02R0AY'],
      ['plugin_slack_slack', 'F0EEE5555'],
    ])
    expect(stdins).toEqual(['iVBORw0KGgo=', 'iVBORw0KGgo='])
    expect(rec.media?.['slack-file:F0C7A02R0AY']?.file).toMatch(/^\/tmp\/claude-peek\/slack-F0C7A02R0AY\.png$/)
    expect(rec.media?.['slack-file:F0EEE5555']?.file).toMatch(/slack-F0EEE5555\.jpg$/)
    expect(rec.media?.['slack-file:F0DDD4444']).toBeUndefined()
    await loadSlack(io, ref(THREAD), NOW + 60_000)
    expect(calls.filter(one => one.tool === 'slack_read_file').length).toBe(2)
  })

  test('a file read that is refused or fails leaves the page whole, asks only one server, and is not retried on refresh', async () => {
    const { io, calls } = world({ mcp: filesMcp({ file: id => (id === 'F0C7A02R0AY' ? 'reject' : text('execution_failed: file_not_found', true)) }) })
    const loaded = await loadSlack(io, ref(THREAD), NOW)
    const rec = record(loaded)
    expect(rec.media).toBeUndefined()
    expect(rec.lead?.files?.[0]?.id).toBe('F0C7A02R0AY')
    await loadSlack(io, ref(THREAD), NOW + 60_000)
    expect(calls.filter(one => one.tool === 'slack_read_file').map(one => one.server)).toEqual(['plugin_slack_slack', 'plugin_slack_slack'])
  })

  test('a speaker avatar comes from the search result whose user id matches, at the small 72 px size', async () => {
    const users = usersResult([
      { name: 'Ada Lovelace', id: 'U0OTHER99', pic: 'https://avatars.slack-edge.com/other_original.png' },
      { name: 'Ada Lovelace', id: 'U0AAA1111', pic: ADA_PIC },
    ])
    const { io, calls, downloads } = world({ mcp: filesMcp({ users }) })
    const rec = record(await loadSlack(io, ref(THREAD), NOW))
    expect(downloads).toContain('https://avatars.slack-edge.com/2022-11-23/4416337781877_a24dc51906aa11d635a2_72.png')
    expect(downloads.some(url => url.includes('other'))).toBe(false)
    expect(rec.avatars?.U0AAA1111).toMatch(/^\/tmp\/claude-peek\/web-\d+\.png$/)
    expect(rec.avatars?.U0BBB2222).toBeUndefined()
    const search = calls.find(one => one.tool === 'slack_search_users' && JSON.stringify(one.args).includes('Ada'))
    expect(search?.args).toMatchObject({ response_format: 'detailed' })
  })

  test('one avatar lookup per speaker, however many messages they wrote and however often the page refreshes', async () => {
    const { io, calls } = world({ mcp: threadMcp() })
    await loadSlack(io, ref(THREAD), NOW)
    await loadSlack(io, ref(THREAD), NOW + 60_000)
    const searches = calls.filter(one => one.tool === 'slack_search_users')
    expect(searches.length).toBe(2)
  })

  test('a search with no picture, or a refused search, leaves the speaker without an avatar', async () => {
    const { io } = world({ mcp: filesMcp({ users: usersResult([{ name: 'Ada Lovelace', id: 'U0AAA1111' }]) }) })
    expect(record(await loadSlack(io, ref(THREAD), NOW)).avatars).toBeUndefined()
  })

  test('the CLI path takes the avatar from user_profile.image_72', async () => {
    const replies = JSON.stringify({
      ok: true,
      messages: [{ ts: '1791759796.763609', user: 'U0AAA1111', user_profile: { real_name: 'Ada Lovelace', image_72: 'https://avatars.slack-edge.com/a_72.png' }, text: 'Parent', files: [{ id: 'F0X', name: 'a.pdf', mimetype: 'application/pdf', size: 2048 }] }],
    })
    const cliRun = (argv: readonly string[]) => (argv[2] === 'conversations.replies' ? exited(0, replies) : exited(0, CLI_CHANNEL))
    const { io, downloads } = world({ mcp: 'absent', cli: '/home/.slack/bin/slack', cliRun })
    const rec = record(await loadSlack(io, ref(THREAD), NOW))
    expect(downloads).toEqual(['https://avatars.slack-edge.com/a_72.png'])
    expect(rec.avatars?.U0AAA1111).toBeDefined()
    expect(rec.lead?.files).toEqual([{ id: 'F0X', name: 'a.pdf', type: 'application/pdf', size: '2.0 KB' }])
  })
})

describe('Speaker and time labels', () => {
  test('a message from today reads relative; an older one reads as a date and time; another year adds the year', () => {
    const noon = Date.parse('2026-10-12T12:00:00Z')
    expect(whenLabel('2026-10-12T11:55:00Z', noon, 'UTC')).toBe('5m ago')
    expect(whenLabel('2026-10-06T13:22:47Z', noon, 'UTC')).toBe('Oct 6, 1:22 PM')
    expect(whenLabel('2025-10-06T13:22:47Z', noon, 'UTC')).toBe('Oct 6, 2025, 1:22 PM')
    expect(whenLabel('2026-10-11T23:59:00Z', noon, 'UTC')).toBe('Oct 11, 11:59 PM')
  })

  test('initials come from the first and last name', () => {
    expect(initials('Ada Lovelace')).toBe('AL')
    expect(initials('Grace Brewster Hopper')).toBe('GH')
    expect(initials('cher')).toBe('C')
    expect(initials('')).toBe('?')
  })

  test('a speaker keeps one colour, and different speakers spread over the palette', () => {
    expect(speakerColor('U0AAA1111')).toBe(speakerColor('U0AAA1111'))
    const ids = ['U0AAA1111', 'U0BBB2222', 'U0CCC3333', 'U0DDD4444', 'U0EEE5555', 'U0FFF6666']
    expect(new Set(ids.map(id => speakerColor(id))).size >= 3).toBe(true)
  })
})
