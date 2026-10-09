import { describe, expect, test } from 'claude-code/testing'
import type { HttpInit, HttpResponse, ProcessRunResult } from 'claude-code'

import type { Captured } from '../hooks/capture'
import { bootstrapLinear, fromCapture, loadLinear } from '../hooks/linear'
import { parseRef } from '../hooks/refs'
import type { Ref } from '../hooks/refs'
import type { SourceIo } from '../hooks/sources'
import type { Loaded, RemoteRecord } from '../types'
import { ISSUE_NO_PROJECT, ISSUE_WITH_PROJECT, PROJECT, openIssue } from './fixtures/linear/api'
import { MCP_ISSUE, MCP_PROJECT } from './fixtures/linear/mcp'

const NOW = 1_760_000_000_000
let sessions = 0

type Sent = { query: string; variables: Record<string, unknown> }
type Reply = (sent: Sent) => unknown

function exited(exitCode: number, stdout = ''): ProcessRunResult {
  return { exitCode, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false }
}

function json(status: number, body: unknown): HttpResponse {
  return { status, ok: status >= 200 && status < 300, headers: {}, text: JSON.stringify(body) }
}

function world(reply: Reply, hasKey = true) {
  const session = `linear-${++sessions}`
  const sent: Sent[] = []
  const io: SourceIo = {
    sessionId: async () => session,
    run: async argv => {
      if (argv[0] === '/usr/bin/security') return hasKey ? exited(0, 'lin_api_FAKE\n') : exited(44)
      if (argv[0] === 'sh') return exited(0, 'gh\ncurl\n')
      return exited(0)
    },
    fetch: async (_url: string, init?: HttpInit) => {
      const body = JSON.parse(String(init?.body ?? '{}')) as Sent
      sent.push(body)
      const answer = reply(body)
      return answer && typeof answer === 'object' && 'status' in answer && 'text' in answer ? (answer as HttpResponse) : json(200, { data: answer })
    },
    linearKeyEnv: async () => undefined,
    home: async () => undefined,
    read: async () => {
      throw new Error('ENOENT')
    },
    sleep: async () => {},
  }
  return { io, sent }
}

function ref(text: string): Ref {
  const found = parseRef(text)
  if (!found) throw new Error(`bad ref ${text}`)
  return found
}

function record(loaded: Loaded | null): RemoteRecord {
  if (!loaded || !loaded.ok) throw new Error(`not loaded: ${JSON.stringify(loaded)}`)
  return loaded.record
}

function meta(rec: RemoteRecord, label: string): string | undefined {
  return rec.meta.find(entry => entry.label === label)?.value
}

function issueWorld(issue: unknown) {
  return world(({ query }) => (query.includes('issue(id') ? { issue } : null))
}

