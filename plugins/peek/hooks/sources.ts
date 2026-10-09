import type { HttpInit, HttpResponse, ProcessRunInit, ProcessRunResult } from 'claude-code'

import type { FailureKind, RemoteKind, Tier } from '../types'

const LINEAR_ENDPOINT = 'https://api.linear.app/graphql'
// Copied from herdr-board crates/board-daemon/src/linear/credential.rs: one Keychain item serves both tools.
const KEYCHAIN_SERVICE = 'work-linear'
const KEYCHAIN_ACCOUNT = 'linear-api-key'
const SECURITY_BIN = '/usr/bin/security'
const TOOLS_PROBE = 'for t in gh curl; do command -v "$t" >/dev/null 2>&1 && echo "$t"; done'
const PAGE_SIZE = 50
const PAGE_CAP = 10
const MAX_RETRY_WAIT_MS = 5000
const DEFAULT_RETRY_WAIT_MS = 1000
const GH_TIMEOUT_MS = 20_000
// A locked Keychain holds `security` on an unlock prompt nobody can answer, so the read is bounded.
const KEYCHAIN_TIMEOUT_MS = 3000

// `$` cannot cross an import (claude plugin validate), so register.tsx builds this port from `$`.
export type SourceIo = {
  sessionId: () => Promise<string>
  run: (argv: readonly string[], init?: ProcessRunInit) => Promise<ProcessRunResult>
  fetch: (url: string, init?: HttpInit) => Promise<HttpResponse>
  linearKeyEnv: () => Promise<string | undefined>
  home: () => Promise<string | undefined>
  read: (path: string) => Promise<string>
  sleep: (ms: number) => Promise<void>
}

export type Probe = {
  gh: FailureKind | null
  hasCurl: boolean
  hasKey: boolean
}

export type Failed = { ok: false; failure: FailureKind }

const probes = new Map<string, Promise<Probe>>()
const keys = new Map<string, Promise<string | null>>()

export function failureText(kind: FailureKind): { title: string; hint: string } {
  switch (kind) {
    case 'cli-missing':
      return { title: 'GitHub CLI is not installed', hint: 'Install it with `brew install gh`, then run `gh auth login`' }
    case 'cli-unauthed':
      return { title: 'GitHub CLI is not signed in', hint: 'Run `gh auth login` in a terminal' }
    case 'key-missing':
      return { title: 'No Linear API key found', hint: 'Set LINEAR_API_KEY or add it to ~/.secrets' }
    case 'key-refused':
      return { title: 'Linear refused the API key', hint: 'Create a new key in Linear settings and update LINEAR_API_KEY' }
    case 'not-found-or-no-access':
      return { title: 'Not found, or you have no access', hint: 'Check the link, or open it in the browser' }
    case 'rate-limited':
      return { title: 'Rate limited', hint: 'Wait a minute, then refresh' }
    case 'offline':
      return { title: 'Could not reach the service', hint: 'Check your connection, then refresh' }
    case 'query-bug':
      return { title: 'peek sent a request the service rejected', hint: 'Open it in the browser; this is a peek bug' }
    case 'fetch-blocked':
      return { title: 'Your network policy blocks this request', hint: 'Open it in the browser instead' }
    case 'process-unavailable':
      return { title: 'Command-line tools are unavailable here', hint: 'This surface cannot run command-line tools' }
    case 'live-unavailable':
      return { title: 'Live view needs the Swift compiler', hint: 'Install the command-line tools with `xcode-select --install`, then press v' }
    case 'live-crashed':
      return { title: 'The live view stopped', hint: 'Press v to start it again' }
    case 'live-stalled':
      return { title: 'The live page never drew', hint: 'Press v to try again, or o to open it in the browser' }
  }
}

export async function probe(io: SourceIo): Promise<Probe> {
  const session = await io.sessionId()
  const known = probes.get(session)
  if (known) return known
  const pending = runProbe(io)
  probes.set(session, pending)
  // Only a working gh is kept: a later `gh auth login` or install must be noticed without restarting the session.
  const drop = () => {
    if (probes.get(session) === pending) probes.delete(session)
  }
  void pending.then(found => found.gh !== null && drop(), drop)
  return pending
}

