import { describe, expect, test } from 'claude-code/testing'
import type { ProcessRunResult } from 'claude-code'

import type { Captured } from '../hooks/capture'
import { ciSummary, fromCapture, loadGithub, resolveNumber } from '../hooks/github'
import type { Ref } from '../hooks/refs'
import { parseRef } from '../hooks/refs'
import type { SourceIo } from '../hooks/sources'
import type { Loaded, RemoteRecord } from '../types'
import { checks, conversation, issueList, issueView, issuesApiIssue, issuesApiPull, mcpPullRead, pullList, pullView, repoView } from './fixtures/github/items'

const NOW = 1_790_000_000_000

type Gh = (args: string[]) => ProcessRunResult

let sessions = 0

function exited(exitCode: number, stdout = '', stderr = ''): ProcessRunResult {
  return { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false }
}

function ok(value: unknown): ProcessRunResult {
  return exited(0, typeof value === 'string' ? value : JSON.stringify(value))
}

function world(gh: Gh) {
  const session = `gh-${++sessions}`
  const calls: string[][] = []
  const $: SourceIo = {
    sessionId: async () => session,
    run: async argv => {
      const [bin = '', ...args] = argv
      if (bin === 'sh') return exited(0, 'gh\ncurl\n')
      if (bin === '/usr/bin/security') return exited(44, '', 'item not found')
      if (bin === 'gh' && args[0] === 'auth') return exited(0)
      if (bin !== 'gh') throw new Error(`spawn ${bin} ENOENT`)
      calls.push(args)
      return gh(args)
    },
    fetch: async () => {
      throw new Error('no network in tests')
    },
    linearKeyEnv: async () => undefined,
    home: async () => '/home/u',
    read: async path => {
      throw new Error(`ENOENT ${path}`)
    },
    sleep: async () => {},
  }
  return { $, calls }
}

function routes(table: Record<string, () => ProcessRunResult>): Gh {
  return args => {
    const line = args.join(' ')
    const hit = Object.keys(table).find(prefix => line.startsWith(prefix))
    return hit ? (table[hit] as () => ProcessRunResult)() : exited(1, '', `unexpected: ${line}`)
  }
}

function record(loaded: Loaded): RemoteRecord {
  if (!loaded.ok) throw new Error(`expected a record, got ${loaded.failure}`)
  return loaded.record
}

function meta(rec: RemoteRecord, label: string): string | undefined {
  return rec.meta.find(entry => entry.label === label)?.value
}

function ref(text: string): Ref {
  const parsed = parseRef(text)
  if (!parsed) throw new Error(`unparsed ${text}`)
  return parsed
}

function prWorld(view: Record<string, unknown>, inline = 5) {
  return world(
    routes({
      'pr view 42': () => ok(view),
      'api repos/acme/widgets/pulls/42': () => ok(String(inline)),
    }),
  )
}

describe('issue or pull request', () => {
  test('covers AE1: a number whose issues-API answer has pull_request loads as a pull request', async () => {
    const { $, calls } = world(
      routes({
        'api repos/acme/widgets/issues/42': () => ok(issuesApiPull),
        'pr view 42': () => ok(pullView()),
        'api repos/acme/widgets/pulls/42': () => ok('5'),
      }),
    )
    const loaded = await loadGithub($, ref('acme/widgets#42'), NOW)
    const rec = record(loaded)
    expect(rec.kind).toBe('gh-pr')
    expect(rec.address).toBe('https://github.com/acme/widgets/pull/42')
    expect(calls.some(args => args[0] === 'issue')).toBe(false)
  })

  test('an /issues/N URL that is really a pull request opens as one; the check is cached per address', async () => {
    const { $, calls } = world(
      routes({
        'api repos/acme/widgets/issues/42': () => ok(issuesApiPull),
      }),
    )
    const first = await resolveNumber($, ref('https://github.com/acme/widgets/issues/42'))
    const again = await resolveNumber($, ref('https://github.com/acme/widgets/issues/42'))
    expect(first).toEqual({ ok: true, ref: { kind: 'gh-pr', address: 'https://github.com/acme/widgets/pull/42', owner: 'acme', repo: 'widgets', number: 42 } })
    expect(again).toEqual(first)
    expect(calls.length).toBe(1)
  })

  test('a plain issue number loads as an issue', async () => {
    const { $ } = world(
      routes({
        'api repos/acme/widgets/issues/7': () => ok(issuesApiIssue),
        'issue view 7': () => ok(issueView()),
      }),
    )
    const rec = record(await loadGithub($, ref('acme/widgets#7'), NOW))
    expect(rec.kind).toBe('gh-issue')
    expect(rec.address).toBe('https://github.com/acme/widgets/issues/7')
  })

  test('a /pull/N ref skips the check', async () => {
    const { $, calls } = prWorld(pullView())
    record(await loadGithub($, ref('https://github.com/acme/widgets/pull/42'), NOW))
    expect(calls.some(args => args.join(' ').includes('issues/42'))).toBe(false)
  })
})

