import { describe, expect, test } from 'claude-code/testing'
import type { HttpInit, HttpResponse, ProcessRunInit, ProcessRunResult } from 'claude-code'

import type { FailureKind } from '../types'
import type { SourceIo } from '../hooks/sources'
import { failureText, hasCurl, httpText, linearPaged, linearQuery, probe, runGh, tierFor } from '../hooks/sources'

const KEY = 'lin_api_PLANTEDKEY123'
const ALL_KINDS: FailureKind[] = [
  'cli-missing',
  'cli-unauthed',
  'key-missing',
  'key-refused',
  'not-found-or-no-access',
  'rate-limited',
  'offline',
  'query-bug',
  'fetch-blocked',
  'process-unavailable',
]

type Run = (argv: readonly string[]) => ProcessRunResult | Error
type Fetch = (url: string, init?: HttpInit) => HttpResponse | Error

type WorldOptions = {
  keychain?: string
  env?: Record<string, string>
  secrets?: string
  tools?: string[]
  ghAuthExit?: number
  isProcessRefused?: boolean
  gh?: Run
  curl?: Run
  fetch?: Fetch
}

let sessions = 0

function exited(exitCode: number, stdout = '', stderr = ''): ProcessRunResult {
  return { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false }
}

function answer(status: number, body: unknown, headers: Record<string, string> = {}): HttpResponse {
  return { status, ok: status >= 200 && status < 300, headers, text: typeof body === 'string' ? body : JSON.stringify(body) }
}

function world(options: WorldOptions) {
  const session = `s-${++sessions}`
  const argvs: string[][] = []
  const fetches: { url: string; init?: HttpInit }[] = []
  const authorizations: string[] = []
  const slept: number[] = []
  const run = async (argv: readonly string[], _init?: ProcessRunInit): Promise<ProcessRunResult> => {
    argvs.push([...argv])
    if (options.isProcessRefused) throw new Error('process.run is not available on this surface')
    const [bin = ''] = argv
    if (bin === 'sh') return exited(0, (options.tools ?? ['gh', 'curl']).map(tool => `${tool}\n`).join(''))
    if (bin === '/usr/bin/security') return options.keychain ? exited(0, `${options.keychain}\n`) : exited(44, '', 'item not found')
    if (bin === 'gh' && argv[1] === 'auth' && argv[2] === 'status') return exited(options.ghAuthExit ?? 0, '', 'Logged in')
    const handler = bin === 'gh' ? options.gh : bin === 'curl' ? options.curl : undefined
    if (!handler) throw new Error(`spawn ${bin} ENOENT`)
    const result = handler(argv)
    if (result instanceof Error) throw result
    return result
  }
  const fetch = async (url: string, init?: HttpInit): Promise<HttpResponse> => {
    const { Authorization, ...headers } = init?.headers ?? {}
    if (Authorization !== undefined) authorizations.push(Authorization)
    fetches.push({ url, init: init && { ...init, headers } })
    const result = options.fetch?.(url, init) ?? new Error('fetch failed: getaddrinfo ENOTFOUND')
    if (result instanceof Error) throw result
    return result
  }
  const $: SourceIo = {
    sessionId: async () => session,
    run,
    fetch,
    linearKeyEnv: async () => options.env?.LINEAR_API_KEY,
    home: async () => '/home/u',
    read: async (path: string) => {
      if (path === '/home/u/.secrets' && options.secrets !== undefined) return options.secrets
      throw new Error(`ENOENT ${path}`)
    },
    sleep: async (ms: number) => void slept.push(ms),
  }
  return { $, argvs, fetches, authorizations, slept }
}

const outputs: unknown[] = []
const watched: ReturnType<typeof world>[] = []

function keyed(options: WorldOptions = {}) {
  const made = world({ keychain: KEY, ...options })
  watched.push(made)
  return made
}

async function seen<T>(value: Promise<T>): Promise<T> {
  const settled = await value
  outputs.push(settled)
  return settled
}

const ISSUE = 'query { viewer { id } }'

