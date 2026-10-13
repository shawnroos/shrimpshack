import type { Ports } from './ports'
import type { RemoteFailure } from '../types'
import { fromHttpStatus, ghFailure } from './sources/classify'
import { parseUrl, tryJson } from './wire'
import { sessionMemo } from './cache'
import { findKey, forgetKey } from './sources/linear-credentials'

const LINEAR_ENDPOINT = 'https://api.linear.app/graphql'
const TOOLS_PROBE = 'for t in gh curl; do command -v "$t" >/dev/null 2>&1 && echo "$t"; done'
const PAGE_SIZE = 50
const PAGE_CAP = 10
const MAX_RETRY_WAIT_MS = 5000
const DEFAULT_RETRY_WAIT_MS = 1000
const GH_TIMEOUT_MS = 20_000

export type SourceIo = Pick<Ports, 'sessionId' | 'run' | 'fetch' | 'linearKeyEnv' | 'home' | 'read' | 'sleep'>

export type Probe = {
  gh: RemoteFailure | null
  hasCurl: boolean
  hasKey: boolean
}

export type Failed = { ok: false; failure: RemoteFailure; detail?: string }

// Only a working gh is kept: a later `gh auth login` or install must be noticed without restarting the session.
const probes = sessionMemo<Probe>({ keep: found => found.gh === null })

export async function probe(io: SourceIo): Promise<Probe> {
  return probes.get(await io.sessionId(), () => runProbe(io))
}

async function runProbe(io: SourceIo): Promise<Probe> {
  const [key, tools] = await Promise.all([findKey(io), io.run(['sh', '-c', TOOLS_PROBE], { timeoutMs: 5000 }).catch(() => null)])
  const hasKey = key !== null
  if (!tools) return { gh: 'process-unavailable', hasCurl: false, hasKey }
  const found = new Set(tools.stdout.split('\n').map(line => line.trim()))
  const hasCurl = found.has('curl')
  if (!found.has('gh')) return { gh: 'cli-missing', hasCurl, hasKey }
  const status = await io.run(['gh', 'auth', 'status'], { timeoutMs: 10_000 }).catch(() => null)
  const gh: RemoteFailure | null = status === null ? 'offline' : status.exitCode === 0 ? null : 'cli-unauthed'
  return { gh, hasCurl, hasKey }
}

export async function hasCurl(io: SourceIo): Promise<boolean> {
  return (await probe(io)).hasCurl
}

export async function runGh(io: SourceIo, args: readonly string[]): Promise<{ ok: true; stdout: string } | Failed> {
  const found = await probe(io)
  if (found.gh) return { ok: false, failure: found.gh }
  const ran = await io.run(['gh', ...args], { timeoutMs: GH_TIMEOUT_MS }).catch(() => null)
  if (!ran) return { ok: false, failure: 'offline' }
  if (ran.exitCode !== 0) return { ok: false, failure: ghFailure(ran.stderr) }
  return { ok: true, stdout: ran.stdout }
}

function isPolicyRefusal(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error)
  return /polic|blocked|not allowed|\bdenied\b|refused by/i.test(message)
}

type Attempt = { ok: true; data: unknown } | Failed | { ok: false; failure: 'rate-limited'; waitMs: number }

function graphqlFailure(error: unknown, status: number): RemoteFailure | 'retry' {
  const extensions = (error as { extensions?: { code?: unknown; type?: unknown } } | null)?.extensions
  const code = typeof extensions?.code === 'string' ? extensions.code.toUpperCase() : ''
  const type = typeof extensions?.type === 'string' ? extensions.type.toUpperCase().replace(/ /g, '_') : ''
  const message = typeof (error as { message?: unknown } | null)?.message === 'string' ? (error as { message: string }).message : ''
  const tags = [code, type]
  if (tags.includes('RATELIMITED')) return 'retry'
  if (tags.includes('AUTHENTICATION_ERROR')) return 'key-refused'
  if (tags.includes('NOT_FOUND') || /entity not found/i.test(message)) return 'gone'
  if (tags.some(tag => ['FORBIDDEN', 'INPUT_ERROR', 'INVALID_INPUT'].includes(tag))) return 'not-found-or-no-access'
  if (tags.some(tag => tag.startsWith('GRAPHQL_') || tag === 'BAD_USER_INPUT')) return 'query-bug'
  return fromHttpStatus(status, 'graphql-error')
}

function retryWait(headers: Record<string, string>): number {
  const seconds = Number.parseFloat(headers['retry-after'] ?? '')
  if (!Number.isFinite(seconds) || seconds < 0) return DEFAULT_RETRY_WAIT_MS
  return Math.min(seconds * 1000, MAX_RETRY_WAIT_MS)
}

