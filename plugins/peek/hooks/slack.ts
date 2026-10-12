import type { CaptureIo } from './capture'
import type { Ref } from './refs'
import type { SourceIo } from './sources'
import type { FailureKind, Loaded, RemoteComment, RemoteRecord } from '../types'

export type SlackIo = Pick<SourceIo, 'sessionId' | 'run'> & Pick<CaptureIo, 'mcpCall'>

export type SlackMessage = { author: string; ts: string; text: string }

export type SlackThread = { parent: SlackMessage; replies: SlackMessage[]; hasMore: boolean }

// `$.mcp.call` accepts the tool-name spelling of a server: the Slack plugin's tools are mcp__plugin_slack_slack__*,
// the claude.ai connector's mcp__claude_ai_Slack__*. `plugin:slack:slack` is the /mcp spelling, in case only that one resolves.
const SLACK_SERVERS = ['plugin_slack_slack', 'claude_ai_Slack', 'plugin:slack:slack']
const REPLY_LIMIT = 200
const CLI_TIMEOUT_MS = 20_000
// The public Slack CLI's `_fingerprint` answer, from the Slack plugin's slack-cli skill; another `slack` binary is not it.
const CLI_FINGERPRINT = 'd41d8cd98f00b204e9800998ecf8427e'
const CLI_PROBE = `if [ -x "$HOME/.slack/bin/slack" ]; then echo "$HOME/.slack/bin/slack"; elif command -v slack >/dev/null 2>&1 && [ "$(slack _fingerprint 2>/dev/null)" = ${CLI_FINGERPRINT} ]; then command -v slack; fi`
const TITLE_CAP = 100

const PARENT_HEAD = '=== THREAD PARENT MESSAGE ==='
const REPLIES_HEAD = /^=== THREAD REPLIES \(\d+ total\) ===$/m
const REPLY_HEAD = /^--- Reply \d+ of \d+ ---$/m

const preferredServer = new Map<string, string>()
const cliPaths = new Map<string, Promise<string | null>>()

type Obj = Record<string, unknown>
type Unavailable = { ok: false; failure: 'unavailable' }

function isUnavailable(result: Loaded | Unavailable): result is Unavailable {
  return !result.ok && result.failure === 'unavailable'
}

function obj(value: unknown): Obj | null {
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as Obj) : null
}

function str(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() ? value.trim() : undefined
}

