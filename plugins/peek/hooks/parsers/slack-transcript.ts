import { asObj, tryJson } from '../wire'
import type { RemoteFile } from '../../types'

export type SlackMessage = { author: string; ts: string; text: string; userId?: string; files: RemoteFile[]; avatarUrl?: string }

export type SlackThread = { parent: SlackMessage; replies: SlackMessage[]; hasMore: boolean }

const PARENT_HEAD = '=== THREAD PARENT MESSAGE ==='
const REPLIES_HEAD = /^=== THREAD REPLIES \(\d+ total\) ===$/m
const REPLY_HEAD = /^--- Reply \d+ of \d+ ---$/m

const FILES_LINE = /^Files: (.*)$/
const FILE_ENTRY = /(?:^|, )(.+?) \(ID: (F[A-Z0-9]+), ([^,()]+), ([^()]+?)\)/g

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

// The server wraps its transcript in {"messages": "...", "pagination_info": "..."}; a bare transcript is read as-is.
export function unwrapTranscript(text: string): { messages: string; more: boolean } {
  const parsed = asObj(tryJson(text))
  if (parsed && typeof parsed.messages === 'string') {
    return { messages: parsed.messages, more: /there are more messages/i.test(String(parsed.pagination_info ?? '')) }
  }
  return { messages: text, more: false }
}

export function channelName(text: string): string | undefined {
  return /^Channel: #(\S+)/m.exec(unwrapTranscript(text).messages)?.[1]
}

export function profilePicture(text: string, userId: string): string | undefined {
  const parsed = asObj(tryJson(text))
  const results = parsed && typeof parsed.results === 'string' ? parsed.results : text
  const mine = new RegExp(`^User ID: ${userId}\\s*$`, 'm')
  const block = results.replaceAll('\\/', '/').split(/^### Result /m).find(part => mine.test(part))
  return block ? /^Profile Pic: \[[^\]]*\]\((https:\/\/[^)\s]+)\)/m.exec(block)?.[1] : undefined
}