describe('Linear issues', () => {
  test('an issue with a project and parent draws trail [team, project] and the identifier in the title', async () => {
    const { io, sent } = issueWorld(ISSUE_WITH_PROJECT)
    const loaded = await loadLinear(io, ref('https://linear.app/acme/issue/WEB-2757'), NOW)
    const rec = record(loaded)
    expect(loaded.ok && loaded.tier).toBe('api')
    expect(loaded.ok && loaded.fetchedAt).toBe(NOW)
    expect(rec.trail).toEqual(['Web', 'Brand refresh'])
    expect(rec.title).toBe('WEB-2757 Remove Logo')
    expect(rec.address).toBe('https://linear.app/acme/issue/WEB-2757')
    expect(rec.kind).toBe('linear-issue')
    expect(rec.status).toBe('In Progress')
    expect(rec.isFrozen).toBe(false)
    expect(rec.body).toBe('The logo should go.')
    expect(meta(rec, 'State')).toBe('In Progress')
    expect(meta(rec, 'Assignee')).toBe('Ada Lovelace')
    expect(meta(rec, 'Labels')).toBe('Bug, Editor')
    expect(meta(rec, 'Priority')).toBe('High')
    expect(meta(rec, 'Project')).toBe('Brand refresh')
    expect(meta(rec, 'Milestone')).toBe('Beta')
    expect(meta(rec, 'Parent')).toBe('WEB-2700 Logo cleanup')
    expect(meta(rec, 'Created')).toBe('2026-10-01')
    expect(meta(rec, 'Updated')).toBe('2026-10-05')
    expect(sent[0]?.variables).toEqual({ id: 'WEB-2757' })
    expect(sent[0]?.query).toContain('comments(last: 50)')
  })

  test('an issue with no project draws trail [team], and a completed one is frozen', async () => {
    const { io } = issueWorld(ISSUE_NO_PROJECT)
    const rec = record(await loadLinear(io, ref('https://linear.app/acme/issue/WEB-12'), NOW))
    expect(rec.trail).toEqual(['Web'])
    expect(rec.isFrozen).toBe(true)
    expect(meta(rec, 'Assignee')).toBe('Unassigned')
    expect(meta(rec, 'Priority')).toBeUndefined()
    expect(meta(rec, 'Labels')).toBeUndefined()
    expect(meta(rec, 'Completed')).toBe('2026-09-02')
    expect(rec.body).toBeUndefined()
  })

  test('a reply comment draws one level under its parent', async () => {
    const { io } = issueWorld(ISSUE_WITH_PROJECT)
    const rec = record(await loadLinear(io, ref('https://linear.app/acme/issue/WEB-2757'), NOW))
    expect(rec.comments?.total).toBe(3)
    expect(rec.comments?.shown.map(c => [c.author, c.body, c.depth ?? 0])).toEqual([
      ['Ada Lovelace', 'First thought', 0],
      ['Grace', 'A reply', 1],
      ['Linus', 'Second thread', 0],
    ])
    expect(rec.comments?.shown[0]?.at).toBe('2026-10-02T10:00:00.000Z')
  })

  test('more than 50 comments counts the full total', async () => {
    const many = {
      ...ISSUE_WITH_PROJECT,
      comments: {
        nodes: Array.from({ length: 50 }, (_, i) => ({ id: `c${i + 70}`, body: `n${i}`, createdAt: new Date(NOW + i * 1000).toISOString(), user: { name: 'A' }, parent: null })),
        pageInfo: { hasPreviousPage: true },
      },
    }
    const { io } = world(({ query, variables }) => {
      if (query.includes('issue(id') && !query.includes('$first')) return { issue: many }
      const start = variables.after ? Number(variables.after) : 0
      const size = Math.min(50, 120 - start)
      return {
        issue: {
          comments: {
            nodes: Array.from({ length: size }, (_, i) => ({ id: `x${start + i}` })),
            pageInfo: { hasNextPage: start + size < 120, endCursor: String(start + size) },
          },
        },
      }
    })
    const rec = record(await loadLinear(io, ref('https://linear.app/acme/issue/WEB-2757'), NOW))
    expect(rec.comments?.shown.length).toBe(50)
    expect(rec.comments?.total).toBe(120)
  })

  test('an ID Linear cannot find is not-found-or-no-access', async () => {
    const { io } = world(() => json(200, { data: null, errors: [{ message: 'Entity not found: Issue', extensions: { code: 'INPUT_ERROR' } }] }))
    expect(await loadLinear(io, ref('https://linear.app/other/issue/ZZQ-9'), NOW)).toEqual({ ok: false, failure: 'not-found-or-no-access' })
  })

  test('an issue the key resolves in a different workspace is not-found-or-no-access', async () => {
    const { io } = issueWorld(ISSUE_WITH_PROJECT)
    expect(await loadLinear(io, ref('https://linear.app/elsewhere/issue/WEB-2757'), NOW)).toEqual({ ok: false, failure: 'not-found-or-no-access' })
  })

  test('a null issue is not-found-or-no-access', async () => {
    const { io } = issueWorld(null)
    expect(await loadLinear(io, ref('https://linear.app/acme/issue/WEB-1'), NOW)).toEqual({ ok: false, failure: 'not-found-or-no-access' })
  })
})

describe('Linear projects', () => {
  function projectWorld(open: number) {
    return world(({ query, variables }) => {
      if (!query.includes('$first')) return { project: PROJECT }
      const start = variables.after ? Number(variables.after) : 0
      const size = Math.min(50, open - start)
      return {
        project: {
          issues: {
            nodes: Array.from({ length: size }, (_, i) => openIssue(start + i + 1)),
            pageInfo: { hasNextPage: start + size < open, endCursor: String(start + size) },
          },
        },
      }
    })
  }

  test('a project with 120 open issues pages to all 120 and is not partial', async () => {
    const { io, sent } = projectWorld(120)
    const rec = record(await loadLinear(io, ref('https://linear.app/acme/project/brand-refresh-1a2b3c4d5e6f'), NOW))
    expect(sent[0]?.variables).toEqual({ id: '1a2b3c4d5e6f' })
    expect(sent.length).toBe(4)
    expect(sent[1]?.variables).toEqual({ id: '1a2b3c4d5e6f', first: 50, after: null })
    expect(sent[1]?.query).toContain('nin: ["completed", "canceled"]')
    const list = rec.lists?.[0]
    expect(list?.heading).toBe('Issues')
    expect(list?.items.length).toBe(120)
    expect(list?.total).toBe(120)
    expect(list?.isPartial).toBe(false)
    expect(list?.items[0]).toEqual({ href: 'https://linear.app/acme/issue/WEB-1', title: 'WEB-1 Open issue 1', status: 'Todo', meta: 'Ada Lovelace' })
    expect(rec.title).toBe('Brand refresh')
    expect(rec.trail).toEqual(['Web'])
    expect(rec.body).toBe('# Brand refresh\n\nThe long description.')
    expect(rec.status).toBe('In Progress')
    expect(rec.isFrozen).toBe(false)
    expect(meta(rec, 'Status')).toBe('In Progress')
    expect(meta(rec, 'Lead')).toBe('Ada Lovelace')
    expect(meta(rec, 'Start')).toBe('2026-09-01')
    expect(meta(rec, 'Target')).toBe('2026-12-01')
    expect(meta(rec, 'Progress')).toBe('43%')
  })

  test('past 10 pages the list is partial', async () => {
    const { io } = projectWorld(600)
    const rec = record(await loadLinear(io, ref('https://linear.app/acme/project/brand-refresh-1a2b3c4d5e6f'), NOW))
    expect(rec.lists?.[0]?.items.length).toBe(500)
    expect(rec.lists?.[0]?.isPartial).toBe(true)
  })

  test('a missing project is not-found-or-no-access', async () => {
    const { io } = world(() => ({ project: null }))
    expect(await loadLinear(io, ref('https://linear.app/acme/project/gone-aaaaaaaaaaaa'), NOW)).toEqual({ ok: false, failure: 'not-found-or-no-access' })
  })
})

