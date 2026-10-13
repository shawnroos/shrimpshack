import type { CaptureIo } from '../capture'
import type { Ref, SlackThreadRef } from '../refs'
import { sessionMemo } from '../cache'
import { IMAGE_MIME_EXT, SCRATCH, downloadImage } from '../net'
import { slackFailure } from './classify'
import { ok } from './result'
import type { SourceIo } from '../source-io'
import { asObj, asStr, decodeEntities, parseUrl, tryJson } from '../wire'
import { channelName, parseThreadText, profilePicture, unwrapTranscript } from '../parsers/slack-transcript'
import type { SlackMessage, SlackThread } from '../parsers/slack-transcript'
import type { Json } from '../wire'
import type { Loaded, RemoteComment, RemoteFailure, RemoteFile, RemoteRecord } from '../../types'

type DownloadImage = (url: string, ext: string) => Promise<string | undefined>

// The source passes its whole port and downloads through net.ts; a narrower port may bring its own downloadImage, or none.
export type SlackIo = Pick<SourceIo, 'sessionId' | 'run'> & Pick<CaptureIo, 'mcpCall'> & ({ downloadImage?: DownloadImage } | SourceIo)

function imageDownloader(io: SlackIo): DownloadImage | undefined {
  if ('downloadImage' in io && io.downloadImage) return io.downloadImage
  return 'fetch' in io && 'linearKeyEnv' in io ? (url, ext) => downloadImage(io, url, ext) : undefined
}

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

const USER_ID = /^[UWB][A-Z0-9]+$/
// Each read is a file download and, the first time, a permission prompt; past these the rest show as file rows.
const MAX_FILE_READS = 6
const MAX_SPEAKERS = 12
// slack_read_file's own limit.
const MAX_FILE_BYTES = 10_000_000
// The pane draws an avatar 4 columns by 2 rows; Slack's 72 px variant is about 12 KB where the original was 1.4 MB.
const AVATAR_PX = 72

const preferredServer = new Map<string, string>()
// Only a found CLI is kept, so an install later in the session is noticed.
const cliPaths = sessionMemo<string | null>({ keep: found => found !== null })
// Refresh reloads a thread every minute; files and faces are fetched, and refused, once per session.
const filePictures = sessionMemo<string | undefined>()
const avatarFiles = sessionMemo<string | undefined>()

// The transport is absent or refused its token: the next transport may still serve the thread.
type Skip = { skip: true }
const SKIP: Skip = { skip: true }


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

function isoOf(ts: string): string {
  return new Date(Math.round(Number(ts) * 1000)).toISOString()
}

function replyCount(count: number, hasMore: boolean): string {
  if (hasMore) return `${count}+ replies`
  if (count === 0) return 'no replies'
  return count === 1 ? '1 reply' : `${count} replies`
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
  const ext = IMAGE_MIME_EXT[String(image?.mimeType ?? file.type)]
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
  return profilePicture(blockText(answer.content), one.userId)
}

async function avatarFile(io: SlackIo, server: string | undefined, one: SlackMessage): Promise<string | undefined> {
  const found = one.avatarUrl ?? (server ? await searchedAvatar(io, server, one) : undefined)
  const download = imageDownloader(io)
  if (!found || !download) return undefined
  const url = smallAvatar(found)
  const ext = /\.(png|jpe?g|gif|webp)$/i.exec(new URL(url).pathname)?.[1]?.toLowerCase() ?? 'png'
  return download(url, ext)
}

async function withPictures(io: SlackIo, record: RemoteRecord, messages: readonly SlackMessage[], server: string | undefined): Promise<RemoteRecord> {
  const session = await io.sessionId()
  const images = server
    ? messages.flatMap(one => one.files).filter(file => IMAGE_MIME_EXT[file.type] && bytesOf(file.size) <= MAX_FILE_BYTES).slice(0, MAX_FILE_READS)
    : []
  const speakers = [...new Map(messages.filter(one => one.userId).map(one => [one.userId ?? '', one])).values()].slice(0, MAX_SPEAKERS)
  const [files, faces] = await Promise.all([
    Promise.all(images.map(async file => [file.id, await filePictures.get(`${session} ${file.id}`, () => filePicture(io, server ?? '', file).catch(() => undefined))] as const)),
    Promise.all(speakers.map(async one => [one.userId ?? '', await avatarFiles.get(`${session} ${one.userId}`, () => avatarFile(io, server, one).catch(() => undefined))] as const)),
  ])
  const media = Object.fromEntries(files.flatMap(([id, file]) => (file ? [[`slack-file:${id}`, { file }]] : [])))
  const avatars = Object.fromEntries(faces.flatMap(([id, file]) => (file ? [[id, file]] : [])))
  return {
    ...record,
    ...(Object.keys(media).length ? { media } : {}),
    ...(Object.keys(avatars).length ? { avatars } : {}),
  }
}

