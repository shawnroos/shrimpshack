import { describe, expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { capturedLinearContext, isReadCall, lookup, record, replay } from '../hooks/capture'

const ISSUE_JSON = JSON.stringify({ id: 'uuid-1', identifier: 'WEB-2757', title: 'Remove Logo', url: 'https://linear.app/acme/issue/WEB-2757/remove-logo' })

describe('isReadCall', () => {
  test('Linear and GitHub read tools pass; writes do not', () => {
    expect(isReadCall('mcp__claude_ai_Linear__get_issue', { id: 'WEB-1' })).toBe(true)
    expect(isReadCall('mcp__linear__list_issues', {})).toBe(true)
    expect(isReadCall('mcp__claude_ai_Github__pull_request_read', { method: 'get' })).toBe(true)
    expect(isReadCall('mcp__claude_ai_Github__issue_read', {})).toBe(true)
    expect(isReadCall('mcp__claude_ai_Github__search_issues', {})).toBe(true)
    expect(isReadCall('mcp__claude_ai_Linear__save_comment', {})).toBe(false)
    expect(isReadCall('mcp__claude_ai_Github__merge_pull_request', {})).toBe(false)
    expect(isReadCall('mcp__claude_ai_Github__issue_write', {})).toBe(false)
    expect(isReadCall('mcp__claude_ai_Gmail__get_message', {})).toBe(false)
    expect(isReadCall('WebFetch', { url: 'https://example.com' })).toBe(true)
  })

  test('only a single plain read-only gh command counts', () => {
    const bash = (command: string) => isReadCall('Bash', { command })
    expect(bash('gh pr view 12 --repo o/r --json title,state')).toBe(true)
    expect(bash('gh issue list -R o/r --json number')).toBe(true)
    expect(bash('gh repo view o/r --json name')).toBe(true)
    expect(bash('gh api repos/o/r/pulls/1')).toBe(true)
    expect(bash('gh pr view 12 --repo o/r')).toBe(false)
    expect(bash('gh api -X POST repos/o/r/issues')).toBe(false)
    expect(bash('gh api --method=PATCH repos/o/r/issues/1')).toBe(false)
    expect(bash('gh api repos/o/r/issues -f title=x')).toBe(false)
    expect(bash('gh api repos/o/r/issues --input body.json')).toBe(false)
    expect(bash('gh pr merge 12 --repo o/r')).toBe(false)
    expect(bash('gh pr view 1 --json x && rm -rf /')).toBe(false)
    expect(bash('gh pr view 1 --json x; rm -rf /')).toBe(false)
    expect(bash('gh pr view 1 --json x | cat')).toBe(false)
    expect(bash('gh pr view $(echo 1) --json x')).toBe(false)
    expect(bash('gh pr view `echo 1` --json x')).toBe(false)
  })
})

// The test file gets its own instance of capture.ts, not the loaded plugin's,
// so the store is driven through `record` and the hook is read through state.
function fakeIo(replayed: unknown[], text: string, isError = false) {
  return {
    mcpCall: async (server: string, tool: string, args: Record<string, unknown>) => {
      replayed.push({ server, tool, args })
      return { content: [{ type: 'text', text }], isError }
    },
    now: async () => 9_000,
  }
}

const at = 5_000
const reply = (text: string) => ({ result: [{ type: 'text', text }], text })

describe('the tool.call hook', () => {
  test('a read call passes through unchanged and its addresses land in Recent as artifacts; a write call records nothing', async ($, on) => {
    const writes: { value?: { href: string; isArtifact?: boolean }[] }[] = []
    on('clock.now', () => ({ value: at }))
    on('state.set', (_$, e) => {
      if ((e as { key?: string }).key === 'mentions') writes.push(e as never)
      return { value: { isSet: true as const, version: writes.length } }
    })
    const list = JSON.stringify([{ url: 'https://linear.app/acme/issue/WEB-1/a' }, { url: 'https://github.com/o/r/pull/3' }])
    // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc
    on('tool.call', async (_$, e) => ((e as { tool: string }).tool.endsWith('save_comment') ? reply('saved https://linear.app/acme/issue/WEB-9') : reply(list)) as never)
    const answer = await $.tool.call({ tool: 'mcp__claude_ai_Linear__list_issues', tool_use_id: 't1', team: 'WEB' } as never)
    expect(answer).toEqual(reply(list))
    const hrefs = writes.at(-1)?.value ?? []
    expect(hrefs.find(one => one.href === 'https://linear.app/acme/issue/WEB-1')?.isArtifact).toBe(true)
    expect(hrefs.find(one => one.href === 'https://github.com/o/r/pull/3')?.isArtifact).toBe(true)
    const before = writes.length
    await $.tool.call({ tool: 'mcp__claude_ai_Linear__save_comment', tool_use_id: 't2', issueId: 'WEB-9', body: 'x' } as never)
    expect(writes.length).toBe(before)
  })

  test('a failing capture never fails the tool call', async ($, on) => {
    on('clock.now', () => {
      throw new Error('no clock')
    })
    // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc
    on('tool.call', async () => reply(ISSUE_JSON) as never)
    const answer = await $.tool.call({ tool: 'mcp__claude_ai_Linear__get_issue', tool_use_id: 't3', id: 'WEB-2757' } as never)
    expect(answer).toEqual(reply(ISSUE_JSON))
  })
})

describe('the capture store', () => {
  test('a Linear get_issue is stored under the issue address, seeds the team-key allowlist, and replays without reserved keys', async () => {
    const input = { tool: 'mcp__claude_ai_Linear__get_issue', tool_use_id: 'toolu_1', agentId: 'a1', consent: 'yes', id: 'WEB-2757' }
    const noted = record(input, reply(ISSUE_JSON), at)
    expect(noted.addresses).toEqual(['https://linear.app/acme/issue/WEB-2757'])
    expect(noted.grewLinear).toBe(true)

    const hit = lookup('https://linear.app/acme/issue/WEB-2757')
    expect(hit?.tool).toBe('get_issue')
    expect(hit?.server).toBe('claude_ai_Linear')
    expect(hit?.source).toBe('mcp')
    expect(hit?.kind).toBe('linear-issue')
    expect(hit?.result).toBe(ISSUE_JSON)
    expect(hit?.args).toEqual({ id: 'WEB-2757' })

    const context = capturedLinearContext()
    expect(context.workspace).toBe('acme')
    expect(context.teamKeys).toContain('WEB')
    expect(record(input, reply(ISSUE_JSON), at).grewLinear).toBe(false)

    const replayed: unknown[] = []
    const fresher = ISSUE_JSON.replace('Remove Logo', 'Remove the logo')
    const again = await replay(fakeIo(replayed, fresher), 'https://linear.app/acme/issue/WEB-2757')
    expect(again?.result).toBe(fresher)
    expect(again?.at).toBe(9_000)
    expect(replayed).toEqual([{ server: 'claude_ai_Linear', tool: 'get_issue', args: { id: 'WEB-2757' } }])
    expect(await replay(fakeIo([], 'oops', true), 'https://linear.app/acme/issue/WEB-2757')).toBeNull()
    expect(lookup('https://linear.app/acme/issue/WEB-2757')?.result).toBe(fresher)
  })

  test('once the allowlist knows the team, a get_issue with no url in its result still resolves', () => {
    record({ tool: 'mcp__linear__get_issue', id: 'WEB-31' }, reply('{"title":"no url"}'), at)
    expect(lookup('https://linear.app/acme/issue/WEB-31')?.server).toBe('linear')
  })

  test('a gh pr view through Bash is stored under the PR address and settles #142 as a pull request', async () => {
    const out = '{"title":"Fix","state":"OPEN"}'
    record({ tool: 'Bash', command: 'gh pr view 142 --repo o/r --json title,state' }, { result: { stdout: out, stderr: '', interrupted: false }, text: out }, at)
    const hit = lookup('https://github.com/o/r/pull/142')
    expect(hit?.source).toBe('bash')
    expect(hit?.result).toBe(out)
    expect(lookup('https://github.com/o/r/issues/142')?.kind).toBe('gh-pr')
    expect(await replay(fakeIo([], out), 'https://github.com/o/r/pull/142')).toBeNull()
  })

  test('GitHub MCP reads key by owner, repo and number', () => {
    record({ tool: 'mcp__claude_ai_Github__issue_read', method: 'get', owner: 'o', repo: 'r', issue_number: 55 }, reply('{}'), at)
    record({ tool: 'mcp__claude_ai_Github__pull_request_read', method: 'get', owner: 'o', repo: 'r', pullNumber: 56 }, reply('{}'), at)
    expect(lookup('https://github.com/o/r/issues/55')?.kind).toBe('gh-issue')
    expect(lookup('https://github.com/o/r/pull/56')?.kind).toBe('gh-pr')
  })

  test('an errored call, a write tool and a write or chained gh command store nothing', async () => {
    const none = { addresses: [], grewLinear: false }
    expect(record({ tool: 'mcp__claude_ai_Github__pull_request_read', method: 'get', owner: 'o', repo: 'r', pullNumber: 7 }, { isError: true, text: 'boom' }, at)).toEqual(none)
    expect(lookup('https://github.com/o/r/pull/7')).toBeNull()
    expect(record({ tool: 'mcp__claude_ai_Linear__save_comment', issueId: 'WEB-2758', body: 'hi' }, reply(ISSUE_JSON), at)).toEqual(none)
    expect(record({ tool: 'mcp__claude_ai_Github__merge_pull_request', owner: 'o', repo: 'r', pullNumber: 8 }, reply('merged'), at)).toEqual(none)
    expect(lookup('https://github.com/o/r/pull/8')).toBeNull()
    expect(record({ tool: 'Bash', command: 'gh api -X POST repos/o/r/issues/9' }, reply('{}'), at)).toEqual(none)
    expect(lookup('https://github.com/o/r/issues/9')).toBeNull()
    expect(record({ tool: 'Bash', command: 'gh pr view 10 --repo o/r --json x && rm -rf /' }, reply('{}'), at)).toEqual(none)
    expect(lookup('https://github.com/o/r/pull/10')).toBeNull()
    expect(await replay(fakeIo([], 'x'), 'https://github.com/o/r/pull/8')).toBeNull()
  })

  test('a list_issues result naming 30 issues makes them mentions, not page sources, and evicts nothing', () => {
    const issue = JSON.stringify({ identifier: 'OPS-1', url: 'https://linear.app/acme/issue/OPS-1/one' })
    const list = JSON.stringify(Array.from({ length: 30 }, (_, i) => ({ identifier: `OPS-${i + 100}`, url: `https://linear.app/acme/issue/OPS-${i + 100}/x` })))
    record({ tool: 'mcp__claude_ai_Linear__get_issue', id: 'OPS-1' }, reply(issue), at)
    const noted = record({ tool: 'mcp__claude_ai_Linear__list_issues', team: 'OPS' }, reply(list), at)
    expect(noted.addresses.length).toBe(30)
    expect(noted.addresses).toContain('https://linear.app/acme/issue/OPS-129')
    expect(lookup('https://linear.app/acme/issue/OPS-1')?.tool).toBe('get_issue')
    expect(lookup('https://linear.app/acme/issue/OPS-100')).toBeNull()
    expect(lookup('https://linear.app/acme/issue/OPS-129')).toBeNull()
  })

  test('a WebFetch capture is stored but never replayed', async () => {
    record({ tool: 'WebFetch', url: 'https://example.com/cats#top', prompt: 'summarise' }, { result: { result: 'A page about cats' }, text: 'A page about cats' }, at)
    const hit = lookup('https://example.com/cats')
    expect(hit?.source).toBe('webfetch')
    expect(hit?.result).toBe('A page about cats')
    expect(await replay(fakeIo([], 'x'), 'https://example.com/cats')).toBeNull()
  })

  test('the store evicts the oldest entry past 200', () => {
    for (let n = 1; n <= 201; n++) record({ tool: 'mcp__claude_ai_Github__issue_read', method: 'get', owner: 'evict', repo: 'r', issue_number: n }, reply('{}'), at)
    expect(lookup('https://github.com/evict/r/issues/1')).toBeNull()
    expect(lookup('https://github.com/evict/r/issues/2')?.kind).toBe('gh-issue')
    expect(lookup('https://github.com/evict/r/issues/201')?.kind).toBe('gh-issue')
  })
})