describe('issue page', () => {
  test('trail, title and meta', async () => {
    const { $ } = world(
      routes({
        'api repos/acme/widgets/issues/7': () => ok(issuesApiIssue),
        'issue view 7': () => ok(issueView()),
      }),
    )
    const loaded = await loadGithub($, ref('https://github.com/acme/widgets/issues/7'), NOW)
    expect(loaded.ok && loaded.tier).toBe('cli')
    expect(loaded.ok && loaded.fetchedAt).toBe(NOW)
    const rec = record(loaded)
    expect(rec.trail).toEqual(['acme', 'widgets'])
    expect(rec.title).toContain('Parser drops trailing comma')
    expect(rec.title).toContain('#7')
    expect(rec.status).toBe('open')
    expect(rec.isFrozen).toBe(false)
    expect(meta(rec, 'Assignees')).toBe('hubot')
    expect(meta(rec, 'Labels')).toBe('bug')
    expect(meta(rec, 'Milestone')).toBe('v2.0')
    expect(meta(rec, 'Created')).toBe('2026-08-01')
    expect(meta(rec, 'Updated')).toBe('2026-08-05')
    expect(rec.body).toBe('Steps to reproduce.')
    expect(rec.comments?.total).toBe(3)
    expect(rec.browserUrl).toBe('https://github.com/acme/widgets/issues/7')
  })

  test('a closed issue is frozen', async () => {
    const { $ } = world(
      routes({
        'api repos/acme/widgets/issues/7': () => ok(issuesApiIssue),
        'issue view 7': () => ok(issueView({ state: 'CLOSED', stateReason: 'COMPLETED', closedAt: '2026-08-09T00:00:00Z' })),
      }),
    )
    const rec = record(await loadGithub($, ref('acme/widgets#7'), NOW))
    expect(rec.status).toBe('closed')
    expect(rec.isFrozen).toBe(true)
    expect(meta(rec, 'Closed')).toBe('2026-08-09')
  })
})

