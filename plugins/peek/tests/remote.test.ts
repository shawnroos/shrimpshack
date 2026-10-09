import { describe, expect, test } from 'claude-code/testing'
import type { ProcessRunResult } from 'claude-code'

import { record } from '../hooks/capture'
import { parseRef } from '../hooks/refs'
import type { Ref } from '../hooks/refs'
import { loadItem } from '../hooks/remote'
import type { RemoteIo } from '../hooks/remote'

let sessions = 0

function io(options: { ghAuthExit?: number; gh?: (argv: readonly string[]) => string; ghStderr?: string; mcp?: () => string } = {}) {
  const session = `remote-${++sessions}`
  const mcpCalls: { server: string; tool: string; args: Record<string, unknown> }[] = []
  const exited = (exitCode: number, stdout = '', stderr = ''): ProcessRunResult =>
    ({ exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false }) as ProcessRunResult
  const port: RemoteIo = {
    sessionId: async () => session,
    run: async argv => {
      if (argv[0] === 'sh') return exited(0, 'gh\ncurl\n')
      if (argv[0] === 'gh' && argv[1] === 'auth') return exited(options.ghAuthExit ?? 0)
      if (argv[0] === 'gh' && options.ghStderr) return exited(1, '', options.ghStderr)
      if (argv[0] === 'gh' && options.gh) return exited(0, options.gh(argv))
      return exited(1, '', 'nope')
    },
    fetch: async () => ({ status: 404, ok: false, headers: {}, text: '' }) as never,
    linearKeyEnv: async () => undefined,
    home: async () => '/home/u',
    read: async path => {
      throw new Error(`ENOENT ${path}`)
    },
    sleep: async () => undefined,
    mcpCall: async (server, tool, args) => {
      mcpCalls.push({ server, tool, args })
      return { content: [{ type: 'text', text: options.mcp?.() ?? '{}' }], isError: false }
    },
    now: async () => 5_000,
  }
  return { port, mcpCalls }
}

const ref = (text: string): Ref => {
  const found = parseRef(text)
  if (!found) throw new Error(`no ref for ${text}`)
  return found
}

const PR_JSON = JSON.stringify({ number: 77, title: 'Ship it', state: 'OPEN', url: 'https://github.com/o/r/pull/77' })

describe('loadItem picks the best tier', () => {
  test('gh answers: the page comes from tier 1', async () => {
    const { port } = io({
      gh: argv => (argv.includes('view') ? PR_JSON : argv.includes('api') ? '{"review_comments":0}' : '[]'),
    })
    const loaded = await loadItem(port, ref('https://github.com/o/r/pull/77'), 1_000)
    expect(loaded.ok && loaded.tier).toBe('cli')
    expect(loaded.ok && loaded.record.title).toBe('#77 Ship it')
    expect(loaded.ok && loaded.liveFailure).toBeUndefined()
  })

  test('gh signed out and a captured gh result: the page comes from this session', async () => {
    record({ tool: 'Bash', command: 'gh pr view 78 --repo o/r --json title,state' }, { result: { stdout: PR_JSON.replace('77', '78') }, text: PR_JSON.replace('77', '78') }, 900)
    const { port } = io({ ghAuthExit: 1 })
    const loaded = await loadItem(port, ref('o/r#78'), 1_000)
    expect(loaded.ok && loaded.tier).toBe('session')
    expect(loaded.ok && loaded.fetchedAt).toBe(900)
    expect(loaded.ok && loaded.liveFailure).toBe('cli-unauthed')
  })

  test('gh rate-limited and a captured result: the page says live was rate-limited, so refresh keeps backing off', async () => {
    record({ tool: 'Bash', command: 'gh pr view 80 --repo o/r --json title,state' }, { result: { stdout: PR_JSON.replace('77', '80') }, text: PR_JSON.replace('77', '80') }, 900)
    const { port } = io({ ghStderr: 'HTTP 403: API rate limit exceeded for user' })
    const loaded = await loadItem(port, ref('https://github.com/o/r/pull/80'), 1_000)
    expect(loaded.ok && loaded.tier).toBe('session')
    expect(loaded.ok && loaded.liveFailure).toBe('rate-limited')
  })

  test('a replayed MCP read after a live failure carries the live failure too', async () => {
    const issue = { identifier: 'WEB-2760', title: 'Replayed', url: 'https://linear.app/acme/issue/WEB-2760/replayed' }
    record({ tool: 'mcp__claude_ai_Linear__get_issue', id: 'WEB-2760' }, { result: { content: [{ type: 'text', text: JSON.stringify(issue) }] } }, 800)
    const { port, mcpCalls } = io({ mcp: () => JSON.stringify(issue) })
    const loaded = await loadItem(port, ref('https://linear.app/acme/issue/WEB-2760'), 1_000, { canReplay: true })
    expect(mcpCalls.length).toBe(1)
    expect(loaded.ok && loaded.liveFailure).toBe('key-missing')
  })

  test('gh signed out and nothing captured: the failure kind comes through', async () => {
    const { port } = io({ ghAuthExit: 1 })
    expect(await loadItem(port, ref('o/r#79'), 1_000)).toEqual({ ok: false, failure: 'cli-unauthed' })
  })

  test('covers AE4 and AE5: no Linear key, a captured MCP read draws, and refresh replays it', async () => {
    const issue = { identifier: 'WEB-2757', title: 'Remove Logo', url: 'https://linear.app/acme/issue/WEB-2757/remove-logo' }
    record({ tool: 'mcp__claude_ai_Linear__get_issue', id: 'WEB-2757' }, { result: { content: [{ type: 'text', text: JSON.stringify(issue) }] } }, 800)
    const { port, mcpCalls } = io({ mcp: () => JSON.stringify({ ...issue, title: 'Remove Logo v2' }) })
    const first = await loadItem(port, ref('https://linear.app/acme/issue/WEB-2757'), 1_000)
    expect(first.ok && first.tier).toBe('session')
    expect(mcpCalls).toEqual([])
    const again = await loadItem(port, ref('https://linear.app/acme/issue/WEB-2757'), 61_000, { canReplay: true })
    expect(mcpCalls).toEqual([{ server: 'claude_ai_Linear', tool: 'get_issue', args: { id: 'WEB-2757' } }])
    expect(again.ok && again.record.title).toContain('Remove Logo v2')
  })
})
