import { describe, expect, test } from 'claude-code/testing'
import type { HttpResponse, ProcessRunResult } from 'claude-code'

import type { FailureKind } from '../types'
import type { SourceIo } from '../hooks/sources'
import { failureText, httpText, linearQuery, runGh } from '../hooks/sources'
import { loadSlack } from '../hooks/slack'
import type { SlackIo } from '../hooks/slack'
import { loadWeb } from '../hooks/web'
import { MARKER } from '../hooks/parsers/curl'
import { exited, ref } from './fixtures/results'

// Each transport keeps its own answer for the same status (KTD4): these rows are today's results, disagreements included.

const NOW = 1_700_000_000_000
const KEY = 'lin_api_TABLEKEY'
let sessions = 0

type Run = (argv: readonly string[]) => ProcessRunResult | Error
type Fetch = () => HttpResponse | Error

function answer(status: number, body: unknown): HttpResponse {
  return { status, ok: status >= 200 && status < 300, headers: {}, text: typeof body === 'string' ? body : JSON.stringify(body) }
}

function world(options: { tools?: string[]; ghAuth?: () => ProcessRunResult | Error; gh?: Run; curl?: Run; fetch?: Fetch; hasKey?: boolean; isProcessRefused?: boolean }) {
  const session = `table-${++sessions}`
  const fetches: string[] = []
  const slept: number[] = []
  const io: SourceIo = {
    sessionId: async () => session,
    run: async argv => {
      if (options.isProcessRefused) throw new Error('process.run is not available on this surface')
      const [bin = ''] = argv
      if (bin === 'sh') return exited(0, (options.tools ?? ['gh', 'curl']).map(tool => `${tool}\n`).join(''))
      if (bin === '/usr/bin/security') return options.hasKey === false ? exited(44, '', 'item not found') : exited(0, `${KEY}\n`)
      if (bin === 'gh' && argv[1] === 'auth') {
        const status = options.ghAuth?.() ?? exited(0, '', 'Logged in')
        if (status instanceof Error) throw status
        return status
      }
      const handler = bin === 'gh' ? options.gh : bin === 'curl' ? options.curl : undefined
      if (!handler) throw new Error(`spawn ${bin} ENOENT`)
      const result = handler(argv)
      if (result instanceof Error) throw result
      return result
    },
    fetch: async url => {
      fetches.push(url)
      const result = options.fetch?.() ?? new Error('fetch failed: getaddrinfo ENOTFOUND')
      if (result instanceof Error) throw result
      return result
    },
    linearKeyEnv: async () => undefined,
    home: async () => undefined,
    read: async path => {
      throw new Error(`ENOENT ${path}`)
    },
    sleep: async ms => {
      slept.push(ms)
    },
  }
  return { io, fetches, slept }
}