describe('pull request page', () => {
  test('meta, stats, interleaved conversation and inline count', async () => {
    const { $ } = prWorld(pullView(), 9)
    const rec = record(await loadGithub($, ref('https://github.com/acme/widgets/pull/42'), NOW))
    expect(rec.kind).toBe('gh-pr')
    expect(rec.trail).toEqual(['acme', 'widgets'])
    expect(rec.title).toContain('Teach the parser trailing commas')
    expect(rec.status).toBe('open')
    expect(rec.isFrozen).toBe(false)
    expect(rec.stats).toEqual({ additions: 120, deletions: 8, changedFiles: 4, ci: '3 passed' })
    expect(meta(rec, 'Review')).toBe('Review required')
    expect(meta(rec, 'Merge state')).toBe('Blocked')
    expect(meta(rec, 'Branch')).toBe('fix/commas → main')
    expect(rec.comments?.shown.map(c => c.body)).toEqual(['first', 'looks fine', 'third'])
    expect(rec.comments?.shown[1]?.isReview).toBe(true)
    expect(rec.comments?.total).toBe(3)
    expect(rec.comments?.inline).toBe(9)
  })

  test('a draft reads as draft', async () => {
    const { $ } = prWorld(pullView({ isDraft: true }))
    expect(record(await loadGithub($, ref('https://github.com/acme/widgets/pull/42'), NOW)).status).toBe('draft')
  })

  test('a merged pull request shows its merged date and is frozen', async () => {
    const { $ } = prWorld(pullView({ state: 'MERGED', mergedAt: '2026-09-04T09:00:00Z', closedAt: '2026-09-04T09:00:00Z' }))
    const rec = record(await loadGithub($, ref('https://github.com/acme/widgets/pull/42'), NOW))
    expect(rec.status).toBe('merged')
    expect(rec.isFrozen).toBe(true)
    expect(meta(rec, 'Merged')).toBe('2026-09-04')
  })

  test('a closed pull request is frozen', async () => {
    const { $ } = prWorld(pullView({ state: 'CLOSED', closedAt: '2026-09-04T09:00:00Z' }))
    const rec = record(await loadGithub($, ref('https://github.com/acme/widgets/pull/42'), NOW))
    expect(rec.status).toBe('closed')
    expect(rec.isFrozen).toBe(true)
  })

  test('214 comments show 165 to 214, oldest first, total 214', async () => {
    const { $ } = prWorld(pullView({ comments: conversation(214), reviews: [] }))
    const rec = record(await loadGithub($, ref('https://github.com/acme/widgets/pull/42'), NOW))
    expect(rec.comments?.total).toBe(214)
    expect(rec.comments?.shown.length).toBe(50)
    expect(rec.comments?.shown[0]?.body).toBe('comment 165')
    expect(rec.comments?.shown[49]?.body).toBe('comment 214')
  })

  test('the inline count failing does not fail the page', async () => {
    const { $ } = world(
      routes({
        'pr view 42': () => ok(pullView()),
        'api repos/acme/widgets/pulls/42': () => exited(1, '', 'HTTP 502 bad gateway'),
      }),
    )
    const rec = record(await loadGithub($, ref('https://github.com/acme/widgets/pull/42'), NOW))
    expect(rec.comments?.inline).toBeUndefined()
  })

  test('"Could not resolve to a PullRequest" is not-found-or-no-access', async () => {
    const { $ } = world(
      routes({
        'pr view 42': () => exited(1, '', 'GraphQL: Could not resolve to a PullRequest with the number of 42. (repository.pullRequest)'),
        'api repos/acme/widgets/pulls/42': () => exited(1, '', 'gh: Not Found (HTTP 404)'),
      }),
    )
    expect(await loadGithub($, ref('https://github.com/acme/widgets/pull/42'), NOW)).toEqual({ ok: false, failure: 'not-found-or-no-access' })
  })

  test('a failed issue-or-PR check fails the page with its kind', async () => {
    const { $ } = world(routes({ 'api repos/acme/widgets/issues/9': () => exited(1, '', 'gh: Not Found (HTTP 404)') }))
    expect(await loadGithub($, ref('acme/widgets#9'), NOW)).toEqual({ ok: false, failure: 'not-found-or-no-access' })
  })
})

describe('CI summary', () => {
  test('12 successful, 1 failed, 2 running, 1 cancelled', () => {
    expect(ciSummary(checks({ passed: 12, failed: 1, running: 2, cancelled: 1 }), 'MERGEABLE', 'OPEN')).toBe(
      '12 passed · 1 failed · 2 pending · 1 cancelled',
    )
  })

  test('covers AE3: open, conflicting, nothing ran', () => {
    expect(ciSummary([], 'CONFLICTING', 'OPEN')).toBe('checks not running: merge conflict')
  })

  test('an empty rollup on a mergeable open pull request', () => {
    expect(ciSummary([], 'MERGEABLE', 'OPEN')).toBe('no checks reported')
  })

  test('open with mergeability unknown and nothing ran reads computing', () => {
    expect(ciSummary([], 'UNKNOWN', 'OPEN')).toBe('computing')
  })

  test('merged with mergeable UNKNOWN still draws its 30 checks', async () => {
    expect(ciSummary(checks({ passed: 30 }), 'UNKNOWN', 'MERGED')).toBe('30 passed')
    const { $ } = prWorld(pullView({ state: 'MERGED', mergeable: 'UNKNOWN', mergedAt: '2026-09-04T09:00:00Z', statusCheckRollup: checks({ passed: 30 }) }))
    expect(record(await loadGithub($, ref('https://github.com/acme/widgets/pull/42'), NOW)).stats?.ci).toBe('30 passed')
  })

  test('nothing ran never reads as passing, even when merged', () => {
    expect(ciSummary([], 'UNKNOWN', 'MERGED')).toBe('no checks reported')
    expect(ciSummary(undefined, 'CONFLICTING', 'CLOSED')).toBe('no checks reported')
  })

  test('status contexts, neutral, skipped and unknown values', () => {
    const rollup = [
      { __typename: 'StatusContext', context: 'ci/legacy', state: 'SUCCESS' },
      { __typename: 'StatusContext', context: 'ci/other', state: 'ERROR' },
      { __typename: 'StatusContext', context: 'ci/wait', state: 'PENDING' },
      { __typename: 'CheckRun', status: 'COMPLETED', conclusion: 'NEUTRAL' },
      { __typename: 'CheckRun', status: 'COMPLETED', conclusion: 'SKIPPED' },
      { __typename: 'CheckRun', status: 'COMPLETED', conclusion: 'TIMED_OUT' },
      { __typename: 'CheckRun', status: 'QUEUED', conclusion: 'SUCCESS' },
      { __typename: 'CheckRun', status: 'COMPLETED', conclusion: 'SOMETHING_NEW' },
    ]
    expect(ciSummary(rollup, 'MERGEABLE', 'OPEN')).toBe('1 passed · 2 failed · 3 pending · 2 skipped')
  })
})

