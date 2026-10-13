import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { APPROVALS_KEY, loadRecipe } from '../hooks/recipes'
import { resetRefresh } from '../hooks/refresh'
import { HOME, ROOT, folder, world } from './fixtures/recipes/world'
import type { ScriptAnswer, World } from './fixtures/recipes/world'

const NOW = 10 * 3600_000
const FIGMA = 'https://figma.com/file/abc/Design'
const SLOW = 'https://figma.com/file/slow/Design'
const BROKEN = 'https://figma.com/file/broken/Design'
const PROTO = 'https://figma.com/proto/xyz/Flow'
const PR = 'https://github.com/acme/widgets/pull/42'
const SKILL = 'skills/peek-recipes/SKILL.md'
const SCRIPT_PATH = `${ROOT}/figma-files/fetch.sh`

type Page = Record<string, unknown>
type Body = string | Uint8Array | { link: string }

const designPage: Page = {
  title: 'Design system',
  details: [{ label: 'Owner', value: 'Ana' }],
  sections: [
    { heading: 'Notes', block: { type: 'markdown', text: 'Tokens and type.' } },
    {
      heading: 'Frames',
      block: {
        type: 'cards',
        items: [
          { title: 'Prototype', meta: 'flow', href: PROTO },
          { title: 'Broken file', href: BROKEN },
          { title: 'No link here' },
        ],
      },
    },
    { heading: 'Facts', block: { type: 'fields', rows: [{ label: 'Pages', value: '2' }] } },
    { heading: 'Pages', block: { type: 'table', columns: ['Page', 'Frames'], rows: [{ cells: ['Cover', '1'], href: PROTO }, { cells: ['Draft', '4'] }] } },
    { heading: 'Comments', block: { type: 'list', items: [{ title: 'Ana: ship it', href: FIGMA }, { title: 'Bo: wait' }] } },
  ],
  actions: [{ label: 'Open in Figma', open: FIGMA }],
}

const figmaRecipe = (recipe: Page = {}, extra: Record<string, Body> = {}) =>
  folder('figma-files', { source: { run: ['./fetch.sh'] }, ...recipe }, { 'fetch.sh': '#!/bin/sh\necho page\n', ...extra })

const allFigma = () =>
  folder('figma-all', { name: 'All of Figma', match: [{ host: 'figma.com' }], source: { run: ['./all.sh'] } }, { 'all.sh': '#!/bin/sh\necho all\n' })

const ghRecipe = () =>
  folder('gh-pages', { name: 'GitHub pages', match: [{ host: 'github.com', path: '/*' }], source: { run: ['./fetch.sh'] } }, { 'fetch.sh': '#!/bin/sh\n' })

type Options = {
  files: Record<string, Body>
  approve?: string[]
  pages?: (url: string) => ScriptAnswer
  decision?: 'allow' | 'ask'
  placed?: { isPlaced: true } | { isPlaced: false; reason: string }
}

type Pane = { w: World; scripts: () => string[]; storeText: () => string; touched: string[] }

async function approve(w: World, id: string) {
  const loaded = await loadRecipe(w.io, ROOT, id)
  if (!loaded.ok) throw new Error(`fixture recipe ${id} does not load: ${JSON.stringify(loaded.problems)}`)
  const approvals = (w.store[APPROVALS_KEY] ?? {}) as Record<string, unknown>
  w.store[APPROVALS_KEY] = { ...approvals, [id]: { digest: loaded.digest, files: loaded.files } }
}