function inline(text: string): string {
  return text
    .replace(/<@([UW][A-Z0-9]+)\|([^>]+)>/g, '**@$2**')
    .replace(/<@([UW][A-Z0-9]+)>/g, '**@$1**')
    .replace(/<#(C[A-Z0-9]+)\|([^>]+)>/g, '**#$2**')
    .replace(/<#(C[A-Z0-9]+)>/g, '**#$1**')
    .replace(/<!subteam\^[A-Z0-9]+\|([^>]+)>/g, '**$1**')
    .replace(/<!(here|channel|everyone)(?:\|[^>]*)?>/g, '**@$1**')
    .replace(/<((?:https?|mailto):[^|>\s]+)\|([^>]+)>/g, '[$2]($1)')
    .replace(/<((?:https?|mailto):[^|>\s]+)>/g, '<$1>')
    .replace(/(^|[\s(])\*(?=\S)([^*\n]+?)\*(?=$|[\s).,!?:;])/gm, '$1**$2**')
    .replace(/(^|[\s(])_(?=\S)([^_\n]+?)_(?=$|[\s).,!?:;])/gm, '$1*$2*')
    .replace(/(^|[\s(])~(?=\S)([^~\n]+?)~(?=$|[\s).,!?:;])/gm, '$1~~$2~~')
    .replace(/^([ \t]*)[•◦▪]\s?/gm, '$1- ')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&')
}

export function mrkdwnToMarkdown(text: string): string {
  return text
    .split(/(```[\s\S]*?```|`[^`\n]*`)/)
    .map((part, i) => (i % 2 === 1 ? part : inline(part)))
    .join('')
}

function plainLine(text: string): string {
  const first = text.split('\n').find(line => line.trim())?.trim() ?? ''
  const plain = first
    .replace(/<[@#!][^|>]*\|([^>]+)>/g, '$1')
    .replace(/<(?:https?|mailto):[^|>]+\|([^>]+)>/g, '$1')
    .replace(/<([^>]+)>/g, '$1')
    .replace(/^([*_~]+)(.+?)\1$/, '$2')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&amp;/g, '&')
    .trim()
  return plain.length > TITLE_CAP ? `${plain.slice(0, TITLE_CAP - 1)}…` : plain
}

function parseMessage(block: string): SlackMessage | null {
  const lines = block.replace(/^\n+/, '').split('\n')
  let author = ''
  let ts = ''
  while (lines.length) {
    const head = /^(From|Time|Message TS): ?(.*)$/.exec(lines[0] ?? '')
    if (!head) break
    lines.shift()
    // The email in "Name <email> (U123)" is dropped on purpose: the page never shows it.
    if (head[1] === 'From') author = (head[2] ?? '').replace(/\s*<[^>]*>.*$/, '').replace(/\s*\([UWB][A-Z0-9]+\)\s*$/, '').trim()
    if (head[1] === 'Message TS') ts = (head[2] ?? '').trim()
  }
  if (!/^\d+\.\d+$/.test(ts)) return null
  return { author: author || 'Unknown', ts, text: lines.join('\n').trim() }
}

export function parseThreadText(text: string): Omit<SlackThread, 'hasMore'> | null {
  const start = text.indexOf(PARENT_HEAD)
  if (start < 0) return null
  const [parentPart = '', repliesPart = ''] = text.slice(start + PARENT_HEAD.length).split(REPLIES_HEAD)
  const parent = parseMessage(parentPart.replace(/\n*No thread messs?ages\s*$/, ''))
  if (!parent) return null
  const replies = repliesPart
    .split(REPLY_HEAD)
    .slice(1)
    .map(block => parseMessage(block))
    .filter((one): one is SlackMessage => one !== null)
  return { parent, replies }
}

function slackFailure(message: string): FailureKind | 'unavailable' {
  const code = /execution_failed:\s*([a-z_]+)/.exec(message)?.[1] ?? /^\s*([a-z_]+)\s*$/.exec(message)?.[1] ?? ''
  if (code === 'thread_not_found' || code === 'message_not_found') return 'gone'
  if (['channel_not_found', 'not_in_channel', 'access_denied', 'missing_scope', 'no_permission'].includes(code)) return 'not-found-or-no-access'
  if (code === 'ratelimited' || code === 'rate_limited') return 'rate-limited'
  if (['invalid_auth', 'not_authed', 'token_revoked', 'token_expired', 'account_inactive'].includes(code)) return 'unavailable'
  return 'query-bug'
}

function isoOf(ts: string): string {
  return new Date(Math.round(Number(ts) * 1000)).toISOString()
}

function replyCount(count: number, hasMore: boolean): string {
  if (hasMore) return `${count}+ replies`
  if (count === 0) return 'no replies'
  return count === 1 ? '1 reply' : `${count} replies`
}

export function threadRecord(ref: Ref, thread: SlackThread, channelName: string | undefined): RemoteRecord {
  const channel = channelName ? `#${channelName}` : (ref.channel ?? '')
  const count = thread.replies.length
  const last = thread.replies.at(-1)
  const meta: RemoteRecord['meta'] = [
    { label: 'Channel', value: channel },
    { label: 'Started by', value: thread.parent.author },
    { label: 'Started', value: isoOf(thread.parent.ts).slice(0, 10) },
    { label: 'Replies', value: `${count}${thread.hasMore ? '+' : ''}` },
  ]
  if (last) meta.push({ label: 'Last reply', value: isoOf(last.ts).slice(0, 10) })
  const shown: RemoteComment[] = thread.replies.map(one => ({ author: one.author, at: isoOf(one.ts), body: mrkdwnToMarkdown(one.text) }))
  return {
    address: ref.address,
    kind: 'slack-thread',
    title: plainLine(thread.parent.text) || `Thread in ${channel}`,
    trail: [ref.workspace ?? 'slack', channel].filter(Boolean),
    status: replyCount(count, thread.hasMore),
    meta,
    body: mrkdwnToMarkdown(thread.parent.text) || undefined,
    comments: { shown, total: count },
    browserUrl: ref.address,
  }
}

function blockText(content: unknown[]): string {
  return content
    .map(block => obj(block))
    .filter((block): block is Obj => block?.type === 'text' && typeof block.text === 'string')
    .map(block => block.text as string)
    .join('\n')
}

// The server wraps its transcript in {"messages": "...", "pagination_info": "..."}; a bare transcript is read as-is.
function unwrap(text: string): { messages: string; more: boolean } {
  try {
    const parsed = obj(JSON.parse(text))
    if (parsed && typeof parsed.messages === 'string') {
      return { messages: parsed.messages, more: /there are more messages/i.test(String(parsed.pagination_info ?? '')) }
    }
  } catch {}
  return { messages: text, more: false }
}

async function mcpRead(io: SlackIo, tool: string, args: Record<string, unknown>): Promise<{ text: string; isError: boolean } | null> {
  const session = await io.sessionId()
  const known = preferredServer.get(session)
  const order = known ? [known, ...SLACK_SERVERS.filter(one => one !== known)] : SLACK_SERVERS
  for (const server of order) {
    // A rejection means the engine has no such server connected; the next spelling may be the one.
    const answer = await io.mcpCall(server, tool, args).catch(() => null)
    if (!answer) continue
    preferredServer.set(session, server)
    return { text: blockText(answer.content), isError: answer.isError }
  }
  return null
}

async function loadViaMcp(io: SlackIo, ref: Ref, channel: string, ts: string, now: number): Promise<Loaded | Unavailable> {
  const [thread, info] = await Promise.all([
    mcpRead(io, 'slack_read_thread', { channel_id: channel, message_ts: ts, limit: REPLY_LIMIT }),
    mcpRead(io, 'slack_read_channel', { channel_id: channel, limit: 1 }),
  ])
  if (!thread) return { ok: false, failure: 'unavailable' }
  if (thread.isError) return { ok: false, failure: slackFailure(thread.text) }
  const { messages, more } = unwrap(thread.text)
  const parsed = parseThreadText(messages)
  if (!parsed) return { ok: false, failure: 'query-bug' }
  const name = info && !info.isError ? /^Channel: #(\S+)/m.exec(unwrap(info.text).messages)?.[1] : undefined
  return { ok: true, record: threadRecord(ref, { ...parsed, hasMore: more }, name), tier: 'mcp', fetchedAt: now }
}

async function findCli(io: SlackIo): Promise<string | null> {
  const session = await io.sessionId()
  const known = cliPaths.get(session)
  if (known) return known
  const pending = io
    .run(['sh', '-c', CLI_PROBE], { timeoutMs: 5000 })
    .then(ran => (ran.exitCode === 0 ? ran.stdout.trim().split('\n')[0]?.trim() || null : null))
    .catch(() => null)
  cliPaths.set(session, pending)
  // Only a found CLI is kept, so an install later in the session is noticed.
  void pending.then(found => {
    if (!found && cliPaths.get(session) === pending) cliPaths.delete(session)
  })
  return pending
}

async function cliApi(io: SlackIo, bin: string, args: readonly string[]): Promise<{ ok: true; body: Obj } | { ok: false; failure: FailureKind | 'unavailable' }> {
  const ran = await io.run([bin, 'api', ...args], { timeoutMs: CLI_TIMEOUT_MS }).catch(() => null)
  if (!ran) return { ok: false, failure: 'offline' }
  let body: Obj | null = null
  try {
    body = obj(JSON.parse(ran.stdout))
  } catch {}
  if (!body) return { ok: false, failure: ran.exitCode === 0 ? 'query-bug' : 'unavailable' }
  if (body.ok !== true) return { ok: false, failure: slackFailure(str(body.error) ?? '') }
  return { ok: true, body }
}

function cliAuthor(message: Obj): string {
  const profile = obj(message.user_profile)
  return str(profile?.real_name) ?? str(profile?.display_name) ?? str(obj(message.bot_profile)?.name) ?? str(message.username) ?? str(message.user) ?? 'Unknown'
}

async function loadViaCli(io: SlackIo, ref: Ref, channel: string, ts: string, now: number): Promise<Loaded | Unavailable> {
  const bin = await findCli(io)
  if (!bin) return { ok: false, failure: 'unavailable' }
  const [replies, info] = await Promise.all([
    cliApi(io, bin, ['conversations.replies', `channel=${channel}`, `ts=${ts}`, `limit=${REPLY_LIMIT}`]),
    cliApi(io, bin, ['conversations.info', `channel=${channel}`]),
  ])
  if (!replies.ok) return { ok: false, failure: replies.failure }
  const raw = Array.isArray(replies.body.messages) ? replies.body.messages : []
  const messages = raw
    .map(one => obj(one))
    .filter((one): one is Obj => one !== null && typeof one.ts === 'string')
    .map(one => ({ author: cliAuthor(one), ts: one.ts as string, text: typeof one.text === 'string' ? one.text : '' }))
  const [parent, ...rest] = messages
  if (!parent) return { ok: false, failure: 'query-bug' }
  const name = info.ok ? str(obj(info.body.channel)?.name) : undefined
  const thread = { parent, replies: rest, hasMore: replies.body.has_more === true }
  return { ok: true, record: threadRecord(ref, thread, name), tier: 'cli', fetchedAt: now }
}

export async function loadSlack(io: SlackIo, ref: Ref, now: number): Promise<Loaded> {
  const { channel, ts } = ref
  if (ref.kind !== 'slack-thread' || !channel || !ts) return { ok: false, failure: 'query-bug' }
  const viaMcp = await loadViaMcp(io, ref, channel, ts, now)
  if (!isUnavailable(viaMcp)) return viaMcp
  const viaCli = await loadViaCli(io, ref, channel, ts, now)
  if (!isUnavailable(viaCli)) return viaCli
  return { ok: false, failure: 'slack-unavailable' }
}

export function fromCapture(): Loaded | null {
  return null
}
