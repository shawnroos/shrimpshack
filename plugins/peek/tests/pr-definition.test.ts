import { expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { C } from '../hooks/theme'
import { GH_PR_DEFINITION } from './fixtures/github/gh-pr-definition'
import { issueView, pullView } from './fixtures/github/items'
import { PR_BASELINE } from './fixtures/github/pr-baseline'
import { exited } from './fixtures/results'
import { PANE_PROPS, baseWorld, fakeHttp, fakeProcess } from './fixtures/world'

const NOW = 10 * 3600_000
const FENCE = '```'
const USER_VIEWS = '/home/.local/share/claude-peek/views'

type PageWorld = { pull?: Record<string, unknown>; definition?: string; userDefinition?: string }

function pageWorld(on: On, options: PageWorld = {}) {
  on('session.id', () => ({ value: 'pr-definition' }))
  baseWorld(on)
  fakeHttp(on)
  on('clock.now', () => ({ value: NOW }))
  const files = new Map<string, string>()
  const fileAt = (path: string) => {
    if (path === `${USER_VIEWS}/gh-pr.md`) return options.userDefinition
    return path.endsWith('/views/gh-pr.md') ? options.definition : undefined
  }
  on('fs.stat', (_$, e) => {
    const text = fileAt(e.path)
    if (text !== undefined) return { value: { kind: 'file' as const, size: text.length, mtimeMs: text.length, isLink: false } }
    throw new Error(`ENOENT ${e.path}`)
  })
  on('fs.list', (_$, e) => {
    if (fileAt(`${e.path}/gh-pr.md`) !== undefined) return { value: [{ name: 'gh-pr.md', kind: 'file' as const, size: 1, mtimeMs: 1, isLink: false }] }
    throw new Error(`ENOENT ${e.path}`)
  })
  on('fs.read', (_$, e) => {
    const text = fileAt(e.path) ?? files.get(e.path)
    if (text !== undefined) return { value: text }
    throw new Error(`ENOENT ${e.path}`)
  })
  fakeProcess(on, argv => {
    const ok = (stdout: string) => exited(0, stdout)
    const line = argv.join(' ')
    if (argv[0] === 'sh') return ok('gh\ncurl\n')
    if (line === 'gh auth status') return ok('')
    if (line.startsWith('gh api repos/acme/widgets/issues/42')) return ok(JSON.stringify({ number: 42, pull_request: {} }))
    if (line.startsWith('gh api repos/acme/widgets/issues/7')) return ok(JSON.stringify({ number: 7 }))
    if (line.startsWith('gh pr view 42')) return ok(JSON.stringify(pullView({ mergeable: 'CONFLICTING', statusCheckRollup: [], body: 'Follows #45. [tick](file:///Users/me/notes.md#task-3)', ...options.pull })))
    if (line.startsWith('gh api repos/acme/widgets/pulls/42')) return ok('2')
    if (line.startsWith('gh issue view 7')) return ok(JSON.stringify(issueView()))
    return exited(1, '', 'unexpected')
  })
}

const PULL = 'https://github.com/acme/widgets/pull/42'
const ISSUE = 'https://github.com/acme/widgets/issues/7'

// Each state is one page the PR drawing must keep; the issue page is here to show it does not move.
const STATES: Record<string, { href: string; pull?: Record<string, unknown>; isMenuOpen?: boolean }> = {
  default: { href: PULL },
  menu: { href: PULL, isMenuOpen: true },
  'no-stats': { href: PULL, pull: { additions: undefined } },
  pictures: {
    href: PULL,
    pull: {
      body: 'Before.\n\n![shot](https://cdn.test/body.png)\n\nAfter.',
      comments: [{ author: { login: 'a' }, body: 'Here:\n\n![later](https://cdn.test/comment.png)', createdAt: '2026-09-01T11:00:00Z' }],
    },
  },
  'unclosed-fence': { href: PULL, pull: { body: `Intro.\n\n${FENCE}ts\nconst open = 1\n\nstill code` } },
  'two-fences': { href: PULL, pull: { body: `${FENCE}ts\nconst a = 1\n${FENCE}\n\n${FENCE}ts\nconst b = 2\n${FENCE}\n` } },
  'no-comments': { href: PULL, pull: { comments: [], reviews: [], body: '' } },
  issue: { href: ISSUE },
}

const SURFACES = ['terminal', 'desktop'] as const
const WIDTHS = [100, 70] as const

async function sha(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text))
  return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('')
}

// Press handles are numbered per run, so they are blanked before the tree is compared.
const treeOf = async (ui: { drawn: () => Promise<unknown> }) => JSON.stringify(await ui.drawn()).replace(/"handle":\d+/g, '"handle":0')

type Node = { props?: { key?: unknown }; children?: unknown[] }

// The baseline holds the page body only (the box of block-N parts), so a change to the tabs, crumbs or footer keys
// elsewhere in the pane does not read as a change to the PR drawing.
function bodyOf(node: unknown): unknown {
  if (typeof node !== 'object' || node === null) return undefined
  const children = (node as Node).children ?? []
  if (children.some(child => (child as Node)?.props?.key === 'block-0')) return node
  for (const child of children) {
    const found = bodyOf(child)
    if (found) return found
  }
  return undefined
}

const bodyTreeOf = async (ui: { drawn: () => Promise<unknown> }) => JSON.stringify(bodyOf(await ui.drawn()) ?? null).replace(/"handle":\d+/g, '"handle":0')

type Mounted = { drawn: () => Promise<unknown>; find: (q: { text?: RegExp | string; key?: string }) => Promise<{ props: Record<string, unknown> } | undefined>; unmount: () => Promise<void> }
type Run = { command: { run: (input: never) => Promise<unknown> }; ui: { mount: (input: never) => Promise<unknown> } }