describe('Linear key lookup', () => {
  test('falls through Keychain and env to ~/.secrets and strips quotes and export', async () => {
    const { $, authorizations, fetches } = world({
      secrets: 'OTHER_SECRET=nope\nexport LINEAR_API_KEY="abc"\nMORE=x\n',
      fetch: () => answer(200, { data: { viewer: { id: 'u' } } }),
    })
    expect(await linearQuery($, ISSUE)).toEqual({ ok: true, data: { viewer: { id: 'u' } } })
    expect(authorizations).toEqual(['abc'])
    expect(fetches[0]?.url).toBe('https://api.linear.app/graphql')
    expect(fetches[0]?.init?.method).toBe('POST')
  })

  test('the env variable wins over ~/.secrets, the Keychain over both', async () => {
    const fromEnv = world({ env: { LINEAR_API_KEY: 'envkey' }, secrets: 'LINEAR_API_KEY=filekey', fetch: () => answer(200, { data: {} }) })
    await linearQuery(fromEnv.$, ISSUE)
    expect(fromEnv.authorizations).toEqual(['envkey'])
    const fromKeychain = world({ keychain: 'chainkey', env: { LINEAR_API_KEY: 'envkey' }, fetch: () => answer(200, { data: {} }) })
    await linearQuery(fromKeychain.$, ISSUE)
    expect(fromKeychain.authorizations).toEqual(['chainkey'])
    expect(fromKeychain.argvs[0]).toEqual(['/usr/bin/security', 'find-generic-password', '-a', 'linear-api-key', '-s', 'work-linear', '-w'])
  })

  test('the key is looked up once per session, and again after Linear refuses it', async () => {
    let status = 200
    const { $, argvs } = keyed({ fetch: () => answer(status, status === 200 ? { data: {} } : 'Unauthorized') })
    const lookups = () => argvs.filter(argv => argv[0] === '/usr/bin/security').length
    await linearQuery($, ISSUE)
    await linearQuery($, ISSUE)
    expect(lookups()).toBe(1)
    status = 401
    expect(await seen(linearQuery($, ISSUE))).toEqual({ ok: false, failure: 'key-refused' })
    status = 200
    expect(await linearQuery($, ISSUE)).toEqual({ ok: true, data: {} })
    expect(lookups()).toBe(2)
  })

  test('no key anywhere is key-missing, and nothing is sent', async () => {
    const { $, fetches } = world({})
    expect(await linearQuery($, ISSUE)).toEqual({ ok: false, failure: 'key-missing' })
    expect(await tierFor($, 'linear-issue')).toEqual({ ok: false, failure: 'key-missing' })
    expect(fetches).toEqual([])
  })
})

describe('Linear failures', () => {
  test('HTTP 401 is key-refused', async () => {
    const { $ } = keyed({ fetch: () => answer(401, 'Unauthorized') })
    expect(await seen(linearQuery($, ISSUE))).toEqual({ ok: false, failure: 'key-refused' })
  })

  test('a GraphQL AUTHENTICATION_ERROR is key-refused', async () => {
    const { $ } = keyed({ fetch: () => answer(400, { errors: [{ message: 'bad', extensions: { code: 'AUTHENTICATION_ERROR' } }] }) })
    expect(await seen(linearQuery($, ISSUE))).toEqual({ ok: false, failure: 'key-refused' })
  })

  test('RATELIMITED retries once after retry-after, then is rate-limited', async () => {
    const limited = () => answer(400, { errors: [{ message: 'slow', extensions: { code: 'RATELIMITED' } }] }, { 'retry-after': '1' })
    const { $, fetches, slept } = keyed({ fetch: limited })
    expect(await seen(linearQuery($, ISSUE))).toEqual({ ok: false, failure: 'rate-limited' })
    expect(fetches.length).toBe(2)
    expect(slept).toEqual([1000])
  })

  test('a rate limit that clears on the retry answers the data, and the wait is capped at 5 s', async () => {
    let calls = 0
    const { $, slept } = keyed({ fetch: () => (++calls === 1 ? answer(429, '', { 'retry-after': '60' }) : answer(200, { data: { ok: 1 } })) })
    expect(await seen(linearQuery($, ISSUE))).toEqual({ ok: true, data: { ok: 1 } })
    expect(slept).toEqual([5000])
  })

  test('a GraphQL validation error is query-bug, not offline', async () => {
    const { $ } = keyed({ fetch: () => answer(400, { errors: [{ message: 'Cannot query field', extensions: { code: 'GRAPHQL_VALIDATION_FAILED' } }] }) })
    expect(await seen(linearQuery($, ISSUE))).toEqual({ ok: false, failure: 'query-bug' })
  })

  test('entity not found is not-found-or-no-access', async () => {
    const { $ } = keyed({ fetch: () => answer(200, { errors: [{ message: 'Entity not found: Issue', extensions: { code: 'INPUT_ERROR' } }] }) })
    expect(await seen(linearQuery($, ISSUE))).toEqual({ ok: false, failure: 'not-found-or-no-access' })
  })

  test('a fetch that throws is offline', async () => {
    const { $ } = keyed({ fetch: () => new Error('fetch failed: ECONNREFUSED') })
    expect(await seen(linearQuery($, ISSUE))).toEqual({ ok: false, failure: 'offline' })
  })

  test('a fetch refused by policy is fetch-blocked', async () => {
    const { $ } = keyed({ fetch: () => new Error('Request refused by the organization web-fetch policy') })
    expect(await seen(linearQuery($, ISSUE))).toEqual({ ok: false, failure: 'fetch-blocked' })
  })
})

