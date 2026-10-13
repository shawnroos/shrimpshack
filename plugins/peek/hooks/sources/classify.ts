import type { FailureKind } from '../../types'

// Each transport answers the same status its own way (a 404 page is gone, a 404 non-JSON GraphQL reply is
// not-found-or-no-access); the contexts keep those answers apart rather than unifying them.
export type StatusContext = 'page' | 'graphql-text' | 'graphql-error' | 'graphql-data'

type StatusTable = { exact: Readonly<Partial<Record<number, FailureKind>>>; success: FailureKind; serverError: FailureKind; other: FailureKind }

const STATUS_TABLES: Record<StatusContext, StatusTable> = {
  page: {
    exact: { 400: 'query-bug', 401: 'not-found-or-no-access', 403: 'not-found-or-no-access', 404: 'gone', 410: 'gone', 429: 'rate-limited' },
    success: 'offline',
    serverError: 'offline',
    other: 'offline',
  },
  'graphql-text': {
    exact: { 400: 'query-bug', 401: 'key-refused', 403: 'not-found-or-no-access', 404: 'not-found-or-no-access' },
    success: 'query-bug',
    serverError: 'offline',
    other: 'offline',
  },
  'graphql-error': {
    exact: { 400: 'query-bug', 401: 'key-refused', 403: 'not-found-or-no-access' },
    success: 'query-bug',
    serverError: 'offline',
    other: 'query-bug',
  },
  'graphql-data': {
    exact: { 401: 'key-refused', 403: 'not-found-or-no-access' },
    success: 'offline',
    serverError: 'offline',
    other: 'offline',
  },
}

export function fromHttpStatus(status: number, context: StatusContext): FailureKind {
  const table = STATUS_TABLES[context]
  const exact = table.exact[status]
  if (exact) return exact
  if (status >= 200 && status < 300) return table.success
  return status >= 500 ? table.serverError : table.other
}

export type PatternRules = readonly (readonly [RegExp, FailureKind])[]

export function fromPatterns(text: string, rules: PatternRules): FailureKind | null {
  return rules.find(([pattern]) => pattern.test(text))?.[1] ?? null
}

// First match wins: a 403 that names a rate limit is rate-limited.
export const GH_RULES: PatternRules = [
  [/rate limit|secondary rate|HTTP 429/i, 'rate-limited'],
  [/gh auth login|not logged in|authentication|HTTP 401|bad credentials/i, 'cli-unauthed'],
  [/HTTP 403|no access|permission/i, 'not-found-or-no-access'],
  [/Could not resolve to a|HTTP 404|HTTP 410|Not Found/i, 'gone'],
  [/dial tcp|could not connect|connection refused|timeout|timed out|no such host|network is unreachable|error connecting/i, 'offline'],
]

export function ghFailure(stderr: string): FailureKind {
  return fromPatterns(stderr, GH_RULES) ?? 'query-bug'
}

// null: this transport's token is refused, so the next transport may still serve the thread.
export const SLACK_CODES: Readonly<Record<string, FailureKind | null>> = {
  thread_not_found: 'gone',
  message_not_found: 'gone',
  channel_not_found: 'not-found-or-no-access',
  not_in_channel: 'not-found-or-no-access',
  access_denied: 'not-found-or-no-access',
  missing_scope: 'not-found-or-no-access',
  no_permission: 'not-found-or-no-access',
  ratelimited: 'rate-limited',
  rate_limited: 'rate-limited',
  invalid_auth: null,
  not_authed: null,
  token_revoked: null,
  token_expired: null,
  account_inactive: null,
}

export function slackFailure(message: string): FailureKind | null {
  const code = /execution_failed:\s*([a-z_]+)/.exec(message)?.[1] ?? /^\s*([a-z_]+)\s*$/.exec(message)?.[1] ?? ''
  return Object.hasOwn(SLACK_CODES, code) ? (SLACK_CODES[code] ?? null) : 'query-bug'
}