async function postOnce(io: SourceIo, key: string, body: string): Promise<Attempt> {
  let response
  try {
    response = await io.fetch(LINEAR_ENDPOINT, {
      method: 'POST',
      headers: { Authorization: key, 'Content-Type': 'application/json' },
      body,
    })
  } catch (error) {
    return { ok: false, failure: isPolicyRefusal(error) ? 'fetch-blocked' : 'offline' }
  }
  const { status, headers, text } = response
  if (status === 429) return { ok: false, failure: 'rate-limited', waitMs: retryWait(headers) }
  const parsed = tryJson(text)
  if (parsed === undefined) return { ok: false, failure: fromHttpStatus(status, 'graphql-text') }
  const errors = (parsed as { errors?: unknown } | null)?.errors
  if (Array.isArray(errors) && errors.length > 0) {
    const failure = graphqlFailure(errors[0], status)
    if (failure === 'retry') return { ok: false, failure: 'rate-limited', waitMs: retryWait(headers) }
    return { ok: false, failure }
  }
  if (status < 200 || status >= 300) return { ok: false, failure: fromHttpStatus(status, 'graphql-data') }
  const data = (parsed as { data?: unknown } | null)?.data
  if (data === null || typeof data !== 'object') return { ok: false, failure: 'query-bug' }
  return { ok: true, data }
}

async function postWithRetry(io: SourceIo, key: string, query: string, variables: Record<string, unknown>): Promise<{ ok: true; data: unknown } | Failed> {
  const body = JSON.stringify({ query, variables })
  const first = await postOnce(io, key, body)
  if (first.ok || !('waitMs' in first)) return first.ok ? first : { ok: false, failure: first.failure }
  await io.sleep(first.waitMs)
  const second = await postOnce(io, key, body)
  return second.ok ? second : { ok: false, failure: second.failure }
}

export async function linearQuery(
  io: SourceIo,
  query: string,
  variables: Record<string, unknown> = {},
): Promise<{ ok: true; data: unknown } | Failed> {
  const key = await findKey(io)
  const answered: { ok: true; data: unknown } | Failed = key ? await postWithRetry(io, key, query, variables) : { ok: false, failure: 'key-missing' }
  if (!answered.ok) await forgetKey(io, answered.failure)
  return answered
}

export type Connection = { nodes: unknown[]; pageInfo?: { hasNextPage?: boolean; endCursor?: string | null } }

export async function linearPaged(
  io: SourceIo,
  query: string,
  variables: Record<string, unknown>,
  pick: (data: unknown) => Connection | null | undefined,
): Promise<{ ok: true; nodes: unknown[]; isPartial: boolean } | Failed> {
  const key = await findKey(io)
  if (!key) {
    await forgetKey(io, 'key-missing')
    return { ok: false, failure: 'key-missing' }
  }
  const nodes: unknown[] = []
  let after: string | null = null
  for (let page = 0; page < PAGE_CAP; page++) {
    const answered = await postWithRetry(io, key, query, { ...variables, first: PAGE_SIZE, after })
    if (!answered.ok) {
      await forgetKey(io, answered.failure)
      return answered
    }
    const connection = pick(answered.data)
    if (!connection || !Array.isArray(connection.nodes)) return { ok: false, failure: 'query-bug' }
    nodes.push(...connection.nodes)
    if (connection.pageInfo?.hasNextPage !== true) return { ok: true, nodes, isPartial: false }
    const cursor = connection.pageInfo.endCursor
    if (!cursor) return { ok: true, nodes, isPartial: true }
    after = cursor
  }
  return { ok: true, nodes, isPartial: true }
}

const STATUS_TEXT: Record<number, string> = {
  400: 'Bad Request',
  401: 'Unauthorized',
  403: 'Forbidden',
  404: 'Not Found',
  410: 'Gone',
  429: 'Too Many Requests',
  500: 'Internal Server Error',
  502: 'Bad Gateway',
  503: 'Service Unavailable',
}

export function httpDetail(status: number, url: string): string {
  const host = parseUrl(url)?.host ?? ''
  return [`HTTP ${status}`, STATUS_TEXT[status], host && `from ${host}`].filter(Boolean).join(' ')
}

export async function httpText(io: SourceIo, url: string): Promise<{ ok: true; text: string; finalUrl?: string } | Failed> {
  const parsed = parseUrl(url)
  if (!parsed) return { ok: false, failure: 'query-bug' }
  if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') return { ok: false, failure: 'query-bug' }
  const target = parsed.href
  let response
  try {
    response = await io.fetch(target)
  } catch (error) {
    return { ok: false, failure: isPolicyRefusal(error) ? 'fetch-blocked' : 'offline' }
  }
  if (!response.ok) return { ok: false, failure: fromHttpStatus(response.status, 'page'), detail: httpDetail(response.status, target) }
  return { ok: true, text: response.text }
}
