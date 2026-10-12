import { describe, expect, test } from 'claude-code/testing'

import { record } from '../hooks/capture'
import { loadItem } from '../hooks/remote'
import type { RemoteIo } from '../hooks/remote'
import { exited, ref } from './fixtures/results'

let sessions = 0

function io(options: { ghAuthExit?: number; gh?: (argv: readonly string[]) => string; ghStderr?: string; mcp?: () => string; images?: Record<string, number> } = {}) {
  const session = `remote-${++sessions}`
  const mcpCalls: { server: string; tool: string; args: Record<string, unknown> }[] = []
  const downloads: string[] = []
  const port: RemoteIo = {
    sessionId: async () => session,
    run: async argv => {
      if (argv[0] === 'sh') return exited(0, 'gh\ncurl\n')
      if (argv[0] === 'gh' && argv[1] === 'auth') return exited(options.ghAuthExit ?? 0)
      if (argv[0] === 'gh' && options.ghStderr) return exited(1, '', options.ghStderr)
      if (argv[0] === 'gh' && options.gh) return exited(0, options.gh(argv))
      if (argv[0] === 'mkdir') return exited(0)
      if (argv[0] === '/usr/bin/dscacheutil') return exited(0, 'ip_address: 93.184.216.34\n')
      if (argv[0] === 'curl' && argv.includes('-o')) {
        const url = argv[argv.length - 1] ?? ''
        downloads.push(url)
        return options.images?.[url] === 200 ? exited(0, '200 512 ') : exited(22, '404 0 ')
      }
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
  return { port, mcpCalls, downloads }
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

describe('media in GitHub and Linear markdown', () => {
  const youtube = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ'
  const attachment = 'https://github.com/user-attachments/assets/0b1c2d3e-aaaa-bbbb-cccc-1234567890ab'
  const prBody = [
    'Intro.',
    '',
    '![shot](https://cdn.test/a.png)',
    '',
    '<img width="320" alt="ui" src="https://cdn.test/b.png" />',
    '',
    youtube,
    '',
    attachment,
  ].join('\n')
  const pr = (body: string, comments: { body: string }[]) =>
    JSON.stringify({ number: 77, title: 'Ship it', state: 'OPEN', url: 'https://github.com/o/r/pull/77', body, comments: comments.map((one, i) => ({ author: { login: `u${i}` }, createdAt: `2026-09-0${i + 1}T00:00:00Z`, ...one })) })

  test('pictures in the body and comments of a pull request download; videos get a play link; a failed download stays a link', async () => {
    const { port, downloads } = io({
      gh: argv => (argv.includes('view') ? pr(prBody, [{ body: 'Look:\n\n![c](https://cdn.test/c.png)' }]) : argv.includes('api') ? '0' : '[]'),
      images: { 'https://cdn.test/a.png': 200, 'https://cdn.test/c.png': 200, 'https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg': 200 },
    })
    const loaded = await loadItem(port, ref('https://github.com/o/r/pull/77'), 1_000)
    if (!loaded.ok) throw new Error(loaded.failure)
    const { record } = loaded
    const media = record.media ?? {}
    expect(media['https://cdn.test/a.png']?.file?.startsWith('/tmp/claude-peek/web-')).toBe(true)
    expect(record.body?.includes('![ui](https://cdn.test/b.png)')).toBe(true)
    expect(record.body?.includes('<img')).toBe(false)
    expect(media['https://cdn.test/b.png']).toBeDefined()
    expect(media['https://cdn.test/b.png']?.file).toBeUndefined()
    expect(media[youtube]?.play).toBe(youtube)
    expect(media[youtube]?.file?.startsWith('/tmp/claude-peek/')).toBe(true)
    expect(media[attachment]?.play).toBe(attachment)
    expect(media['https://cdn.test/c.png']?.file?.startsWith('/tmp/claude-peek/web-')).toBe(true)
    expect(record.comments?.shown.some(one => one.body.includes('![c](https://cdn.test/c.png)'))).toBe(true)
    expect(downloads).toContain('https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg')
    expect(downloads.includes(attachment)).toBe(false)
  })

  test('one cap covers the body and every comment, and pictures past it stay as links', async () => {
    const pics = (from: number) => Array.from({ length: 6 }, (_, i) => `![p${from + i}](https://cdn.test/p${from + i}.png)`).join('\n\n')
    const images = Object.fromEntries(Array.from({ length: 12 }, (_, i) => [`https://cdn.test/p${i}.png`, 200]))
    const { port, downloads } = io({
      gh: argv => (argv.includes('view') ? pr(pics(0), [{ body: pics(6) }]) : argv.includes('api') ? '0' : '[]'),
      images,
    })
    const loaded = await loadItem(port, ref('https://github.com/o/r/pull/77'), 1_000)
    if (!loaded.ok) throw new Error(loaded.failure)
    expect(downloads.filter(url => url.startsWith('https://cdn.test/p')).length).toBe(8)
    expect(loaded.record.comments?.shown[0]?.body.includes('![p11](https://cdn.test/p11.png)')).toBe(true)
    expect(loaded.record.media?.['https://cdn.test/p11.png']?.file).toBeUndefined()
  })

  test('a picture in a captured Linear description downloads too', async () => {
    const issue = { identifier: 'WEB-2770', title: 'Pictures', description: 'See:\n\n![mock](https://uploads.linear.app/x/mock.png)', url: 'https://linear.app/acme/issue/WEB-2770/pictures' }
    record({ tool: 'mcp__claude_ai_Linear__get_issue', id: 'WEB-2770' }, { result: { content: [{ type: 'text', text: JSON.stringify(issue) }] } }, 800)
    const { port } = io({ images: { 'https://uploads.linear.app/x/mock.png': 200 } })
    const loaded = await loadItem(port, ref('https://linear.app/acme/issue/WEB-2770'), 1_000)
    if (!loaded.ok) throw new Error(loaded.failure)
    expect(loaded.record.media?.['https://uploads.linear.app/x/mock.png']?.file?.startsWith('/tmp/claude-peek/web-')).toBe(true)
  })

  test('a picture on a private address is never fetched', async () => {
    const { port, downloads } = io({ gh: argv => (argv.includes('view') ? pr('![x](http://127.0.0.1/x.png)', []) : argv.includes('api') ? '0' : '[]') })
    const loaded = await loadItem(port, ref('https://github.com/o/r/pull/77'), 1_000)
    if (!loaded.ok) throw new Error(loaded.failure)
    expect(downloads).toEqual([])
    expect(loaded.record.media?.['http://127.0.0.1/x.png']?.file).toBeUndefined()
  })

  test('a repo README keeps its badges as text: only issues, pull requests and Linear items get media', async () => {
    const readme = '# Widgets\n\n![Build](https://img.shields.io/badge/build-passing-green) ![License](https://img.shields.io/badge/license-MIT-blue)\n'
    const repo = JSON.stringify({ nameWithOwner: 'o/r', description: 'Widgets', url: 'https://github.com/o/r', defaultBranchRef: { name: 'main' } })
    const { port, downloads } = io({
      gh: argv => (argv.includes('view') ? repo : argv.some(arg => arg.includes('readme')) ? readme : '[]'),
      images: { 'https://img.shields.io/badge/build-passing-green': 200 },
    })
    const loaded = await loadItem(port, ref('https://github.com/o/r'), 1_000)
    if (!loaded.ok) throw new Error(loaded.failure)
    expect(loaded.record.body).toContain('shields.io')
    expect(loaded.record.media).toBeUndefined()
    expect(downloads).toEqual([])
  })
})