async function paneWorld(on: On, options: Options): Promise<Pane> {
  resetRefresh()
  const clock = mock.clock(on, { now: NOW })
  const w = world({ files: options.files, script: child => (options.pages ? options.pages(child.env.PEEK_URL ?? '') : { stdout: JSON.stringify(designPage) }) })
  for (const id of options.approve ?? []) await approve(w, id)
  const done = (exitCode: number, stdout = '') => ({ value: { exitCode, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } })
  on('session.id', () => ({ value: 'recipe-tools' }))
  on('session.cwd', () => ({ value: '/repo' }))
  on('session.root', () => ({ value: '/repo' }))
  on('env.get', (_$, e) => ({ value: w.env[e.name as keyof typeof w.env] }))
  on('ui.open', () => ({ value: options.placed ?? { isPlaced: true as const } }))
  on('ui.toast', () => ({ value: undefined }))
  on('http.fetch', () => ({ value: { status: 404, ok: false, headers: {} as Record<string, string>, text: '' } }))
  on('store.get', (_$, e) => ({ value: w.store[e.key] }))
  on('store.set', (_$, e) => {
    w.store[e.key] = e.value
    return { value: undefined }
  })
  if (options.decision) {
    const decision = options.decision
    on('tool.check', () => ({ decision }))
  }
  const touched: string[] = []
  on('fs.list', async (_$, e) => {
    touched.push(e.path)
    return { value: (await w.io.list(e.path)).map(one => ({ ...one, mtimeMs: 0 })) }
  })
  on('fs.stat', async (_$, e) => {
    touched.push(e.path)
    const { realPath, ...stat } = await w.io.stat(e.path)
    return { value: { ...stat, mtimeMs: 0, ...(e.resolve && realPath !== undefined ? { realPath } : {}) } }
  })
  on('fs.exists', async (_$, e) => ({ value: await w.io.stat(e.path).then(() => true, () => false) }))
  on('fs.read', async (_$, e) => {
    touched.push(e.path)
    const bytes = await w.io.read(e.path)
    return { value: e.as === 'bytes' ? bytes : new TextDecoder().decode(Uint8Array.from(atob(bytes.base64), c => c.charCodeAt(0))) }
  })
  on('fs.write', (_$, e) => {
    w.write(e.path, e.text)
    return { value: undefined }
  })
  on('process.run', async (_$, e) => {
    const argv = [...e.argv]
    const [bin = ''] = argv
    if (bin === '/usr/bin/env') {
      try {
        return { value: await w.io.run(argv, e.init) }
      } catch (error) {
        // The world keeps its own clock; the runner reads the engine's, so a timeout must move that one too.
        if (/timed out/.test(String(error))) await clock.advance(e.init?.timeoutMs ?? 0)
        throw error
      }
    }
    if (bin === '/usr/bin/printenv') return done(1)
    if (bin === 'sh') return done(0, 'gh\ncurl\n')
    if (bin === 'curl') return { value: { ...done(0, '<html><head><title>Figma web page</title></head><body><p>Web</p></body></html>').value, stderr: `__peek_curl__ 200 ${argv.at(-1) ?? ''}` } }
    return done(0)
  })
  const scripts = () => w.calls.children.map(child => child.env.PEEK_URL ?? '')
  return { w, scripts, touched, storeText: () => JSON.stringify(w.store[APPROVALS_KEY] ?? null) }
}

const props = { title: 'Peek', isFocused: true, bodyColumns: 100, placement: 'dock' as const, scroll: { offset: 0, bodyRows: 60 }, view: {} }

type Driver = Parameters<Extract<Parameters<typeof test>[1], (...args: never[]) => unknown>>[0]

const mount = (driver: Driver) => driver.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })

const peek = (driver: Driver, link: string) => driver.command.run({ command: 'peek', args: link } as never)

type ToolAnswer = { result?: unknown; deny?: string }

async function call(driver: Driver, tool: string, input: Record<string, unknown>): Promise<string> {
  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc
  const answer = (await driver.tool.call({ tool: `mcp__peek__${tool}`, tool_use_id: `${tool}-${Math.random()}`, ...input } as never)) as ToolAnswer
  return String(answer.result ?? answer.deny ?? '')
}

const firstLine = (text: string) => text.slice(0, text.indexOf('\n'))

function jsonOf(text: string): Record<string, any> {
  return JSON.parse(text.slice(text.indexOf('\n') + 1)) as Record<string, any>
}