describe('linearPaged', () => {
  const pages = (total: number) => (_url: string, init?: HttpInit) => {
    const { variables } = JSON.parse(init?.body ?? '{}') as { variables: { first: number; after: string | null } }
    const start = variables.after ? Number(variables.after) : 0
    const end = Math.min(start + variables.first, total)
    const nodes = Array.from({ length: end - start }, (_, i) => ({ id: start + i }))
    return answer(200, { data: { issues: { nodes, pageInfo: { hasNextPage: end < total, endCursor: String(end) } } } })
  }
  const pick = (data: unknown) => (data as { issues: { nodes: unknown[] } }).issues

  test('120 nodes across three pages come back whole', async () => {
    const { $, fetches } = keyed({ fetch: pages(120) })
    const result = await seen(linearPaged($, ISSUE, { team: 't' }, pick))
    expect(result.ok && result.nodes.length).toBe(120)
    expect(result.ok && result.isPartial).toBe(false)
    expect(fetches.length).toBe(3)
    expect(JSON.parse(fetches[1]?.init?.body ?? '{}').variables).toEqual({ team: 't', first: 50, after: '50' })
  })

  test('more than ten pages stops at ten and says so', async () => {
    const { $, fetches } = keyed({ fetch: pages(5000) })
    const result = await seen(linearPaged($, ISSUE, {}, pick))
    expect(result.ok && result.nodes.length).toBe(500)
    expect(result.ok && result.isPartial).toBe(true)
    expect(fetches.length).toBe(10)
  })
})

describe('probe and gh', () => {
  test('gh auth status exiting non-zero is cli-unauthed', async () => {
    const { $ } = keyed({ ghAuthExit: 1 })
    expect(await seen(runGh($, ['issue', 'view', '1']))).toEqual({ ok: false, failure: 'cli-unauthed' })
    expect(await tierFor($, 'gh-pr')).toEqual({ ok: false, failure: 'cli-unauthed' })
  })

  test('gh missing from PATH is cli-missing', async () => {
    const { $ } = keyed({ tools: ['curl'] })
    expect(await seen(runGh($, ['issue', 'view', '1']))).toEqual({ ok: false, failure: 'cli-missing' })
    expect(await hasCurl($)).toBe(true)
  })

  test('process.run rejecting outright is process-unavailable, and web pages fall back to fetch', async () => {
    const { $ } = keyed({ isProcessRefused: true, fetch: () => answer(200, '<html>hi</html>') })
    expect(await seen(runGh($, ['issue', 'view', '1']))).toEqual({ ok: false, failure: 'process-unavailable' })
    expect(await tierFor($, 'web')).toEqual({ ok: true, tier: 'api' })
    expect(await seen(httpText($, 'https://example.com/'))).toEqual({ ok: true, text: '<html>hi</html>' })
  })

  test('the probe runs once per session', async () => {
    const { $, argvs } = keyed({})
    await probe($)
    await probe($)
    await runGh($, ['api', 'user'])
    expect(argvs.filter(argv => argv[0] === 'sh').length).toBe(1)
    expect(argvs.filter(argv => argv.join(' ') === 'gh auth status').length).toBe(1)
  })

  test('signing in to gh mid-session is noticed on the next call; a healthy probe stays cached', async () => {
    const options: WorldOptions = { keychain: KEY, ghAuthExit: 1, gh: () => exited(0, '{"ok":true}') }
    const { $, argvs } = world(options)
    expect(await seen(runGh($, ['api', 'user']))).toEqual({ ok: false, failure: 'cli-unauthed' })
    options.ghAuthExit = 0
    expect(await runGh($, ['api', 'user'])).toEqual({ ok: true, stdout: '{"ok":true}' })
    await runGh($, ['api', 'user'])
    expect(argvs.filter(argv => argv.join(' ') === 'gh auth status').length).toBe(2)
  })

  test('gh auth status timing out is offline, not cli-missing, and is probed again', async () => {
    const made = keyed({ gh: () => exited(0, 'fine') })
    let isHung = true
    const run = made.$.run
    const $: SourceIo = {
      ...made.$,
      run: async (argv, init) => {
        if (isHung && argv.join(' ') === 'gh auth status') throw new Error('process timed out after 10000 ms')
        return run(argv, init)
      },
    }
    expect(await seen(runGh($, ['api', 'user']))).toEqual({ ok: false, failure: 'offline' })
    expect(await tierFor($, 'gh-pr')).toEqual({ ok: false, failure: 'offline' })
    isHung = false
    expect(await runGh($, ['api', 'user'])).toEqual({ ok: true, stdout: 'fine' })
  })

  test('a gh found missing is probed again, so installing it mid-session is noticed', async () => {
    const options: WorldOptions = { keychain: KEY, tools: ['curl'], gh: () => exited(0, 'fine') }
    const { $ } = world(options)
    expect(await seen(runGh($, ['api', 'user']))).toEqual({ ok: false, failure: 'cli-missing' })
    options.tools = ['gh', 'curl']
    expect(await runGh($, ['api', 'user'])).toEqual({ ok: true, stdout: 'fine' })
  })

  test('gh stderr maps to a kind and never travels upward', async () => {
    const cases: [string, FailureKind][] = [
      ['GraphQL: Could not resolve to a PullRequest with the number of 9.', 'not-found-or-no-access'],
      ['HTTP 403: API rate limit exceeded for user', 'rate-limited'],
      ['To get started with GitHub CLI, please run:  gh auth login', 'cli-unauthed'],
      ['dial tcp: lookup api.github.com: no such host', 'offline'],
      ['unknown flag: --bogus', 'query-bug'],
    ]
    for (const [stderr, kind] of cases) {
      const { $ } = keyed({ gh: () => exited(1, '', `${stderr} ${KEY}`) })
      const result = await seen(runGh($, ['pr', 'view', '9', '--json', 'title']))
      expect(result).toEqual({ ok: false, failure: kind })
    }
    const { $ } = keyed({ gh: argv => exited(0, `{"args":${JSON.stringify(argv.slice(1))}}`) })
    expect(await runGh($, ['api', 'repos/o/r'])).toEqual({ ok: true, stdout: '{"args":["api","repos/o/r"]}' })
  })
})