describe('repo page', () => {
  function repoWorld(readme: () => ProcessRunResult) {
    return world(
      routes({
        'repo view acme/widgets': () => ok(repoView),
        'api repos/acme/widgets/readme': readme,
        'pr list': () => ok(pullList),
        'issue list': () => ok(issueList),
      }),
    )
  }

  test('README body, metadata and open lists newest update first', async () => {
    const { $, calls } = repoWorld(() => ok('# Widgets\n\nHello.'))
    const rec = record(await loadGithub($, ref('https://github.com/acme/widgets'), NOW))
    expect(rec.kind).toBe('gh-repo')
    expect(rec.trail).toEqual(['acme'])
    expect(rec.title).toBe('widgets')
    expect(rec.body).toBe('# Widgets\n\nHello.')
    expect(meta(rec, 'Language')).toBe('TypeScript')
    expect(meta(rec, 'Default branch')).toBe('main')
    const [pulls, issues] = rec.lists ?? []
    expect(pulls?.heading).toBe('Pull requests')
    expect(pulls?.total).toBe(41)
    expect(pulls?.items.map(item => item.href)).toEqual(['https://github.com/acme/widgets/pull/41', 'https://github.com/acme/widgets/pull/40'])
    expect(pulls?.items[0]?.status).toBe('draft')
    expect(issues?.heading).toBe('Issues')
    expect(issues?.total).toBe(57)
    expect(issues?.items[0]?.href).toBe('https://github.com/acme/widgets/issues/7')
    const listCall = calls.find(args => args[0] === 'pr' && args[1] === 'list') ?? []
    expect(listCall).toContain('30')
    expect(listCall).toContain('open')
  })

  test('a repo with no README draws metadata and lists with no body', async () => {
    const { $ } = repoWorld(() => exited(1, '', 'gh: Not Found (HTTP 404)'))
    const loaded = await loadGithub($, ref('https://github.com/acme/widgets'), NOW)
    const rec = record(loaded)
    expect(rec.body).toBeUndefined()
    expect(meta(rec, 'Description')).toBe('Widgets for everyone')
    expect(rec.lists?.length).toBe(2)
  })

  test('the repo view failing fails the page', async () => {
    const { $ } = world(routes({ 'repo view': () => exited(1, '', 'GraphQL: Could not resolve to a Repository with the name') }))
    expect(await loadGithub($, ref('https://github.com/acme/widgets'), NOW)).toEqual({ ok: false, failure: 'not-found-or-no-access' })
  })
})