async function runProbe(io: SourceIo): Promise<Probe> {
  const [key, tools] = await Promise.all([findKey(io), io.run(['sh', '-c', TOOLS_PROBE], { timeoutMs: 5000 }).catch(() => null)])
  const hasKey = key !== null
  if (!tools) return { gh: 'process-unavailable', hasCurl: false, hasKey }
  const found = new Set(tools.stdout.split('\n').map(line => line.trim()))
  const hasCurl = found.has('curl')
  if (!found.has('gh')) return { gh: 'cli-missing', hasCurl, hasKey }
  const status = await io.run(['gh', 'auth', 'status'], { timeoutMs: 10_000 }).catch(() => null)
  const gh: FailureKind | null = status === null ? 'offline' : status.exitCode === 0 ? null : 'cli-unauthed'
  return { gh, hasCurl, hasKey }
}

export async function hasCurl(io: SourceIo): Promise<boolean> {
  return (await probe(io)).hasCurl
}

export async function tierFor(io: SourceIo, kind: RemoteKind): Promise<{ ok: true; tier: Tier } | Failed> {
  const found = await probe(io)
  if (kind === 'gh-repo' || kind === 'gh-issue' || kind === 'gh-pr') {
    return found.gh ? { ok: false, failure: found.gh } : { ok: true, tier: 'cli' }
  }
  if (kind === 'linear-issue' || kind === 'linear-project') {
    return found.hasKey ? { ok: true, tier: 'api' } : { ok: false, failure: 'key-missing' }
  }
  return { ok: true, tier: found.hasCurl ? 'cli' : 'api' }
}

function ghFailure(stderr: string): FailureKind {
  if (/rate limit|secondary rate|HTTP 429/i.test(stderr)) return 'rate-limited'
  if (/gh auth login|not logged in|authentication|HTTP 401|bad credentials/i.test(stderr)) return 'cli-unauthed'
  if (/Could not resolve to a|HTTP 404|Not Found|HTTP 403|no access|permission/i.test(stderr)) return 'not-found-or-no-access'
  if (/dial tcp|could not connect|connection refused|timeout|timed out|no such host|network is unreachable|error connecting/i.test(stderr)) {
    return 'offline'
  }
  return 'query-bug'
}

export async function runGh(io: SourceIo, args: readonly string[]): Promise<{ ok: true; stdout: string } | Failed> {
  const found = await probe(io)
  if (found.gh) return { ok: false, failure: found.gh }
  const ran = await io.run(['gh', ...args], { timeoutMs: GH_TIMEOUT_MS }).catch(() => null)
  if (!ran) return { ok: false, failure: 'offline' }
  if (ran.exitCode !== 0) return { ok: false, failure: ghFailure(ran.stderr) }
  return { ok: true, stdout: ran.stdout }
}

function unquote(raw: string): string {
  const text = raw.trim()
  const first = text[0]
  if (text.length >= 2 && (first === '"' || first === "'") && text.endsWith(first)) return text.slice(1, -1)
  return text
}

async function findKey(io: SourceIo): Promise<string | null> {
  const session = await io.sessionId()
  const known = keys.get(session)
  if (known) return known
  const pending = lookupKey(io)
  keys.set(session, pending)
  return pending
}

async function forgetKey(io: SourceIo, failure: FailureKind): Promise<void> {
  if (failure === 'key-refused' || failure === 'key-missing') keys.delete(await io.sessionId())
}

