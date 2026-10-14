import { expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { pullView } from './fixtures/github/items'
import { exited } from './fixtures/results'
import { PANE_PROPS, baseWorld, fakeHttp, fakeProcess } from './fixtures/world'

const SHARED = [
  '## Shared part',
  '',
  'Intro with **bold** and `code`.',
  '',
  '> a quoted line',
  '',
  // After prose, not after a fence: linkify's splitFences drops the newlines between two fences one blank line
  // apart, so on a remote body the second fence never opens.
  '```peek-list status=todo',
  '```',
  '',
  '| Step | Days |',
  '|---|---:|',
  '| Build | 3 |',
  '',
  '- bullet one',
  '  - nested bullet',
  '',
  '```ts',
  'const x = 1',
  '```',
  '',
  '### End mark',
].join('\n')

const FILE = '/repo/notes/shared.md'

function fakeWorld(on: On) {
  baseWorld(on)
  fakeHttp(on)
  on('clock.now', () => ({ value: 10 * 3600_000 }))
  on('session.id', () => ({ value: 'pane-parity' }))
  fakeProcess(on, argv => {
    const line = argv.join(' ')
    if (argv[0] === 'git' && argv.includes('rev-parse')) return exited(0, '/repo\n/repo/.git\n/repo/.git\n')
    if (argv[0] === 'sh') return exited(0, line.includes('command -v') ? 'gh\ncurl\n' : '')
    if (line === 'gh auth status') return exited(0, '')
    if (line.startsWith('gh api repos/acme/widgets/issues/42')) return exited(0, JSON.stringify({ number: 42, pull_request: {} }))
    if (line.startsWith('gh pr view 42')) return exited(0, JSON.stringify(pullView({ statusCheckRollup: [], body: SHARED })))
    if (line.startsWith('gh api repos/acme/widgets/pulls/42')) return exited(0, '0')
    return exited(1, '', 'unexpected')
  })
  on('fs.stat', (_$, e) => {
    if (e.path === FILE) return { value: { kind: 'file' as const, size: SHARED.length, mtimeMs: 8 * 3600_000, isLink: false } }
    if (FILE.startsWith(`${e.path}/`)) return { value: { kind: 'dir' as const, size: 0, mtimeMs: 8 * 3600_000, isLink: false } }
    throw new Error(`ENOENT ${e.path}`)
  })
  on('fs.list', () => ({ value: [] }))
  on('fs.read', (_$, e) => {
    if (e.path === FILE) return { value: SHARED }
    throw new Error(`ENOENT ${e.path}`)
  })
}

type Node = { type?: string; props?: Record<string, unknown>; children?: unknown[] }

// What a reader sees, in order: each Text's words, each Markdown's source, each Code block's source.
function seen(node: unknown, out: string[] = []): string[] {
  if (!node || typeof node !== 'object') return out
  const { type, props = {}, children = [] } = node as Node
  if (type === 'Text') {
    const words = (function flat(list: unknown[]): string {
      return list.map(one => (typeof one === 'string' ? one : flat((one as Node).children ?? []))).join('')
    })(children)
    if (words.trim()) out.push(words)
    return out
  }
  if (type === 'Markdown') out.push(`md:${String(props.text)}`)
  if (type === 'Code') out.push(`code:${String(props.source)}`)
  for (const child of children) seen(child, out)
  return out
}

function sharedSlice(tree: unknown): string[] {
  const all = seen(tree)
  const start = all.findIndex(one => one.startsWith('SHARED PART'))
  const end = all.findIndex(one => one.endsWith('End mark'))
  return start >= 0 && end > start ? all.slice(start, end + 1) : []
}

test('the same markdown draws the same parts on a file page and in a pull request body', async ($, on) => {
  fakeWorld(on)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: PANE_PROPS, requestId: 'peek' })
  await $.command.run({ command: 'peek', args: FILE } as never)
  await ui.redraw()
  const onFile = sharedSlice(await ui.drawn())

  await $.command.run({ command: 'peek', args: 'https://github.com/acme/widgets/pull/42' } as never)
  await ui.redraw()
  const inPull = sharedSlice(await ui.drawn())

  expect(onFile.length).toBeGreaterThan(8)
  expect(onFile).toContain('⏵ ')
  expect(onFile).toContain('code:const x = 1')
  // No page hands blocks an item source yet, so a collection block draws its empty row on both pages.
  expect(onFile).toContain('no items · status=todo')
  expect(inPull).toEqual(onFile)
  await ui.unmount()
})
