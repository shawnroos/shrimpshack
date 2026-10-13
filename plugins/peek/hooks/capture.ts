import { itemKey, keyOf, parseRef } from './refs'
import type { Ref, RefKind } from './refs'
import { captureReaderOf } from './sources/adapter'
import { ghRead, ghSource } from './parsers/gh-argv'
import type { Ports } from './ports'

export type CaptureIo = Pick<Ports, 'mcpCall' | 'now'>

export type CaptureSource = 'mcp' | 'bash' | 'webfetch'

export type Captured = {
  address: string
  kind: RefKind
  source: CaptureSource
  server?: string
  tool: string
  args: Record<string, unknown>
  result: string
  at: number
}

const MAX_ENTRIES = 200
const MAX_TEXT = 2_000_000
const RESERVED = new Set(['tool', 'tool_use_id', 'agentId', 'consent'])
const READ_PREFIX = /^(?:get|list|search)_/
const READ_EXACT = new Set(['issue_read', 'pull_request_read'])
const SLACK_READ = /^slack_(?:read|search)_/
const REMOTE_URL = /https:\/\/(?:www\.)?(?:github\.com|linear\.app|[a-z0-9-]+\.slack\.com)\/[^\s"'<>)\]}\\,]+/g

const store = new Map<string, Captured>()
let textSize = 0

function splitMcp(tool: string): { server: string; name: string } | null {
  if (!tool.startsWith('mcp__')) return null
  const rest = tool.slice(5)
  const cut = rest.lastIndexOf('__')
  if (cut <= 0) return null
  return { server: rest.slice(0, cut), name: rest.slice(cut + 2) }
}

export function isReadCall(tool: string, input: Record<string, unknown>): boolean {
  if (tool === 'WebFetch') return typeof input.url === 'string'
  if (tool === 'Bash') return ghRead(input.command) !== null
  const mcp = splitMcp(tool)
  if (!mcp || !captureReaderOf(mcp.server)) return false
  return READ_PREFIX.test(mcp.name) || READ_EXACT.has(mcp.name) || SLACK_READ.test(mcp.name)
}

function isSingleItem(tool: string, input: Record<string, unknown>): boolean {
  if (tool === 'WebFetch') return true
  if (tool === 'Bash') {
    const gh = ghRead(input.command)
    return gh !== null && (gh.sub === 'api' || gh.verb === 'view')
  }
  const name = splitMcp(tool)?.name ?? ''
  // Only method `get` returns the item itself; get_diff, get_files and the rest would overwrite it with text no page can draw.
  if (READ_EXACT.has(name)) return input.method === undefined || input.method === 'get'
  return name.startsWith('get_')
}

function textOf(answer: unknown): string | null {
  if (!answer || typeof answer !== 'object') return null
  const reply = answer as { result?: unknown; text?: unknown }
  const result = reply.result as { stdout?: unknown; content?: unknown } | undefined
  if (result && typeof result === 'object' && typeof result.stdout === 'string') return result.stdout
  if (typeof reply.text === 'string') return reply.text
  const blocks = Array.isArray(result) ? result : Array.isArray(result?.content) ? result.content : null
  if (blocks) {
    return blocks
      .filter((block): block is { type: 'text'; text: string } => block?.type === 'text' && typeof block.text === 'string')
      .map(block => block.text)
      .join('\n')
  }
  if (typeof reply.result === 'string') return reply.result
  return reply.result === undefined ? null : JSON.stringify(reply.result)
}

// The Slack server writes its JSON with every slash escaped (`https:\/\/`), which no URL pattern matches.
function remoteRefs(text: string): Ref[] {
  const seen = new Map<string, Ref>()
  for (const url of new Set(text.replace(/\\\//g, '/').match(REMOTE_URL))) {
    const ref = parseRef(url)
    if (ref && ref.kind !== 'web' && !seen.has(ref.address)) seen.set(ref.address, ref)
  }
  return [...seen.values()]
}

function captureSourceOf(tool: string, args: Record<string, unknown>, text: string): { ref: Ref; source: CaptureSource; server?: string; name: string } | null {
  if (tool === 'WebFetch') {
    const ref = typeof args.url === 'string' ? parseRef(args.url) : null
    return ref ? { ref, source: 'webfetch', name: tool } : null
  }
  if (tool === 'Bash') {
    const gh = ghRead(args.command)
    const ref = gh ? ghSource(gh) : null
    return ref ? { ref, source: 'bash', name: tool } : null
  }
  const mcp = splitMcp(tool)
  const reader = mcp ? captureReaderOf(mcp.server) : undefined
  const ref = mcp && reader ? reader.refOf(mcp.name, args, text) : null
  return mcp && ref ? { ref, source: 'mcp', server: mcp.server, name: mcp.name } : null
}

function forget(key: string) {
  const entry = store.get(key)
  if (!entry) return
  store.delete(key)
  textSize -= entry.result.length
}

function keep(entry: Captured) {
  const key = itemKey(entry.address)
  forget(key)
  store.set(key, entry)
  textSize += entry.result.length
  for (const oldest of store.keys()) {
    if (store.size <= MAX_ENTRIES && textSize <= MAX_TEXT) break
    forget(oldest)
  }
}

export function record(input: Record<string, unknown>, answer: unknown, at: number): { addresses: string[]; learned: boolean } {
  const none = { addresses: [], learned: false }
  const tool = typeof input.tool === 'string' ? input.tool : ''
  const reply = answer as { isError?: unknown; deny?: unknown } | null
  if (!reply || reply.isError || reply.deny !== undefined) return none
  if (!isReadCall(tool, input)) return none
  const text = textOf(answer)
  if (text === null) return none
  const args = Object.fromEntries(Object.entries(input).filter(([key]) => !RESERVED.has(key)))
  const found = remoteRefs(text)
  const server = splitMcp(tool)?.server
  const learned = server ? (captureReaderOf(server)?.learn?.(found) ?? false) : false
  const addresses = new Set<string>()
  if (isSingleItem(tool, input) && text.length <= MAX_TEXT) {
    const source = captureSourceOf(tool, args, text)
    if (source) {
      keep({ address: source.ref.address, kind: source.ref.kind, source: source.source, server: source.server, tool: source.name, args, result: text, at })
      addresses.add(source.ref.address)
    }
  }
  for (const ref of found) addresses.add(ref.address)
  return { addresses: [...addresses], learned }
}

export function lookup(address: string): Captured | null {
  const ref = parseRef(address)
  const entry = store.get(ref ? keyOf(ref) : itemKey(address))
  return entry ? { ...entry, args: { ...entry.args } } : null
}

export async function replay(io: CaptureIo, address: string): Promise<Captured | null> {
  const entry = lookup(address)
  if (!entry || entry.source !== 'mcp' || !entry.server) return null
  if (!isReadCall(`mcp__${entry.server}__${entry.tool}`, entry.args)) return null
  const answer = await io.mcpCall(entry.server, entry.tool, entry.args)
  if (answer.isError) return null
  const text = textOf({ result: answer.content })
  if (text === null) return null
  const at = await io.now()
  const fresh = { ...entry, result: text, at }
  keep(fresh)
  return lookup(address)
}