async function openPage($: Run, href: string, width = 100): Promise<Mounted> {
  await $.command.run({ command: 'peek', args: href } as never)
  return (await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: { ...PANE_PROPS, bodyColumns: width }, requestId: 'peek' } as never)) as Mounted
}

for (const [name, state] of Object.entries(STATES)) {
  for (const source of ['views/gh-pr.md', 'no definition'] as const) {
    test(`covers AE7: the ${name} page with ${source} draws the baseline tree on terminal and desktop at two widths`, async ($, on) => {
      pageWorld(on, { ...(state.pull ? { pull: state.pull } : {}), ...(source === 'views/gh-pr.md' ? { definition: GH_PR_DEFINITION } : {}) })
      await $.command.run({ command: 'peek', args: state.href } as never)
      if (state.isMenuOpen) await $.command.run({ command: 'peek-menu' } as never)
      const got: Record<string, string> = {}
      for (const surface of SURFACES) {
        for (const width of WIDTHS) {
          const ui = await $.ui.mount({ plugin: 'peek', surface, component: 'Pane', props: { ...PANE_PROPS, bodyColumns: width }, requestId: 'peek' })
          got[`${surface}-${width}`] = await sha(await bodyTreeOf(ui))
          await ui.unmount()
        }
      }
      expect(got).toEqual(PR_BASELINE[name] ?? {})
    })
  }
}

const withoutBlock = (language: string, from: string) => GH_PR_DEFINITION.replace(`${FENCE}${language} from=${from}`, `${FENCE}text from=${from}`)

test('a PR with no stats draws no Changes block, and one with pictures draws its media embed', async ($, on) => {
  pageWorld(on, { definition: GH_PR_DEFINITION, pull: { additions: undefined, body: 'Before.\n\n![shot](https://cdn.test/body.png)' } })
  const ui = await openPage($, PULL)
  expect(await ui.find({ text: /^DETAILS$/ })).toBeDefined()
  expect(await ui.find({ text: /^CHANGES$/ })).toBeUndefined()
  expect(await ui.find({ text: /^IMAGE$/ })).toBeDefined()
  expect(await ui.find({ text: /^ shot$/ })).toBeDefined()
  await ui.unmount()
})

test('the PR page path has no PR-specific drawing: removing a block from views/gh-pr.md removes it from the page', async ($, on) => {
  pageWorld(on, { definition: withoutBlock('peek-fields', 'stats') })
  const ui = await openPage($, PULL)
  expect(await ui.find({ text: /^DETAILS$/ })).toBeDefined()
  expect(await ui.find({ text: /^CHANGES$/ })).toBeUndefined()
  expect(await ui.find({ text: /^\+120$/ })).toBeUndefined()
  expect(await ui.find({ text: /^COMMENTS $/ })).toBeDefined()
  await ui.unmount()
})

test('the PR page draws its blocks in the order views/gh-pr.md lists them', async ($, on) => {
  const comments = `${FENCE}peek-comments from=comments title=Comments\n${FENCE}\n`
  const details = `${FENCE}peek-fields from=meta`
  pageWorld(on, { definition: GH_PR_DEFINITION.replace(comments, '').replace(details, `${comments}\n${details}`) })
  const ui = await openPage($, PULL)
  const tree = await treeOf(ui)
  expect(tree.indexOf('COMMENTS')).toBeGreaterThan(-1)
  expect(tree.indexOf('COMMENTS')).toBeLessThan(tree.indexOf('DETAILS'))
  await ui.unmount()
})

test('the details icons and the CI color come from the frontmatter maps of views/gh-pr.md', async ($, on) => {
  const changed = GH_PR_DEFINITION.replace(/\n {2}author: [^\n]+/, '\n  author: A').replace('bad: red', 'bad: blue')
  pageWorld(on, { definition: changed })
  const ui = await openPage($, PULL)
  expect(await ui.find({ text: /^A +$/ })).toBeDefined()
  expect((await ui.find({ text: /^checks not running: merge conflict$/ }))?.props.color).toBe(C.blue)
  await ui.unmount()
})

test('a PR body with an unclosed code fence still draws the comments below it', async ($, on) => {
  pageWorld(on, { definition: GH_PR_DEFINITION, pull: { body: `Intro.\n\n${FENCE}ts\nconst open = 1\n\nstill code` } })
  const ui = await openPage($, PULL)
  const tree = await treeOf(ui)
  expect(await ui.find({ text: /^COMMENTS $/ })).toBeDefined()
  expect(await ui.find({ key: 'comment-0-body-md-0' })).toBeDefined()
  expect(tree.indexOf('const open = 1')).toBeGreaterThan(-1)
  expect(tree.indexOf('const open = 1')).toBeLessThan(tree.indexOf('COMMENTS'))
  await ui.unmount()
})

test('a user definition that clashes with gh-pr names both files on the page, which still draws', async ($, on) => {
  pageWorld(on, { definition: GH_PR_DEFINITION, userDefinition: GH_PR_DEFINITION })
  const ui = await openPage($, PULL)
  expect(await ui.find({ text: /^\/home\/\.local\/share\/claude-peek\/views\/gh-pr\.md: type "gh-pr" is also defined by \S+\/views\/gh-pr\.md; neither loads$/ })).toBeDefined()
  expect(await ui.find({ text: /\/views\/gh-pr\.md: type "gh-pr" is also defined by \/home\/\.local\/share\/claude-peek\/views\/gh-pr\.md; neither loads$/ })).toBeDefined()
  expect(await ui.find({ text: /^DETAILS$/ })).toBeDefined()
  expect(await ui.find({ text: /^COMMENTS $/ })).toBeDefined()
  await ui.unmount()
})
