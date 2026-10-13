import type { RemoteFailure } from '../../types'
import type { Failed, SourceIo } from '../source-io'
import { tryJson } from '../wire'
import { fromHttpStatus, isPolicyRefusal } from './classify'
import { findKey, forgetKey } from './linear-credentials'

const LINEAR_ENDPOINT = 'https://api.linear.app/graphql'
const PAGE_SIZE = 50
const PAGE_CAP = 10
const MAX_RETRY_WAIT_MS = 5000
const DEFAULT_RETRY_WAIT_MS = 1000

type Answered = { ok: true; data: unknown } | Failed
type Attempt = Answered | { ok: false; failure: 'rate-limited'; waitMs: number }

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

const plain = (attempt: Attempt): Answered => (attempt.ok ? attempt : { ok: false, failure: attempt.failure })

async function postWithRetry(io: SourceIo, key: string, query: string, variables: Record<string, unknown>): Promise<Answered> {
  const body = JSON.stringify({ query, variables })
  const first = await postOnce(io, key, body)
  if (first.ok || !('waitMs' in first)) return plain(first)
  await io.sleep(first.waitMs)
  return plain(await postOnce(io, key, body))
}

export async function linearQuery(
  io: SourceIo,
  query: string,
  variables: Record<string, unknown> = {},
): Promise<Answered> {
  const key = await findKey(io)
  const answered: Answered = key ? await postWithRetry(io, key, query, variables) : { ok: false, failure: 'key-missing' }
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
