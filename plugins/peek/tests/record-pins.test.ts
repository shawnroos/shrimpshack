import { describe, expect, test } from 'claude-code/testing'

import type { Captured } from '../hooks/capture'
import { fromCapture as githubFromCapture } from '../hooks/github'
import { fromCapture as linearFromCapture } from '../hooks/linear'
import { htmlToMarkdown } from '../hooks/markdown'
import { parseThreadText } from '../hooks/parsers/slack-transcript'
import { mrkdwnToMarkdown, threadRecord } from '../hooks/slack'
import { parseHead } from '../hooks/web'
import { PINNED } from './fixtures/pinned-records'
import { MCP_ISSUE, MCP_PROJECT } from './fixtures/linear/mcp'
import { FILES_TEXT, THREAD_TEXT } from './fixtures/slack/mcp'
import { ref } from './fixtures/results'
import type { SlackThreadRef } from '../hooks/refs'

const PR = 'https://github.com/acme/widgets/pull/42'
const THREAD = 'https://acme.slack.com/archives/C0123ABCD/p1791759796763609'
const ENTITIES = 'A &amp;lt; B &#39;q&#39; &#x41;&#65; &nbsp;x &quot;y&quot; &apos;z&apos; &lt;t&gt; &#0; &#x110000;'

function ghCapture(view: unknown, over: Partial<Captured> = {}): Captured {
  return { address: PR, kind: 'gh-pr', source: 'bash', tool: 'Bash', args: {}, result: JSON.stringify(view), at: 5, ...over }
}

function slackRef(address: string): SlackThreadRef {
  const found = ref(address)
  if (found.kind !== 'slack-thread') throw new Error(`not a thread ${address}`)
  return found
}

function linearCapture(address: string, kind: Captured['kind'], result: string): Captured {
  return { address, kind, source: 'mcp', server: 'claude_ai_Linear', tool: 'get_issue', args: {}, result, at: 9 }
}

describe('GitHub records keep their exact shape', () => {
  test('a body and comments that start with indented code keep their leading whitespace', () => {
    const view = {
      number: 42,
      title: 'Indented',
      state: 'OPEN',
      author: { login: 'octo' },
      body: '    const x = 1\n    const y = 2\n\nprose',
      headRefName: 'feature',
      baseRefName: 'main',
      additions: 3,
      comments: [{ author: { login: 'a' }, body: '  indented reply', createdAt: '2026-09-01T00:00:00Z' }],
      reviews: [
        { author: { login: 'b' }, body: '   ', submittedAt: '2026-09-02T00:00:00Z' },
        { author: { login: 'c' }, body: '\tLGTM', submittedAt: '2026-09-03T00:00:00Z' },
      ],
    }
    expect(githubFromCapture(ghCapture(view), ref(PR))).toEqual(PINNED.prIndented)
  })

  test('a whitespace-only head branch wins over head.ref, and an untrimmed date is cut as-is', () => {
    const view = { number: 42, title: 'Blank branch', state: 'OPEN', headRefName: '   ', head: { ref: 'fallback' }, baseRefName: '', base: { ref: 'main' }, createdAt: '  2026-09-01T00:00:00Z' }
    expect(githubFromCapture(ghCapture(view), ref(PR))).toEqual(PINNED.wsBranch)
  })

  test('an empty head branch falls back to head.ref', () => {
    const view = { number: 42, title: 'Empty branch', state: 'OPEN', headRefName: '', head: { ref: 'from-head' }, base: { ref: 'main' } }
    expect(githubFromCapture(ghCapture(view), ref(PR))).toEqual(PINNED.emptyBranch)
  })

  test('a payload with no head object does not throw and counts missing numbers as 0', () => {
    const view = { number: 42, title: 'No head', state: 'open', user: { login: 'r' }, merged_at: null, draft: true, base: { ref: 'main' }, additions: 1, changed_files: 2 }
    expect(githubFromCapture(ghCapture(view), ref(PR))).toEqual(PINNED.noHead)
  })

  test('an issue keeps an untrimmed title and body and skips empty label names', () => {
    const issue = 'https://github.com/acme/widgets/issues/7'
    const view = {
      number: 7,
      title: '  Padded title  ',
      state: 'OPEN',
      user: { name: 'Named' },
      body: '  - indented list\n',
      labels: ['x', { name: '' }, { name: 'y' }],
      comments: [{ user: { login: 'z' }, body: '    code', created_at: '2026-08-01T00:00:00Z' }],
    }
    expect(githubFromCapture(ghCapture(view, { kind: 'gh-issue', address: issue }), ref(issue))).toEqual(PINNED.issueIndented)
  })
})

describe('Linear and Slack records keep their exact shape', () => {
  test('the MCP issue and project fixtures', () => {
    const issue = 'https://linear.app/acme/issue/WEB-2757'
    const project = 'https://linear.app/acme/project/brand-refresh-1a2b3c4d5e6f'
    expect(linearFromCapture(linearCapture(issue, 'linear-issue', MCP_ISSUE), ref(issue))).toEqual(PINNED.linearIssue)
    expect(linearFromCapture(linearCapture(project, 'linear-project', MCP_PROJECT), ref(project))).toEqual(PINNED.linearProject)
  })

  test('padded Linear strings are trimmed and blank ones dropped', () => {
    const address = 'https://linear.app/acme/issue/WEB-9'
    const result = JSON.stringify({
      title: '  Padded  ',
      identifier: '  ',
      id: 'web-9',
      state: { name: '  Todo ', type: ' unstarted ' },
      description: '   ',
      createdAt: '  2026-01-02T03:04:05Z',
      comments: [{ id: 'c1', body: '  hi  ', createdAt: '2026-01-03', user: { name: ' Ada ' } }],
    })
    expect(linearFromCapture(linearCapture(address, 'linear-issue', result), ref(address))).toEqual(PINNED.linearPadded)
  })

  test('the Slack thread and files fixtures', () => {
    const thread = parseThreadText(THREAD_TEXT)
    const files = parseThreadText(FILES_TEXT)
    if (!thread || !files) throw new Error('fixture did not parse')
    expect(threadRecord(slackRef(THREAD), { ...thread, hasMore: false }, 'general')).toEqual(PINNED.slackThread)
    expect(threadRecord(slackRef(THREAD), { ...files, hasMore: true }, undefined)).toEqual(PINNED.slackFiles)
  })
})

describe('each entity decoder keeps its own entity set', () => {
  test('Slack decodes only &lt; &gt; &amp;', () => {
    expect(mrkdwnToMarkdown(ENTITIES)).toBe(PINNED.mrkdwn)
    const parent = { author: 'A', ts: '1791759796.763609', text: ENTITIES, files: [] }
    expect(threadRecord(slackRef(THREAD), { parent, replies: [], hasMore: false }, 'g').title).toBe(PINNED.slackTitle)
  })

  test('a page head decodes numeric entities too', () => {
    expect(parseHead(`<html><head><title>${ENTITIES}</title></head></html>`, 'https://a.dev/').title).toBe(PINNED.headTitle)
  })

  test('htmlToMarkdown decodes its named set only', () => {
    expect(htmlToMarkdown(`<p>${ENTITIES}</p>`)).toBe(PINNED.htmlMd)
  })
})