describe('httpText', () => {
  test('a 404 page is not-found-or-no-access, a dead host offline, a non-web URL query-bug', async () => {
    const missing = keyed({ tools: ['gh'], fetch: () => answer(404, 'gone') })
    expect(await seen(httpText(missing.$, 'https://example.com/x'))).toEqual({ ok: false, failure: 'not-found-or-no-access', detail: 'HTTP 404 Not Found from example.com' })
    const dead = keyed({ tools: ['gh'], fetch: () => new Error('fetch failed: getaddrinfo ENOTFOUND') })
    expect(await seen(httpText(dead.$, 'https://nowhere.invalid/'))).toEqual({ ok: false, failure: 'offline' })
    expect(await seen(httpText(dead.$, 'file:///etc/passwd'))).toEqual({ ok: false, failure: 'query-bug' })
    expect(dead.fetches).toEqual([{ url: 'https://nowhere.invalid/', init: undefined }])
  })

  test('without curl a policy refusal is fetch-blocked', async () => {
    const { $ } = keyed({ tools: ['gh'], fetch: () => new Error('blocked by web-fetch policy') })
    expect(await seen(httpText($, 'https://example.com/'))).toEqual({ ok: false, failure: 'fetch-blocked' })
  })
})

test('every kind has a title and a next action', () => {
  for (const kind of ALL_KINDS) {
    const text = failureText(kind)
    expect(text.title.length > 0 && text.hint.length > 0).toBe(true)
  }
  expect(failureText('cli-unauthed').hint).toBe('Run `gh auth login` in a terminal')
  expect(failureText('key-missing').hint).toBe('Set LINEAR_API_KEY or add it to ~/.secrets')
  expect(failureText('process-unavailable').hint).toBe('This surface cannot run command-line tools')
})

test('the planted key appears nowhere but the Authorization header, across every failure kind', () => {
  const failures = new Set(outputs.flatMap(value => ((value as { failure?: FailureKind }).failure ? [(value as { failure: FailureKind }).failure] : [])))
  for (const kind of ALL_KINDS.filter(kind => kind !== 'key-missing')) expect([kind, failures.has(kind)]).toEqual([kind, true])
  const visible = JSON.stringify({
    outputs,
    texts: ALL_KINDS.map(failureText),
    argvs: watched.flatMap(made => made.argvs),
    fetches: watched.flatMap(made => made.fetches),
  })
  expect(visible.includes(KEY)).toBe(false)
  expect(watched.some(made => made.authorizations.includes(KEY))).toBe(true)
})