async function lookupKey(io: SourceIo): Promise<string | null> {
  const keychain = await io
    .run([SECURITY_BIN, 'find-generic-password', '-a', KEYCHAIN_ACCOUNT, '-s', KEYCHAIN_SERVICE, '-w'], { timeoutMs: KEYCHAIN_TIMEOUT_MS })
    .catch(() => null)
  const fromKeychain = keychain && keychain.exitCode === 0 ? keychain.stdout.trim() : ''
  if (fromKeychain) return fromKeychain
  const fromEnv = ((await io.linearKeyEnv().catch(() => undefined)) ?? '').trim()
  if (fromEnv) return fromEnv
  const home = (await io.home().catch(() => undefined)) ?? ''
  if (!home) return null
  const secrets = await io.read(`${home}/.secrets`).catch(() => '')
  const line = /^[ \t]*(?:export[ \t]+)?LINEAR_API_KEY[ \t]*=[ \t]*(.*?)[ \t]*$/m.exec(secrets)
  const fromFile = line ? unquote(line[1] ?? '') : ''
  return fromFile || null
}

function isPolicyRefusal(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error)
  return /polic|blocked|not allowed|\bdenied\b|refused by/i.test(message)
}

type Attempt = { ok: true; data: unknown } | Failed | { ok: false; failure: 'rate-limited'; waitMs: number }

function graphqlFailure(error: unknown, status: number): FailureKind | 'retry' {
  const extensions = (error as { extensions?: { code?: unknown; type?: unknown } } | null)?.extensions
  const code = typeof extensions?.code === 'string' ? extensions.code.toUpperCase() : ''
  const type = typeof extensions?.type === 'string' ? extensions.type.toUpperCase().replace(/ /g, '_') : ''
  const message = typeof (error as { message?: unknown } | null)?.message === 'string' ? (error as { message: string }).message : ''
  const tags = [code, type]
  if (tags.includes('RATELIMITED')) return 'retry'
  if (tags.includes('AUTHENTICATION_ERROR')) return 'key-refused'
  if (tags.some(tag => ['FORBIDDEN', 'NOT_FOUND', 'INPUT_ERROR', 'INVALID_INPUT'].includes(tag)) || /entity not found/i.test(message)) {
    return 'not-found-or-no-access'
  }
  if (tags.some(tag => tag.startsWith('GRAPHQL_') || tag === 'BAD_USER_INPUT') || status === 400) return 'query-bug'
  if (status === 401) return 'key-refused'
  if (status === 403) return 'not-found-or-no-access'
  if (status >= 500) return 'offline'
  return 'query-bug'
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
  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch {
    if (status === 401) return { ok: false, failure: 'key-refused' }
    if (status === 403 || status === 404) return { ok: false, failure: 'not-found-or-no-access' }
    if (status === 400) return { ok: false, failure: 'query-bug' }
    return { ok: false, failure: status >= 200 && status < 300 ? 'query-bug' : 'offline' }
  }
  const errors = (parsed as { errors?: unknown } | null)?.errors
  if (Array.isArray(errors) && errors.length > 0) {
    const failure = graphqlFailure(errors[0], status)
    if (failure === 'retry') return { ok: false, failure: 'rate-limited', waitMs: retryWait(headers) }
    return { ok: false, failure }
  }
  if (status === 401) return { ok: false, failure: 'key-refused' }
  if (status < 200 || status >= 300) return { ok: false, failure: status === 403 ? 'not-found-or-no-access' : 'offline' }
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

export function httpFailure(status: number): FailureKind {
  if (status === 429) return 'rate-limited'
  if (status === 401 || status === 403 || status === 404 || status === 410) return 'not-found-or-no-access'
  if (status === 400) return 'query-bug'
  return 'offline'
}

export async function httpText(io: SourceIo, url: string): Promise<{ ok: true; text: string; finalUrl?: string } | Failed> {
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    return { ok: false, failure: 'query-bug' }
  }
  if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') return { ok: false, failure: 'query-bug' }
  const target = parsed.href
  let response
  try {
    response = await io.fetch(target)
  } catch (error) {
    return { ok: false, failure: isPolicyRefusal(error) ? 'fetch-blocked' : 'offline' }
  }
  if (!response.ok) return { ok: false, failure: httpFailure(response.status) }
  return { ok: true, text: response.text }
}