describe('gh: stderr and probe results', () => {
  const STDERR: [string, FailureKind][] = [
    ['GraphQL: Could not resolve to a PullRequest with the number of 9.', 'gone'],
    ['gh: Not Found (HTTP 404)', 'gone'],
    ['HTTP 410: Gone', 'gone'],
    ['gh: Resource not accessible by integration (HTTP 403)', 'not-found-or-no-access'],
    ['you do not have permission to view this', 'not-found-or-no-access'],
    ['no access to repository', 'not-found-or-no-access'],
    ['HTTP 403: API rate limit exceeded for user', 'rate-limited'],
    ['You have exceeded a secondary rate limit', 'rate-limited'],
    ['HTTP 429: Too Many Requests', 'rate-limited'],
    ['To get started with GitHub CLI, please run:  gh auth login', 'cli-unauthed'],
    ['HTTP 401: Bad credentials', 'cli-unauthed'],
    ['You are not logged in to any GitHub hosts', 'cli-unauthed'],
    ['authentication required', 'cli-unauthed'],
    ['dial tcp: lookup api.github.com: no such host', 'offline'],
    ['Post "https://api.github.com/graphql": net/http: request canceled (Client.Timeout exceeded)', 'offline'],
    ['context deadline exceeded: timed out', 'offline'],
    ['could not connect to api.github.com', 'offline'],
    ['connect: connection refused', 'offline'],
    ['connect: network is unreachable', 'offline'],
    ['error connecting to api.github.com', 'offline'],
    ['HTTP 500: Internal Server Error', 'query-bug'],
    ['HTTP 502: Bad Gateway', 'query-bug'],
    ['unknown flag: --bogus', 'query-bug'],
    ['', 'query-bug'],
  ]
  for (const [stderr, kind] of STDERR) {
    test(`stderr ${JSON.stringify(stderr)} is ${kind}`, async () => {
      const { io } = world({ gh: () => exited(1, '', stderr) })
      expect(await runGh(io, ['pr', 'view', '9'])).toEqual({ ok: false, failure: kind })
    })
  }

  test('the probe answers before gh runs', async () => {
    expect(await runGh(world({ tools: ['curl'] }).io, ['api', 'user'])).toEqual({ ok: false, failure: 'cli-missing' })
    expect(await runGh(world({ ghAuth: () => exited(1, '', 'not logged in') }).io, ['api', 'user'])).toEqual({ ok: false, failure: 'cli-unauthed' })
    expect(await runGh(world({ ghAuth: () => new Error('timed out') }).io, ['api', 'user'])).toEqual({ ok: false, failure: 'offline' })
    expect(await runGh(world({ isProcessRefused: true }).io, ['api', 'user'])).toEqual({ ok: false, failure: 'process-unavailable' })
    expect(await runGh(world({ gh: () => new Error('killed') }).io, ['api', 'user'])).toEqual({ ok: false, failure: 'offline' })
  })
})