async function loadViaMcp(io: SlackIo, ref: SlackThreadRef, channel: string, ts: string, now: number): Promise<Loaded | Skip> {
  const [thread, info] = await Promise.all([
    mcpRead(io, 'slack_read_thread', { channel_id: channel, message_ts: ts, limit: REPLY_LIMIT }),
    mcpRead(io, 'slack_read_channel', { channel_id: channel, limit: 1 }),
  ])
  if (!thread) return SKIP
  if (thread.isError) {
    const failure = slackFailure(thread.text)
    return failure ? { ok: false, failure } : SKIP
  }
  const { messages, more } = unwrapTranscript(thread.text)
  const parsed = parseThreadText(messages)
  if (!parsed) return { ok: false, failure: 'query-bug' }
  const name = info && !info.isError ? channelName(info.text) : undefined
  const base = threadRecord(ref, { ...parsed, hasMore: more }, name)
  const record = await withPictures(io, base, [parsed.parent, ...parsed.replies], thread.server)
  return ok(record, 'mcp', now)
}

async function findCli(io: SlackIo): Promise<string | null> {
  return cliPaths.get(await io.sessionId(), () =>
    io
      .run(['sh', '-c', CLI_PROBE], { timeoutMs: 5000 })
      .then(ran => (ran.exitCode === 0 ? ran.stdout.trim().split('\n')[0]?.trim() || null : null))
      .catch(() => null),
  )
}

async function cliApi(io: SlackIo, bin: string, args: readonly string[]): Promise<{ ok: true; body: Json } | { ok: false; failure: RemoteFailure } | Skip> {
  const ran = await io.run([bin, 'api', ...args], { timeoutMs: CLI_TIMEOUT_MS }).catch(() => null)
  if (!ran) return { ok: false, failure: 'offline' }
  const body = asObj(tryJson(ran.stdout))
  if (!body) return ran.exitCode === 0 ? { ok: false, failure: 'query-bug' } : SKIP
  if (body.ok !== true) {
    const failure = slackFailure(asStr(body.error) ?? '')
    return failure ? { ok: false, failure } : SKIP
  }
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

async function loadViaCli(io: SlackIo, ref: SlackThreadRef, channel: string, ts: string, now: number): Promise<Loaded | Skip> {
  const bin = await findCli(io)
  if (!bin) return SKIP
  const [replies, info] = await Promise.all([
    cliApi(io, bin, ['conversations.replies', `channel=${channel}`, `ts=${ts}`, `limit=${REPLY_LIMIT}`]),
    cliApi(io, bin, ['conversations.info', `channel=${channel}`]),
  ])
  if ('skip' in replies) return SKIP
  if (!replies.ok) return { ok: false, failure: replies.failure }
  const raw = Array.isArray(replies.body.messages) ? replies.body.messages : []
  const messages = raw
    .map(one => asObj(one))
    .filter((one): one is Json => one !== null && typeof one.ts === 'string')
    .map(one => cliMessage(one))
  const [parent, ...rest] = messages
  if (!parent) return { ok: false, failure: 'query-bug' }
  const name = 'body' in info ? asStr(asObj(info.body.channel)?.name) : undefined
  const thread = { parent, replies: rest, hasMore: replies.body.has_more === true }
  const record = await withPictures(io, threadRecord(ref, thread, name), messages, undefined)
  return ok(record, 'cli', now)
}

export async function loadSlack(io: SlackIo, ref: Ref, now: number): Promise<Loaded> {
  if (ref.kind !== 'slack-thread' || !ref.channel || !ref.ts) return { ok: false, failure: 'query-bug' }
  const { channel, ts } = ref
  const viaMcp = await loadViaMcp(io, ref, channel, ts, now)
  if (!('skip' in viaMcp)) return viaMcp
  const viaCli = await loadViaCli(io, ref, channel, ts, now)
  if (!('skip' in viaCli)) return viaCli
  return { ok: false, failure: 'slack-unavailable' }
}