describe('Linear bootstrap', () => {
  test('loads the workspace slug and every team key', async () => {
    const { io } = world(({ query, variables }) => {
      if (query.includes('viewer')) return { viewer: { organization: { urlKey: 'acme' } } }
      return variables.after
        ? { teams: { nodes: [{ key: 'AI' }], pageInfo: { hasNextPage: false, endCursor: null } } }
        : { teams: { nodes: [{ key: 'WEB' }, { key: 'OPS' }], pageInfo: { hasNextPage: true, endCursor: 'p2' } } }
    })
    expect(await bootstrapLinear(io, NOW)).toEqual({ ok: true, workspace: 'acme', teamKeys: ['WEB', 'OPS', 'AI'], fetchedAt: NOW })
  })

  test('with no key the bootstrap fails, so with no captures no IDs link', async () => {
    const { io, sent } = world(() => ({}), false)
    const result = await bootstrapLinear(io, NOW)
    expect(result).toEqual({ ok: false, failure: 'key-missing' })
    expect(sent.length).toBe(0)
    const teamKeys = result.ok ? result.teamKeys : []
    expect(parseRef('WEB-2757', { workspace: 'acme', teamKeys })).toBeNull()
  })
})

describe('Linear captures', () => {
  function captured(address: string, kind: Captured['kind'], result: string, tool: string): Captured {
    return { address, kind, source: 'mcp', server: 'claude_ai_Linear', tool, args: {}, result, at: NOW - 5000 }
  }

  test('a captured MCP issue with null assignee and no labels normalises', () => {
    const address = 'https://linear.app/acme/issue/WEB-2757'
    const loaded = fromCapture(captured(address, 'linear-issue', MCP_ISSUE, 'get_issue'), ref(address), NOW)
    const rec = record(loaded)
    expect(loaded?.ok && loaded.tier).toBe('session')
    expect(loaded?.ok && loaded.fetchedAt).toBe(NOW - 5000)
    expect(rec.title).toBe('WEB-2757 Remove Logo')
    expect(rec.trail).toEqual(['Web', 'Brand refresh'])
    expect(rec.status).toBe('In Progress')
    expect(rec.isFrozen).toBe(false)
    expect(meta(rec, 'Assignee')).toBe('Unassigned')
    expect(meta(rec, 'Labels')).toBeUndefined()
    expect(meta(rec, 'Priority')).toBe('Medium')
    expect(meta(rec, 'Parent')).toBe('WEB-2700')
    expect(rec.comments).toBeUndefined()
  })

  test('a captured issue with 60 comments keeps the newest 50, oldest first, of 60', () => {
    const address = 'https://linear.app/acme/issue/WEB-2757'
    const comments = Array.from({ length: 60 }, (_, i) => ({ id: `c${i}`, body: `n${i}`, createdAt: new Date(NOW + i * 1000).toISOString(), user: 'A' }))
    const result = JSON.stringify({ ...JSON.parse(MCP_ISSUE), comments })
    const rec = record(fromCapture(captured(address, 'linear-issue', result, 'get_issue'), ref(address), NOW))
    expect(rec.comments?.total).toBe(60)
    expect(rec.comments?.shown.length).toBe(50)
    expect(rec.comments?.shown[0]?.body).toBe('n10')
    expect(rec.comments?.shown[49]?.body).toBe('n59')
  })

  test('a captured MCP project normalises', () => {
    const address = 'https://linear.app/acme/project/brand-refresh-1a2b3c4d5e6f'
    const rec = record(fromCapture(captured(address, 'linear-project', MCP_PROJECT, 'get_project'), ref(address), NOW))
    expect(rec.title).toBe('Brand refresh')
    expect(rec.trail).toEqual(['Web'])
    expect(rec.isFrozen).toBe(true)
    expect(meta(rec, 'Lead')).toBe('Ada Lovelace')
    expect(rec.body).toBeUndefined()
  })

  test('a result with no title or no JSON normalises to null', () => {
    const address = 'https://linear.app/acme/issue/WEB-1'
    expect(fromCapture(captured(address, 'linear-issue', '{"id":"WEB-1"}', 'get_issue'), ref(address), NOW)).toBeNull()
    expect(fromCapture(captured(address, 'linear-issue', 'not json', 'get_issue'), ref(address), NOW)).toBeNull()
  })
})