describe('Linear GraphQL: four status ladders and the extension codes', () => {
  const STATUSES = [200, 302, 400, 401, 403, 404, 410, 418, 500, 503]
  const NOT_JSON: Record<number, FailureKind> = {
    200: 'query-bug',
    302: 'offline',
    400: 'query-bug',
    401: 'key-refused',
    403: 'not-found-or-no-access',
    404: 'not-found-or-no-access',
    410: 'offline',
    418: 'offline',
    500: 'offline',
    503: 'offline',
  }
  const UNKNOWN_ERROR: Record<number, FailureKind> = {
    200: 'query-bug',
    302: 'query-bug',
    400: 'query-bug',
    401: 'key-refused',
    403: 'not-found-or-no-access',
    404: 'query-bug',
    410: 'query-bug',
    418: 'query-bug',
    500: 'offline',
    503: 'offline',
  }
  const NO_ERRORS: Record<number, FailureKind | 'ok'> = {
    200: 'ok',
    302: 'offline',
    400: 'offline',
    401: 'key-refused',
    403: 'not-found-or-no-access',
    404: 'offline',
    410: 'offline',
    418: 'offline',
    500: 'offline',
    503: 'offline',
  }
  const outcome = (result: { ok: true; data: unknown } | { ok: false; failure: FailureKind }) => (result.ok ? 'ok' : result.failure)
  for (const status of STATUSES) {
    test(`HTTP ${status}: non-JSON ${NOT_JSON[status]}, unknown error ${UNKNOWN_ERROR[status]}, no errors ${NO_ERRORS[status]}`, async () => {
      const bodies = ['<html>Bad gateway</html>', { errors: [{ message: 'odd', extensions: { code: 'WEIRD' } }] }, { errors: [{ message: 'odd' }] }, { data: {} }, { errors: [], data: {} }]
      const got = []
      for (const body of bodies) got.push(outcome(await linearQuery(world({ fetch: () => answer(status, body) }).io, 'query { viewer { id } }')))
      expect(got).toEqual([NOT_JSON[status], UNKNOWN_ERROR[status], UNKNOWN_ERROR[status], NO_ERRORS[status], NO_ERRORS[status]])
    })
  }

  test('429 is rate-limited after one retry, whatever the body', async () => {
    for (const body of ['nope', { errors: [{ extensions: { code: 'WEIRD' } }] }, { data: {} }]) {
      const { io, fetches, slept } = world({ fetch: () => answer(429, body) })
      expect(await linearQuery(io, 'q')).toEqual({ ok: false, failure: 'rate-limited' })
      expect([fetches.length, slept]).toEqual([2, [1000]])
    }
  })

  const CODES: [string, unknown, number, FailureKind][] = [
    ['RATELIMITED code', { extensions: { code: 'RATELIMITED' } }, 200, 'rate-limited'],
    ['ratelimited type', { extensions: { type: 'ratelimited' } }, 400, 'rate-limited'],
    ['lowercase authentication_error', { extensions: { code: 'authentication_error' } }, 200, 'key-refused'],
    ['AUTHENTICATION_ERROR on a 500', { extensions: { code: 'AUTHENTICATION_ERROR' } }, 500, 'key-refused'],
    ['type Not Found', { extensions: { type: 'Not Found' } }, 200, 'gone'],
    ['NOT_FOUND on a 403', { extensions: { code: 'NOT_FOUND' } }, 403, 'gone'],
    ['entity not found message', { message: 'Entity not found: Issue' }, 200, 'gone'],
    ['FORBIDDEN', { extensions: { code: 'FORBIDDEN' } }, 200, 'not-found-or-no-access'],
    ['INPUT_ERROR', { extensions: { code: 'INPUT_ERROR' } }, 200, 'not-found-or-no-access'],
    ['type invalid input', { extensions: { type: 'invalid input' } }, 500, 'not-found-or-no-access'],
    ['GRAPHQL_PARSE_FAILED', { extensions: { code: 'GRAPHQL_PARSE_FAILED' } }, 500, 'query-bug'],
    ['BAD_USER_INPUT', { extensions: { code: 'BAD_USER_INPUT' } }, 401, 'query-bug'],
    ['a non-object error on a 401', 'boom', 401, 'key-refused'],
  ]
  for (const [name, error, status, kind] of CODES) {
    test(`${name} at HTTP ${status} is ${kind}`, async () => {
      const { io } = world({ fetch: () => answer(status, { errors: [error] }) })
      expect(await linearQuery(io, 'q')).toEqual({ ok: false, failure: kind })
    })
  }

  test('a 200 whose data is missing or not an object is a query bug; transport errors and a missing key', async () => {
    for (const body of [{}, { data: null }, { data: 'text' }]) {
      expect(await linearQuery(world({ fetch: () => answer(200, body) }).io, 'q')).toEqual({ ok: false, failure: 'query-bug' })
    }
    expect(await linearQuery(world({ fetch: () => new Error('blocked by web-fetch policy') }).io, 'q')).toEqual({ ok: false, failure: 'fetch-blocked' })
    expect(await linearQuery(world({ fetch: () => new Error('request denied') }).io, 'q')).toEqual({ ok: false, failure: 'fetch-blocked' })
    expect(await linearQuery(world({ fetch: () => new Error('getaddrinfo ENOTFOUND') }).io, 'q')).toEqual({ ok: false, failure: 'offline' })
    expect(await linearQuery(world({ hasKey: false }).io, 'q')).toEqual({ ok: false, failure: 'key-missing' })
  })
})

