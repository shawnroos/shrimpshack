import { describe, expect, test } from 'claude-code/testing'

import { lookup, record, replay } from '../hooks/capture'
import { mcpPullRead } from './fixtures/github/items'
import { MCP_ISSUE, MCP_PROJECT } from './fixtures/linear/mcp'
import { THREAD_RESULT } from './fixtures/slack/mcp'
import { RECORDED, REPLAYED } from './fixtures/capture-table'

const AT = 7_000
const reply = (text: string) => ({ result: [{ type: 'text', text }], text })
const bash = (stdout: string) => ({ result: { stdout, stderr: '', interrupted: false }, text: stdout })

type Row = { name: string; input: Record<string, unknown>; answer: unknown; stored?: string }

const ROWS: Row[] = [
  { name: 'Linear get_issue', input: { tool: 'mcp__claude_ai_Linear__get_issue', id: 'WEB-2757' }, answer: reply(MCP_ISSUE), stored: 'https://linear.app/acme/issue/WEB-2757' },
  { name: 'Linear get_project', input: { tool: 'mcp__claude_ai_Linear__get_project', query: 'Brand refresh' }, answer: reply(MCP_PROJECT), stored: 'https://linear.app/acme/project/brand-refresh-1a2b3c4d5e6f' },
  { name: 'Linear get_issue by bare key once the team is known', input: { tool: 'mcp__linear__get_issue', id: 'web-12' }, answer: reply('{"title":"no url"}'), stored: 'https://linear.app/acme/issue/WEB-12' },
  { name: 'Linear get_issue whose result names another issue', input: { tool: 'mcp__linear__get_issue', id: 'WEB-13' }, answer: reply(MCP_ISSUE), stored: 'https://linear.app/acme/issue/WEB-13' },
  { name: 'Linear server issue_read', input: { tool: 'mcp__claude_ai_Linear__issue_read', id: 'WEB-14' }, answer: reply('{}'), stored: 'https://linear.app/acme/issue/WEB-14' },
  { name: 'Linear list_issues', input: { tool: 'mcp__claude_ai_Linear__list_issues', team: 'WEB' }, answer: reply(JSON.stringify([{ url: 'https://linear.app/acme/issue/WEB-15/x' }])) },
  { name: 'GitHub MCP pull_request_read get', input: { tool: 'mcp__claude_ai_Github__pull_request_read', method: 'get', owner: 'acme', repo: 'widgets', pullNumber: 42 }, answer: reply(JSON.stringify(mcpPullRead)), stored: 'https://github.com/acme/widgets/pull/42' },
  { name: 'GitHub MCP issue_read get', input: { tool: 'mcp__claude_ai_Github__issue_read', method: 'get', owner: 'acme', repo: 'widgets', issue_number: 7 }, answer: reply('{"number":7}'), stored: 'https://github.com/acme/widgets/issues/7' },
  { name: 'GitHub MCP get_pull_request', input: { tool: 'mcp__github__get_pull_request', owner: 'acme', repo: 'widgets', pull_number: 43 }, answer: reply('{}'), stored: 'https://github.com/acme/widgets/pull/43' },
  { name: 'GitHub MCP get_issue on a pull number', input: { tool: 'mcp__github__get_pull_request_status', owner: 'acme', repo: 'widgets', issueNumber: 44 }, answer: reply('{}'), stored: 'https://github.com/acme/widgets/pull/44' },
  { name: 'GitHub MCP sub-method read', input: { tool: 'mcp__claude_ai_Github__pull_request_read', method: 'get_diff', owner: 'acme', repo: 'widgets', pullNumber: 45 }, answer: reply('see https://github.com/acme/widgets/pull/45') },
  { name: 'GitHub server slack_read_ tool', input: { tool: 'mcp__github__slack_read_thing', owner: 'acme', repo: 'widgets', pullNumber: 46 }, answer: reply('{}') },
  { name: 'Slack server get_ tool', input: { tool: 'mcp__plugin_slack_slack__get_item', owner: 'acme', repo: 'widgets', pullNumber: 47 }, answer: reply('{}'), stored: 'https://github.com/acme/widgets/pull/47' },
  { name: 'Slack read_thread', input: { tool: 'mcp__plugin_slack_slack__slack_read_thread', channel_id: 'C0123ABCD', message_ts: '1791759796.763609' }, answer: reply(THREAD_RESULT) },
  { name: 'unknown server get_ tool', input: { tool: 'mcp__claude_ai_Gmail__get_message', owner: 'acme', repo: 'widgets', pullNumber: 48 }, answer: reply('https://github.com/acme/widgets/pull/48') },
  { name: 'gh pr view', input: { tool: 'Bash', command: 'gh pr view 49 --repo acme/widgets --json title,state' }, answer: bash('{"title":"Fix"}'), stored: 'https://github.com/acme/widgets/pull/49' },
  { name: 'gh issue view', input: { tool: 'Bash', command: 'gh issue view 50 -R acme/widgets --json title' }, answer: bash('{"title":"Bug"}'), stored: 'https://github.com/acme/widgets/issues/50' },
  { name: 'gh api issue', input: { tool: 'Bash', command: 'gh api repos/acme/widgets/issues/51' }, answer: bash('{"number":51}') },
  { name: 'gh pr list', input: { tool: 'Bash', command: 'gh pr list --repo acme/widgets --json url' }, answer: bash('[{"url":"https://github.com/acme/widgets/pull/52"}]') },
  { name: 'WebFetch', input: { tool: 'WebFetch', url: 'https://example.com/page#top', prompt: 'x' }, answer: { result: { result: '# Page' }, text: '# Page' }, stored: 'https://example.com/page' },
  { name: 'an errored read', input: { tool: 'mcp__claude_ai_Github__issue_read', method: 'get', owner: 'acme', repo: 'widgets', issue_number: 53 }, answer: { isError: true, text: 'x' } },
  { name: 'a denied read', input: { tool: 'mcp__claude_ai_Github__issue_read', method: 'get', owner: 'acme', repo: 'widgets', issue_number: 54 }, answer: { deny: 'no' } },
]

function summary(row: Row) {
  const noted = record({ ...row.input, tool_use_id: 'x', agentId: 'a', consent: 'c' }, row.answer, AT)
  const addresses = [...new Set([...noted.addresses, ...(row.stored ? [row.stored] : [])])]
  return { noted, stored: Object.fromEntries(addresses.map(address => [address, lookup(address)])) }
}

describe('capture table', () => {
  test('each read call records the same addresses, Linear learning and stored entry', () => {
    for (const row of ROWS) expect({ name: row.name, ...summary(row) }).toEqual({ name: row.name, ...RECORDED[row.name as keyof typeof RECORDED] })
  })

  test('replay repeats each stored MCP read with its server, tool and args, and nothing else', async () => {
    for (const address of Object.keys(REPLAYED)) {
      const calls: unknown[] = []
      const io = {
        mcpCall: async (server: string, tool: string, args: Record<string, unknown>) => {
          calls.push({ server, tool, args })
          return { content: [{ type: 'text', text: `fresh ${tool}` }], isError: false }
        },
        now: async () => 9_000,
      }
      expect({ address, entry: await replay(io, address), calls }).toEqual({ address, ...REPLAYED[address as keyof typeof REPLAYED] })
    }
  })
})