describe('fromCapture', () => {
  function captured(over: Partial<Captured>): Captured {
    return { address: 'https://github.com/acme/widgets/pull/42', kind: 'gh-pr', source: 'mcp', tool: 'pull_request_read', args: {}, result: '{}', at: NOW - 1000, ...over }
  }

  test('a GitHub MCP pull request with no labels or milestone still normalises', () => {
    const loaded = fromCapture(captured({ result: JSON.stringify(mcpPullRead) }), ref('https://github.com/acme/widgets/pull/42'), NOW)
    expect(loaded?.ok && loaded.tier).toBe('session')
    const rec = record(loaded as Loaded)
    expect(rec.kind).toBe('gh-pr')
    expect(rec.title).toContain('Teach the parser trailing commas')
    expect(rec.trail).toEqual(['acme', 'widgets'])
    expect(rec.status).toBe('open')
    expect(meta(rec, 'Author')).toBe('octo')
    expect(meta(rec, 'Labels')).toBeUndefined()
    expect(rec.stats?.additions).toBe(120)
    expect(rec.stats?.changedFiles).toBe(4)
  })

  test('a Bash-captured gh pr view normalises like a live load', () => {
    const view = pullView({ state: 'MERGED', mergedAt: '2026-09-04T09:00:00Z' })
    const loaded = fromCapture(captured({ source: 'bash', tool: 'Bash', result: JSON.stringify(view) }), ref('https://github.com/acme/widgets/pull/42'), NOW)
    const rec = record(loaded as Loaded)
    expect(rec.status).toBe('merged')
    expect(rec.isFrozen).toBe(true)
    expect(rec.stats?.ci).toBe('3 passed')
  })

  test('a gh-number capture with PR-only fields becomes a pull request', () => {
    const loaded = fromCapture(
      captured({ kind: 'gh-number', address: 'https://github.com/acme/widgets/issues/42', result: JSON.stringify(mcpPullRead) }),
      ref('acme/widgets#42'),
      NOW,
    )
    const rec = record(loaded as Loaded)
    expect(rec.kind).toBe('gh-pr')
    expect(rec.address).toBe('https://github.com/acme/widgets/pull/42')
  })

  test('a captured gh issue view of a merged pull request reads as a merged pull request', () => {
    const view = { number: 1, title: 'interactive pr list', state: 'MERGED', author: { login: 'v' }, comments: [] }
    const loaded = fromCapture(
      captured({ kind: 'gh-issue', address: 'https://github.com/acme/widgets/issues/1', source: 'bash', tool: 'Bash', result: JSON.stringify(view) }),
      ref('https://github.com/acme/widgets/issues/1'),
      NOW,
    )
    const rec = record(loaded as Loaded)
    expect(rec.kind).toBe('gh-pr')
    expect(rec.status).toBe('merged')
    expect(rec.isFrozen).toBe(true)
    expect(rec.stats).toBeUndefined()
  })

  test('a REST issue capture normalises', () => {
    const rest = { number: 7, title: 'Parser drops trailing comma', state: 'closed', user: { login: 'r' }, labels: [{ name: 'bug' }], created_at: '2026-08-01T10:00:00Z', closed_at: '2026-08-09T00:00:00Z' }
    const loaded = fromCapture(
      captured({ kind: 'gh-issue', address: 'https://github.com/acme/widgets/issues/7', tool: 'issue_read', result: JSON.stringify(rest) }),
      ref('https://github.com/acme/widgets/issues/7'),
      NOW,
    )
    const rec = record(loaded as Loaded)
    expect(rec.kind).toBe('gh-issue')
    expect(rec.status).toBe('closed')
    expect(rec.isFrozen).toBe(true)
    expect(meta(rec, 'Labels')).toBe('bug')
  })

  test('no title or unparseable text normalises to null', () => {
    expect(fromCapture(captured({ result: '{"number":1}' }), ref('https://github.com/acme/widgets/pull/42'), NOW)).toBe(null)
    expect(fromCapture(captured({ result: 'not json' }), ref('https://github.com/acme/widgets/pull/42'), NOW)).toBe(null)
  })

  test('a captured repo view normalises', () => {
    const loaded = fromCapture(
      captured({ kind: 'gh-repo', address: 'https://github.com/acme/widgets', source: 'bash', tool: 'Bash', result: JSON.stringify(repoView) }),
      ref('https://github.com/acme/widgets'),
      NOW,
    )
    const rec = record(loaded as Loaded)
    expect(rec.kind).toBe('gh-repo')
    expect(rec.title).toBe('widgets')
  })
})