describe('plain HTTP: httpText and curl pages', () => {
  const PAGE: [number, FailureKind, string][] = [
    [302, 'offline', 'HTTP 302 from h.test'],
    [400, 'query-bug', 'HTTP 400 Bad Request from h.test'],
    [401, 'not-found-or-no-access', 'HTTP 401 Unauthorized from h.test'],
    [403, 'not-found-or-no-access', 'HTTP 403 Forbidden from h.test'],
    [404, 'gone', 'HTTP 404 Not Found from h.test'],
    [410, 'gone', 'HTTP 410 Gone from h.test'],
    [418, 'offline', 'HTTP 418 from h.test'],
    [429, 'rate-limited', 'HTTP 429 Too Many Requests from h.test'],
    [500, 'offline', 'HTTP 500 Internal Server Error from h.test'],
    [502, 'offline', 'HTTP 502 Bad Gateway from h.test'],
    [503, 'offline', 'HTTP 503 Service Unavailable from h.test'],
  ]
  for (const [status, failure, detail] of PAGE) {
    test(`HTTP ${status} is ${failure} through fetch and through curl`, async () => {
      const fetched = world({ tools: [], fetch: () => answer(status, 'body') })
      expect(await httpText(fetched.io, 'https://h.test/p')).toEqual({ ok: false, failure, detail })
      const curled = world({ tools: ['curl'], curl: () => exited(0, 'body', `${MARKER}${status} https://h.test/p`) })
      expect(await loadWeb(curled.io, ref('https://h.test/p'), NOW)).toEqual({ ok: false, failure, detail })
    })
  }

  test("curl's own edges: a 200 with a failed exit and no body, no marker, an empty or zero status", async () => {
    const page = (run: Run) => loadWeb(world({ tools: ['curl'], curl: run }).io, ref('https://h.test/p'), NOW)
    expect(await page(() => exited(28, '', `${MARKER}200 https://h.test/p`))).toEqual({ ok: false, failure: 'offline', detail: 'HTTP 200 from h.test' })
    expect(await page(() => exited(6, '', 'Could not resolve host'))).toEqual({ ok: false, failure: 'offline' })
    expect(await page(() => exited(7, '', `${MARKER}000 https://h.test/p`))).toEqual({ ok: false, failure: 'offline' })
    expect(await page(() => exited(7, '', MARKER))).toEqual({ ok: false, failure: 'offline' })
    expect(await page(() => new Error('killed'))).toEqual({ ok: false, failure: 'offline' })
    expect(await page(() => exited(0, 'body', `${MARKER}404 https://elsewhere.test/q`))).toEqual({ ok: false, failure: 'gone', detail: 'HTTP 404 Not Found from elsewhere.test' })
  })

  test('fetch transport errors and refused addresses', async () => {
    expect(await httpText(world({ fetch: () => new Error('blocked by web-fetch policy') }).io, 'https://h.test/')).toEqual({ ok: false, failure: 'fetch-blocked' })
    expect(await httpText(world({ fetch: () => new Error('getaddrinfo ENOTFOUND') }).io, 'https://h.test/')).toEqual({ ok: false, failure: 'offline' })
    expect(await httpText(world({}).io, 'file:///etc/passwd')).toEqual({ ok: false, failure: 'query-bug' })
    expect(await httpText(world({}).io, 'not a url')).toEqual({ ok: false, failure: 'query-bug' })
  })
})

describe('Slack: error codes and the transport that cannot serve', () => {
  const THREAD = 'https://acme.slack.com/archives/C0123ABCD/p1791759796763609'
  type Options = { mcp?: (tool: string) => { content: unknown[]; isError: boolean }; cli?: Run }
  const text = (body: string, isError = true) => ({ content: [{ type: 'text', text: body }], isError })

  function slackWorld(options: Options): SlackIo {
    const session = `slack-table-${++sessions}`
    return {
      sessionId: async () => session,
      mcpCall: async (server, tool) => {
        if (!options.mcp) throw new Error(`MCP server "${server}" is not connected`)
        return options.mcp(tool)
      },
      run: async argv => {
        if (argv[0] === 'sh') return options.cli ? exited(0, '/usr/local/bin/slack\n') : exited(0, '')
        const result = options.cli ? options.cli(argv) : exited(1)
        if (result instanceof Error) throw result
        return result
      },
    }
  }
  const load = (options: Options) => loadSlack(slackWorld(options), ref(THREAD), NOW)

  const CODES: [string, FailureKind][] = [
    ['thread_not_found', 'gone'],
    ['message_not_found', 'gone'],
    ['channel_not_found', 'not-found-or-no-access'],
    ['not_in_channel', 'not-found-or-no-access'],
    ['access_denied', 'not-found-or-no-access'],
    ['missing_scope', 'not-found-or-no-access'],
    ['no_permission', 'not-found-or-no-access'],
    ['ratelimited', 'rate-limited'],
    ['rate_limited', 'rate-limited'],
    ['invalid_auth', 'slack-unavailable'],
    ['not_authed', 'slack-unavailable'],
    ['token_revoked', 'slack-unavailable'],
    ['token_expired', 'slack-unavailable'],
    ['account_inactive', 'slack-unavailable'],
    ['something_else', 'query-bug'],
  ]
  for (const [code, failure] of CODES) {
    test(`${code} is ${failure} from the MCP server and from the CLI`, async () => {
      expect(await load({ mcp: () => text(`execution_failed: ${code}\n\nDetails.`) })).toEqual({ ok: false, failure })
      expect(await load({ mcp: () => text(code) })).toEqual({ ok: false, failure })
      expect(await load({ cli: () => exited(0, JSON.stringify({ ok: false, error: code })) })).toEqual({ ok: false, failure })
    })
  }

  test('messages that carry no code are query bugs', async () => {
    expect(await load({ mcp: () => text('Thread not found') })).toEqual({ ok: false, failure: 'query-bug' })
    expect(await load({ mcp: () => text('') })).toEqual({ ok: false, failure: 'query-bug' })
    expect(await load({ cli: () => exited(0, JSON.stringify({ ok: false })) })).toEqual({ ok: false, failure: 'query-bug' })
  })

  test('a refused MCP token falls through to the CLI, whose answer wins', async () => {
    expect(await load({ mcp: () => text('execution_failed: invalid_auth'), cli: () => exited(0, JSON.stringify({ ok: false, error: 'thread_not_found' })) })).toEqual({ ok: false, failure: 'gone' })
    expect(await load({ mcp: () => text('execution_failed: thread_not_found'), cli: () => exited(0, JSON.stringify({ ok: false, error: 'channel_not_found' })) })).toEqual({ ok: false, failure: 'gone' })
  })

  test('a CLI that cannot serve is slack-unavailable; one that answers badly is a query bug or offline', async () => {
    expect(await load({})).toEqual({ ok: false, failure: 'slack-unavailable' })
    expect(await load({ cli: () => exited(1, 'not logged in') })).toEqual({ ok: false, failure: 'slack-unavailable' })
    expect(await load({ cli: () => exited(0, 'Usage: slack api') })).toEqual({ ok: false, failure: 'query-bug' })
    expect(await load({ cli: () => new Error('killed') })).toEqual({ ok: false, failure: 'offline' })
    expect(await load({ cli: () => exited(0, JSON.stringify({ ok: true, messages: [] })) })).toEqual({ ok: false, failure: 'query-bug' })
  })
})