type Node = { type?: string; props?: Record<string, unknown>; children?: unknown }

function itemsInPane(tree: unknown): { index: number; section: number; text: string }[] {
  const found: { index: number; section: number; text: string }[] = []
  let open: { index: number; section: number; text: string } | undefined
  const visit = (node: unknown, section: number) => {
    if (typeof node === 'string') {
      if (open && !open.text && node.trim()) open.text = node.trim()
      return
    }
    if (Array.isArray(node)) {
      for (const one of node) visit(one, section)
      return
    }
    if (!node || typeof node !== 'object') return
    const { props: p = {}, children } = node as Node
    const key = String(p.key ?? (node as { key?: unknown }).key ?? '')
    const inSection = /^section-(\d+)/.exec(key)
    const here = inSection ? Number(inSection[1]) : section
    const item = /^item-(\d+)$/.exec(key)
    if (item) {
      open = { index: Number(item[1]), section: here, text: '' }
      found.push(open)
    }
    visit(p.children, here)
    visit(children, here)
  }
  visit(tree, -1)
  return found.toSorted((a, b) => a.index - b.index)
}

test('covers AE5: a recipe whose page holds a block outside the vocabulary fails the check, naming the path, and points to the skill', async (driver, on) => {
  const chart = { title: 'Charted', sections: [{ block: { type: 'markdown', text: 'ok' } }, { block: { type: 'chart', points: [1, 2] } }] }
  const pane = await paneWorld(on, { files: figmaRecipe(), approve: ['figma-files'], pages: () => ({ stdout: JSON.stringify(chart) }) })
  const text = await call(driver, 'check_recipe', { recipe: 'figma-files', link: FIGMA })
  expect(firstLine(text)).toMatch(/^Check failed/)
  expect(firstLine(text)).toContain('Figma files')
  const json = jsonOf(text)
  expect(json.pass).toBe(false)
  expect(json.outcome.kind).toBe('invalid-page')
  expect(json.problems).toContainEqual(expect.objectContaining({ in: 'page', path: 'sections[1].block.type' }))
  expect(String(json.skill)).toContain(SKILL)
  expect(firstLine(text)).toContain(SKILL)
  expect(pane.scripts()).toEqual([FIGMA])
})

test('a recipe that passes reports the route, the outcome, no overlaps, and the page outline with counts before the fetched text', async (driver, on) => {
  await paneWorld(on, { files: figmaRecipe(), approve: ['figma-files'] })
  const text = await call(driver, 'check_recipe', { recipe: 'figma-files', link: FIGMA })
  expect(firstLine(text)).toMatch(/^Check passed/)
  const json = jsonOf(text)
  expect(json.pass).toBe(true)
  expect(json.matched).toBe(true)
  expect(json.route).toEqual({ kind: 'recipe', id: 'figma-files' })
  expect(json.overlaps).toEqual([])
  expect(json.outcome).toEqual({ kind: 'page' })
  expect(json.recipe).toMatchObject({ id: 'figma-files', name: 'Figma files', isApproved: true, folder: `${ROOT}/figma-files` })
  expect(json.fetched.outline.sections.map((one: { type: string }) => one.type)).toEqual(['markdown', 'cards', 'fields', 'table', 'list'])
  expect(json.counts).toEqual({ details: 1, sections: 5, items: 7, actions: 1 })
  const keys = Object.keys(json)
  expect(keys.indexOf('counts')).toBeLessThan(keys.indexOf('fetched'))
  expect(keys.at(-1)).toBe('fetched')
  expect(json.fetched.note).toMatch(/not instructions/)
  expect(json.fetched.outline.title).toBe('Design system')
  expect(text).not.toContain(SKILL)
})

