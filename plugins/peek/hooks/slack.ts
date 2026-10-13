import type { CaptureIo } from './capture'
import type { Ref, SlackThreadRef } from './refs'
import { describeAge } from './format'
import type { SourceIo } from './sources'
import { asObj, asStr, decodeEntities, parseUrl, tryJson } from './wire'
import type { Json } from './wire'
import type { FailureKind, Loaded, RemoteComment, RemoteFile, RemoteRecord } from '../types'

export type SlackIo = Pick<SourceIo, 'sessionId' | 'run'> &
  Pick<CaptureIo, 'mcpCall'> & { downloadImage?: (url: string, ext: string) => Promise<string | undefined> }

export type SlackMessage = { author: string; ts: string; text: string; userId?: string; files: RemoteFile[]; avatarUrl?: string }

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
const SLACK_ENTITIES = ['lt', 'gt', 'amp'] as const

const PARENT_HEAD = '=== THREAD PARENT MESSAGE ==='
const REPLIES_HEAD = /^=== THREAD REPLIES \(\d+ total\) ===$/m
const REPLY_HEAD = /^--- Reply \d+ of \d+ ---$/m

const FILES_LINE = /^Files: (.*)$/
const FILE_ENTRY = /(?:^|, )(.+?) \(ID: (F[A-Z0-9]+), ([^,()]+), ([^()]+?)\)/g
const USER_ID = /^[UWB][A-Z0-9]+$/
const SCRATCH = '/tmp/claude-peek'
// Each read is a file download and, the first time, a permission prompt; past these the rest show as file rows.
const MAX_FILE_READS = 6
const MAX_SPEAKERS = 12
// slack_read_file's own limit.
const MAX_FILE_BYTES = 10_000_000
// The pane draws an avatar 4 columns by 2 rows; Slack's 72 px variant is about 12 KB where the original was 1.4 MB.
const AVATAR_PX = 72
const IMAGE_EXT: Record<string, string> = { 'image/png': 'png', 'image/jpeg': 'jpg', 'image/gif': 'gif', 'image/webp': 'webp' }

const preferredServer = new Map<string, string>()
const cliPaths = new Map<string, Promise<string | null>>()
// Refresh reloads a thread every minute; files and faces are fetched, and refused, once per session.
const filePictures = new Map<string, Promise<string | undefined>>()
const avatarFiles = new Map<string, Promise<string | undefined>>()

type Unavailable = { ok: false; failure: 'unavailable' }

function isUnavailable(result: Loaded | Unavailable): result is Unavailable {
  return !result.ok && result.failure === 'unavailable'
}


function inline(text: string): string {
  const converted = text
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
  return decodeEntities(converted, SLACK_ENTITIES)
}