describe('failure text', () => {
  const TEXT: Record<FailureKind, { title: string; hint: string }> = {
    'cli-missing': { title: 'GitHub CLI is not installed', hint: 'Install it with `brew install gh`, then run `gh auth login`' },
    'cli-unauthed': { title: 'GitHub CLI is not signed in', hint: 'Run `gh auth login` in a terminal' },
    'key-missing': { title: 'No Linear API key found', hint: 'Set LINEAR_API_KEY or add it to ~/.secrets' },
    'key-refused': { title: 'Linear refused the API key', hint: 'Create a new key in Linear settings and update LINEAR_API_KEY' },
    'not-found-or-no-access': { title: 'Not found, or you have no access', hint: 'Check the link, or open it in the browser' },
    gone: { title: 'Not found: it was deleted, moved, or you have no access', hint: 'Check the link, or open it in the browser' },
    'rate-limited': { title: 'Rate limited', hint: 'Wait a minute, then refresh' },
    offline: { title: 'Could not reach the service', hint: 'Check your connection, then refresh' },
    'query-bug': { title: 'peek sent a request the service rejected', hint: 'Open it in the browser; this is a peek bug' },
    'fetch-blocked': { title: 'Your network policy blocks this request', hint: 'Open it in the browser instead' },
    'process-unavailable': { title: 'Command-line tools are unavailable here', hint: 'This surface cannot run command-line tools' },
    'live-unavailable': { title: 'Live view needs the Swift compiler', hint: 'Install the command-line tools with `xcode-select --install`, then press v' },
    'live-crashed': { title: 'The live view stopped', hint: 'Press v to start it again' },
    'live-stalled': { title: 'The live page never drew', hint: 'Press v to try again, or o to open it in the browser' },
    'slack-unavailable': { title: 'Slack is not connected', hint: 'Slack: connect the Slack MCP server (/mcp), or install the Slack CLI and run `slack login`' },
  }
  for (const [kind, text] of Object.entries(TEXT) as [FailureKind, { title: string; hint: string }][]) {
    test(`${kind} keeps its title and hint`, () => {
      expect(failureText(kind)).toEqual(text)
    })
  }
})