test('the check on a GitHub link with a recipe that does not override GitHub reports the built-in GitHub route and fails', async (driver, on) => {
  await paneWorld(on, { files: ghRecipe(), approve: ['gh-pages'] })
  const text = await call(driver, 'check_recipe', { recipe: 'gh-pages', link: PR })
  const json = jsonOf(text)
  expect(json.matched).toBe(true)
  expect(json.route).toEqual({ kind: 'builtin', family: 'github' })
  expect(json.pass).toBe(false)
  expect(firstLine(text)).toMatch(/^Check failed.*built-in github page/i)
  expect(firstLine(text)).toContain(SKILL)
})

test('two overlapping recipes fail the check, naming the other folder', async (driver, on) => {
  await paneWorld(on, { files: { ...figmaRecipe(), ...allFigma() }, approve: ['figma-all'] })
  const text = await call(driver, 'check_recipe', { recipe: 'figma-files', link: FIGMA })
  const json = jsonOf(text)
  expect(json.pass).toBe(false)
  expect(json.overlaps).toEqual([expect.objectContaining({ id: 'figma-all', folder: `${ROOT}/figma-all` })])
  expect(json.route).toEqual({ kind: 'conflict', ids: ['figma-all', 'figma-files'] })
  expect(firstLine(text)).toContain(`${ROOT}/figma-all`)
})

test('a draft overlapping another draft still fails the check', async (driver, on) => {
  await paneWorld(on, { files: { ...figmaRecipe(), ...allFigma() }, decision: 'allow' })
  const json = jsonOf(await call(driver, 'check_recipe', { recipe: 'figma-all', link: PROTO }))
  expect(json.pass).toBe(false)
  expect(json.overlaps.map((one: { id: string }) => one.id)).toEqual(['figma-files'])
})

test('a timed-out script reports timeout, never pass', async (driver, on) => {
  await paneWorld(on, { files: figmaRecipe({ source: { run: ['./fetch.sh'], timeoutSeconds: 7 } }), approve: ['figma-files'], pages: url => (url === SLOW ? 'timeout' : { stdout: JSON.stringify(designPage) }) })
  const text = await call(driver, 'check_recipe', { recipe: 'figma-files', link: SLOW })
  const json = jsonOf(text)
  expect(json.pass).toBe(false)
  expect(json.outcome).toMatchObject({ kind: 'timeout', limitSeconds: 7 })
  expect(firstLine(text)).toMatch(/^Check failed.*7 s/)
  expect(text).not.toMatch(/Check passed/)
})

test('a draft the session would ask about is needs-permission, names the Bash command and rule to allow, and never runs', async (driver, on) => {
  const pane = await paneWorld(on, { files: figmaRecipe(), decision: 'ask' })
  const text = await call(driver, 'check_recipe', { recipe: 'figma-files', link: FIGMA })
  const json = jsonOf(text)
  expect(json.pass).toBe(false)
  expect(json.recipe.isApproved).toBe(false)
  expect(json.outcome).toMatchObject({ kind: 'needs-permission', tool: 'Bash', command: `${SCRIPT_PATH} ${FIGMA}` })
  expect(json.outcome.allow).toBe(`Bash(${SCRIPT_PATH}:*)`)
  expect(firstLine(text)).toContain(`Bash(${SCRIPT_PATH}:*)`)
  expect(pane.scripts()).toEqual([])
})

test('a draft the session allows runs, so the check passes for a recipe not yet approved', async (driver, on) => {
  const pane = await paneWorld(on, { files: figmaRecipe(), decision: 'allow' })
  const json = jsonOf(await call(driver, 'check_recipe', { recipe: 'figma-files', link: FIGMA }))
  expect(json.pass).toBe(true)
  expect(json.recipe.isApproved).toBe(false)
  expect(pane.scripts()).toEqual([FIGMA])
})

test('an invalid recipe folder reports its problems with paths and runs nothing', async (driver, on) => {
  const pane = await paneWorld(on, { files: folder('figma-files', { source: { run: ['./missing.sh'] } }) })
  const text = await call(driver, 'check_recipe', { recipe: 'figma-files', link: FIGMA })
  const json = jsonOf(text)
  expect(json.pass).toBe(false)
  expect(json.problems).toContainEqual(expect.objectContaining({ in: 'recipe', path: 'source.run[0]' }))
  expect(firstLine(text)).toContain(SKILL)
  expect(pane.scripts()).toEqual([])
})