export function mrkdwnToMarkdown(text: string): string {
  return text
    .split(/(```[\s\S]*?```|`[^`\n]*`)/)
    .map((part, i) => (i % 2 === 1 ? part : inline(part)))
    .join('')
}

function plainLine(text: string): string {
  const first = text.split('\n').find(line => line.trim())?.trim() ?? ''
  const stripped = first
    .replace(/<[@#!][^|>]*\|([^>]+)>/g, '$1')
    .replace(/<(?:https?|mailto):[^|>]+\|([^>]+)>/g, '$1')
    .replace(/<([^>]+)>/g, '$1')
    .replace(/^([*_~]+)(.+?)\1$/, '$2')
  const plain = decodeEntities(stripped, SLACK_ENTITIES).trim()
  return plain.length > TITLE_CAP ? `${plain.slice(0, TITLE_CAP - 1)}…` : plain
}

function parseFiles(line: string): RemoteFile[] {
  return [...line.matchAll(FILE_ENTRY)].map(found => ({ id: found[2] ?? '', name: (found[1] ?? '').trim(), type: (found[3] ?? '').trim(), size: (found[4] ?? '').trim() }))
}

function parseMessage(block: string): SlackMessage | null {
  const lines = block.replace(/^\n+/, '').split('\n')
  let author = ''
  let ts = ''
  let userId: string | undefined
  while (lines.length) {
    const head = /^(From|Time|Message TS): ?(.*)$/.exec(lines[0] ?? '')
    if (!head) break
    lines.shift()
    if (head[1] === 'From') {
      const from = head[2] ?? ''
      userId = /\(([UWB][A-Z0-9]+)\)\s*$/.exec(from)?.[1]
      // The email in "Name <email> (U123)" is dropped on purpose: the page never shows it.
      author = from.replace(/\s*<[^>]*>.*$/, '').replace(/\s*\([UWB][A-Z0-9]+\)\s*$/, '').trim()
    }
    if (head[1] === 'Message TS') ts = (head[2] ?? '').trim()
  }
  if (!/^\d+\.\d+$/.test(ts)) return null
  const files = lines.flatMap(line => parseFiles(FILES_LINE.exec(line)?.[1] ?? ''))
  const text = lines.filter(line => !FILES_LINE.test(line)).join('\n').trim()
  return { author: author || 'Unknown', ts, text, ...(userId ? { userId } : {}), files }
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

export function initials(name: string): string {
  const words = name.split(/\s+/).map(word => word.replace(/[^\p{L}\p{N}]/gu, '')).filter(Boolean)
  const first = words[0]?.[0] ?? ''
  const last = words.length > 1 ? (words.at(-1)?.[0] ?? '') : ''
  return `${first}${last}`.toUpperCase() || '?'
}

export function whenLabel(iso: string, now: number, timeZone?: string): string {
  const at = Date.parse(iso)
  if (Number.isNaN(at)) return iso
  const day = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' })
  if (day.format(at) === day.format(now)) return describeAge(at, now)
  const isThisYear = day.format(at).slice(0, 4) === day.format(now).slice(0, 4)
  const date = new Intl.DateTimeFormat('en-US', { timeZone, month: 'short', day: 'numeric', ...(isThisYear ? {} : { year: 'numeric' }) }).format(at)
  const time = new Intl.DateTimeFormat('en-US', { timeZone, hour: 'numeric', minute: '2-digit' }).format(at)
  // Newer ICU puts a narrow no-break space before AM/PM.
  return `${date}, ${time}`.replace(/\s/g, ' ')
}

function permalink(ref: SlackThreadRef, ts: string, parentTs: string): string {
  const base = `https://${ref.workspace}.slack.com/archives/${ref.channel}/p${ts.replace('.', '')}`
  return ts === parentTs ? base : `${base}?thread_ts=${parentTs}&cid=${ref.channel}`
}

function messageOf(ref: SlackThreadRef, one: SlackMessage, parentTs: string): RemoteComment {
  return {
    author: one.author,
    ...(one.userId ? { authorId: one.userId } : {}),
    at: isoOf(one.ts),
    body: mrkdwnToMarkdown(one.text),
    href: permalink(ref, one.ts, parentTs),
    ...(one.files.length ? { files: one.files } : {}),
  }
}

export function threadRecord(ref: SlackThreadRef, thread: SlackThread, channelName: string | undefined): RemoteRecord {
  const channel = channelName ? `#${channelName}` : ref.channel
  const count = thread.replies.length
  const last = thread.replies.at(-1)
  const meta: RemoteRecord['meta'] = [
    { label: 'Channel', value: channel },
    { label: 'Started by', value: thread.parent.author },
    { label: 'Started', value: isoOf(thread.parent.ts).slice(0, 10) },
    { label: 'Replies', value: `${count}${thread.hasMore ? '+' : ''}` },
  ]
  if (last) meta.push({ label: 'Last reply', value: isoOf(last.ts).slice(0, 10) })
  const shown = thread.replies.map(one => messageOf(ref, one, thread.parent.ts))
  return {
    address: ref.address,
    kind: 'slack-thread',
    title: plainLine(thread.parent.text) || `Thread in ${channel}`,
    trail: [ref.workspace, channel].filter(Boolean),
    status: replyCount(count, thread.hasMore),
    meta,
    body: mrkdwnToMarkdown(thread.parent.text) || undefined,
    comments: { shown, total: count },
    lead: messageOf(ref, thread.parent, thread.parent.ts),
    browserUrl: ref.address,
  }
}

function blockText(content: unknown[]): string {
  return content
    .map(block => asObj(block))
    .filter((block): block is Json => block?.type === 'text' && typeof block.text === 'string')
    .map(block => block.text as string)
    .join('\n')
}

// The server wraps its transcript in {"messages": "...", "pagination_info": "..."}; a bare transcript is read as-is.
function unwrap(text: string): { messages: string; more: boolean } {
  const parsed = asObj(tryJson(text))
  if (parsed && typeof parsed.messages === 'string') {
    return { messages: parsed.messages, more: /there are more messages/i.test(String(parsed.pagination_info ?? '')) }
  }
  return { messages: text, more: false }
}

async function mcpRead(io: SlackIo, tool: string, args: Record<string, unknown>): Promise<{ text: string; isError: boolean; server: string } | null> {
  const session = await io.sessionId()
  const known = preferredServer.get(session)
  const order = known ? [known, ...SLACK_SERVERS.filter(one => one !== known)] : SLACK_SERVERS
  for (const server of order) {
    // A rejection means the engine has no such server connected; the next spelling may be the one.
    const answer = await io.mcpCall(server, tool, args).catch(() => null)
    if (!answer) continue
    preferredServer.set(session, server)
    return { text: blockText(answer.content), isError: answer.isError, server }
  }
  return null
}

function bytesOf(size: string): number {
  const found = /^([\d.]+)\s*(B|KB|MB|GB)$/i.exec(size.trim())
  if (!found) return Number.POSITIVE_INFINITY
  return Number(found[1]) * 1024 ** ['B', 'KB', 'MB', 'GB'].indexOf((found[2] ?? 'B').toUpperCase())
}

function sizeLabel(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 ** 2) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / 1024 ** 2).toFixed(1)} MB`
}

// A refused or failed call is a rejection or an error result; asking the other server spellings would ask again.
async function filePicture(io: SlackIo, server: string, file: RemoteFile): Promise<string | undefined> {
  const answer = await io.mcpCall(server, 'slack_read_file', { file_id: file.id }).catch(() => null)
  if (!answer || answer.isError) return undefined
  const image = answer.content.map(block => asObj(block)).find(block => block?.type === 'image' && typeof block.data === 'string')
  const ext = IMAGE_EXT[String(image?.mimeType ?? file.type)]
  if (!image || !ext) return undefined
  const path = `${SCRATCH}/slack-${file.id}.${ext}`
  const made = await io.run(['mkdir', '-p', SCRATCH], { timeoutMs: 5000 }).catch(() => null)
  if (!made || made.exitCode !== 0) return undefined
  const wrote = await io.run(['base64', '-d', '-o', path], { stdin: image.data as string, timeoutMs: 10_000 }).catch(() => null)
  return wrote?.exitCode === 0 ? path : undefined
}

function smallAvatar(raw: string): string {
  const url = parseUrl(raw)
  if (!url) return raw
  if (url.hostname === 'avatars.slack-edge.com') return raw.replace(/_(?:original|\d+)\.(png|jpe?g|gif)$/i, `_${AVATAR_PX}.$1`)
  if (url.hostname.endsWith('gravatar.com')) {
    url.searchParams.set('s', String(AVATAR_PX))
    return url.href
  }
  return raw
}

// slack_read_user_profile returns no picture in either format; the detailed user search is the read that does.
async function searchedAvatar(io: SlackIo, server: string, one: SlackMessage): Promise<string | undefined> {
  const keywords = one.author.split(/\s+/).map(word => word.replace(/[^\p{L}\p{N}'-]/gu, '')).filter(Boolean).slice(0, 3)
  if (!keywords.length || !one.userId || !USER_ID.test(one.userId)) return undefined
  const args = { keywords, natural_language_query: one.author, limit: 5, response_format: 'detailed' }
  const answer = await io.mcpCall(server, 'slack_search_users', args).catch(() => null)
  if (!answer || answer.isError) return undefined
  const raw = blockText(answer.content)
  const parsed = asObj(tryJson(raw))
  const results = parsed && typeof parsed.results === 'string' ? parsed.results : raw
  const mine = new RegExp(`^User ID: ${one.userId}\\s*$`, 'm')
  const block = results.replaceAll('\\/', '/').split(/^### Result /m).find(part => mine.test(part))
  return block ? /^Profile Pic: \[[^\]]*\]\((https:\/\/[^)\s]+)\)/m.exec(block)?.[1] : undefined
}

async function avatarFile(io: SlackIo, server: string | undefined, one: SlackMessage): Promise<string | undefined> {
  const found = one.avatarUrl ?? (server ? await searchedAvatar(io, server, one) : undefined)
  if (!found || !io.downloadImage) return undefined
  const url = smallAvatar(found)
  const ext = /\.(png|jpe?g|gif|webp)$/i.exec(new URL(url).pathname)?.[1]?.toLowerCase() ?? 'png'
  return io.downloadImage(url, ext)
}

function once(cache: Map<string, Promise<string | undefined>>, key: string, make: () => Promise<string | undefined>): Promise<string | undefined> {
  const known = cache.get(key)
  if (known) return known
  const pending = make().catch(() => undefined)
  cache.set(key, pending)
  return pending
}

async function withPictures(io: SlackIo, record: RemoteRecord, messages: readonly SlackMessage[], server: string | undefined): Promise<RemoteRecord> {
  const session = await io.sessionId()
  const images = server
    ? messages.flatMap(one => one.files).filter(file => IMAGE_EXT[file.type] && bytesOf(file.size) <= MAX_FILE_BYTES).slice(0, MAX_FILE_READS)
    : []
  const speakers = [...new Map(messages.filter(one => one.userId).map(one => [one.userId ?? '', one])).values()].slice(0, MAX_SPEAKERS)
  const [files, faces] = await Promise.all([
    Promise.all(images.map(async file => [file.id, await once(filePictures, `${session} ${file.id}`, () => filePicture(io, server ?? '', file))] as const)),
    Promise.all(speakers.map(async one => [one.userId ?? '', await once(avatarFiles, `${session} ${one.userId}`, () => avatarFile(io, server, one))] as const)),
  ])
  const media = Object.fromEntries(files.flatMap(([id, file]) => (file ? [[`slack-file:${id}`, { file }]] : [])))
  const avatars = Object.fromEntries(faces.flatMap(([id, file]) => (file ? [[id, file]] : [])))
  return {
    ...record,
    ...(Object.keys(media).length ? { media } : {}),
    ...(Object.keys(avatars).length ? { avatars } : {}),
  }
}

async function loadViaMcp(io: SlackIo, ref: SlackThreadRef, channel: string, ts: string, now: number): Promise<Loaded | Unavailable> {
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
  const base = threadRecord(ref, { ...parsed, hasMore: more }, name)
  const record = await withPictures(io, base, [parsed.parent, ...parsed.replies], thread.server)
  return { ok: true, record, tier: 'mcp', fetchedAt: now }
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

async function cliApi(io: SlackIo, bin: string, args: readonly string[]): Promise<{ ok: true; body: Json } | { ok: false; failure: FailureKind | 'unavailable' }> {
  const ran = await io.run([bin, 'api', ...args], { timeoutMs: CLI_TIMEOUT_MS }).catch(() => null)
  if (!ran) return { ok: false, failure: 'offline' }
  const body = asObj(tryJson(ran.stdout))
  if (!body) return { ok: false, failure: ran.exitCode === 0 ? 'query-bug' : 'unavailable' }
  if (body.ok !== true) return { ok: false, failure: slackFailure(asStr(body.error) ?? '') }
  return { ok: true, body }
}

function cliAuthor(message: Json): string {
  const profile = asObj(message.user_profile)
  return asStr(profile?.real_name) ?? asStr(profile?.display_name) ?? asStr(asObj(message.bot_profile)?.name) ?? asStr(message.username) ?? asStr(message.user) ?? 'Unknown'
}

function cliFiles(message: Json): RemoteFile[] {
  const raw = Array.isArray(message.files) ? message.files : []
  return raw
    .map(one => asObj(one))
    .filter((one): one is Json => one !== null && typeof one.id === 'string' && /^F[A-Z0-9]+$/.test(one.id))
    .map(one => ({ id: one.id as string, name: asStr(one.name) ?? (one.id as string), type: asStr(one.mimetype) ?? 'file', size: typeof one.size === 'number' ? sizeLabel(one.size) : '' }))
}

function cliMessage(one: Json): SlackMessage {
  const user = asStr(one.user)
  const avatarUrl = asStr(asObj(one.user_profile)?.image_72)
  return {
    author: cliAuthor(one),
    ts: one.ts as string,
    text: typeof one.text === 'string' ? one.text : '',
    ...(user && USER_ID.test(user) ? { userId: user } : {}),
    files: cliFiles(one),
    ...(avatarUrl ? { avatarUrl } : {}),
  }
}

async function loadViaCli(io: SlackIo, ref: SlackThreadRef, channel: string, ts: string, now: number): Promise<Loaded | Unavailable> {
  const bin = await findCli(io)
  if (!bin) return { ok: false, failure: 'unavailable' }
  const [replies, info] = await Promise.all([
    cliApi(io, bin, ['conversations.replies', `channel=${channel}`, `ts=${ts}`, `limit=${REPLY_LIMIT}`]),
    cliApi(io, bin, ['conversations.info', `channel=${channel}`]),
  ])
  if (!replies.ok) return { ok: false, failure: replies.failure }
  const raw = Array.isArray(replies.body.messages) ? replies.body.messages : []
  const messages = raw
    .map(one => asObj(one))
    .filter((one): one is Json => one !== null && typeof one.ts === 'string')
    .map(one => cliMessage(one))
  const [parent, ...rest] = messages
  if (!parent) return { ok: false, failure: 'query-bug' }
  const name = info.ok ? asStr(asObj(info.body.channel)?.name) : undefined
  const thread = { parent, replies: rest, hasMore: replies.body.has_more === true }
  const record = await withPictures(io, threadRecord(ref, thread, name), messages, undefined)
  return { ok: true, record, tier: 'cli', fetchedAt: now }
}

export async function loadSlack(io: SlackIo, ref: Ref, now: number): Promise<Loaded> {
  if (ref.kind !== 'slack-thread' || !ref.channel || !ref.ts) return { ok: false, failure: 'query-bug' }
  const { channel, ts } = ref
  const viaMcp = await loadViaMcp(io, ref, channel, ts, now)
  if (!isUnavailable(viaMcp)) return viaMcp
  const viaCli = await loadViaCli(io, ref, channel, ts, now)
  if (!isUnavailable(viaCli)) return viaCli
  return { ok: false, failure: 'slack-unavailable' }
}

export function fromCapture(): Loaded | null {
  return null
}