test('a recipe id that is not a folder name is refused before any path is built', async (driver, on) => {
  const pane = await paneWorld(on, { files: figmaRecipe() })
  const text = await call(driver, 'check_recipe', { recipe: '../figma-files', link: FIGMA })
  expect(firstLine(text)).toMatch(/^Check failed/)
  expect(jsonOf(text).problems).toContainEqual(expect.objectContaining({ path: 'id' }))
  expect(pane.touched.filter(path => path.includes('figma-files') && !path.startsWith(`${ROOT}/`))).toEqual([])
  expect(pane.scripts()).toEqual([])
})

test('a link the recipe does not match fails the check as not matched', async (driver, on) => {
  await paneWorld(on, { files: figmaRecipe(), approve: ['figma-files'] })
  const text = await call(driver, 'check_recipe', { recipe: 'figma-files', link: PROTO })
  const json = jsonOf(text)
  expect(json.matched).toBe(false)
  expect(json.pass).toBe(false)
  expect(firstLine(text)).toMatch(/does not match/)
})

test('the check reports a failing source by kind and keeps stderr under the fetched-data field', async (driver, on) => {
  await paneWorld(on, { files: figmaRecipe(), approve: ['figma-files'], pages: () => ({ exitCode: 2, stderr: 'boom' }) })
  const text = await call(driver, 'check_recipe', { recipe: 'figma-files', link: FIGMA })
  const json = jsonOf(text)
  expect(json.outcome).toMatchObject({ kind: 'exit-nonzero', exitCode: 2 })
  expect(json.fetched.stderr).toBe('boom')
  expect(json.outcome.stderr).toBeUndefined()
})

test('open on a working draft returns the outline in the pane focus order, marked unapproved, with the page shown before', async (driver, on) => {
  await paneWorld(on, { files: figmaRecipe(), decision: 'allow' })
  await peek(driver, 'https://example.com/page')
  const text = await call(driver, 'open', { link: FIGMA })
  expect(firstLine(text)).toMatch(/^Opened recipe "Figma files" \(figma-files\) in peek \(draft, unapproved/)
  expect(firstLine(text)).not.toContain('Design system')
  const json = jsonOf(text)
  expect(json.isPlaced).toBe(true)
  expect(json.route).toEqual({ kind: 'recipe', id: 'figma-files', isDraft: true })
  expect(json.isApproved).toBe(false)
  expect(json.before).toBeDefined()
  expect(json.before).toMatchObject({ href: 'https://example.com/page' })
  const outlined: { section: number; title: string }[] = json.fetched.outline.items
  expect(outlined.map(one => one.title)).toEqual(['Prototype', 'Broken file', 'No link here', 'Cover | 1', 'Draft | 4', 'Ana: ship it', 'Bo: wait'])
  const ui = await mount(driver)
  const drawn = itemsInPane(await ui.drawn())
  expect(drawn.map(one => one.index)).toEqual(outlined.map((_, i) => i))
  expect(drawn.map(one => one.section)).toEqual(outlined.map(one => one.section))
  drawn.forEach((one, i) => expect(one.text).toContain(outlined[i]?.title.split(' | ')[0] ?? '?'))
  await ui.unmount()
})

test('open on a failing recipe returns the error text, not opened', async (driver, on) => {
  await paneWorld(on, { files: figmaRecipe(), approve: ['figma-files'], pages: () => ({ exitCode: 2, stderr: 'boom' }) })
  const text = await call(driver, 'open', { link: FIGMA })
  expect(firstLine(text)).not.toMatch(/^Opened/)
  expect(firstLine(text)).toMatch(/Figma files.*exit-nonzero/)
  expect(firstLine(text)).not.toContain('boom')
  const json = jsonOf(text)
  expect(json.fetched.error).toMatch(/boom/)
  expect(json.fetched.outline).toBeUndefined()
  expect(json.route).toEqual({ kind: 'recipe', id: 'figma-files', isDraft: false })
  expect(String(json.skill)).toContain(SKILL)
})

test('open with the pane unplaced reports isPlaced false and the reason', async (driver, on) => {
  await paneWorld(on, { files: figmaRecipe(), approve: ['figma-files'], placed: { isPlaced: false, reason: 'the terminal is too narrow' } })
  const text = await call(driver, 'open', { link: FIGMA })
  const json = jsonOf(text)
  expect(json.isPlaced).toBe(false)
  expect(json.reason).toBe('the terminal is too narrow')
  expect(firstLine(text)).toMatch(/^Opened.*not shown.*too narrow/i)
})

test('open on a link no recipe handles reports the web route', async (driver, on) => {
  await paneWorld(on, { files: figmaRecipe(), approve: ['figma-files'] })
  const json = jsonOf(await call(driver, 'open', { link: 'https://example.com/page' }))
  expect(json.route).toEqual({ kind: 'web' })
  expect(json.isPlaced).toBe(true)
})

test('page text in a result sits under the fetched-data field and is capped', async (driver, on) => {
  const long = 'x'.repeat(5000)
  const items = Array.from({ length: 150 }, (_, i) => ({ title: `${i} ${'y'.repeat(150)}` }))
  const page = { title: 'Big', sections: [{ block: { type: 'markdown', text: long } }, { block: { type: 'list', items } }] }
  await paneWorld(on, { files: figmaRecipe(), approve: ['figma-files'], pages: () => ({ stdout: JSON.stringify(page) }) })
  for (const tool of ['check_recipe', 'open']) {
    const text = await call(driver, tool, { recipe: 'figma-files', link: FIGMA })
    const json = jsonOf(text)
    expect(json.fetched.note).toMatch(/not instructions/)
    expect(text.length).toBeLessThan(20_000)
    expect(text).not.toContain('x'.repeat(1000))
    expect(json.counts.items).toBe(150)
    expect(json.fetched.outline.sections[1].items).toBe(150)
    const outlined = json.fetched.outline.items as { title: string }[]
    expect(outlined.length).toBe(50)
    expect(json.fetched.outline.itemsShown).toBe(50)
    expect(outlined.every(one => one.title.length <= 120)).toBe(true)
    expect(firstLine(text)).not.toContain('y'.repeat(20))
  }
})

test('neither check_recipe nor open records an approval', async (driver, on) => {
  const pane = await paneWorld(on, { files: figmaRecipe(), decision: 'allow' })
  await call(driver, 'check_recipe', { recipe: 'figma-files', link: FIGMA })
  await call(driver, 'open', { link: FIGMA })
  await call(driver, 'check_recipe', { recipe: 'figma-files', link: FIGMA, approve: true })
  await call(driver, 'open', { link: FIGMA, approve: true })
  expect(pane.storeText()).toBe('null')
  await peek(driver, FIGMA)
  const ui = await mount(driver)
  expect(await ui.find({ text: 'Figma web page' })).toBeDefined()
  await ui.unmount()
})

test('both tools are registered deferred, and their descriptions name the skill file', async (driver, on) => {
  await paneWorld(on, { files: figmaRecipe() })
  const specs: Record<string, unknown>[] = []
  on('tool.register', (_$, e) => {
    specs.push(e as unknown as Record<string, unknown>)
    return { value: undefined } as never
  })
  on('command.register', () => ({ value: undefined }) as never)
  on('session.start', () => ({ cwd: '/repo' }) as never)
  await driver.session.start({ cwd: '/repo', source: 'startup' } as never)
  const byName = Object.fromEntries(specs.map(one => [String(one.name), one]))
  for (const name of ['check_recipe', 'open']) {
    expect(byName[name]?.isDeferred).toBe(true)
    expect(String(byName[name]?.description)).toContain(SKILL)
  }
})
