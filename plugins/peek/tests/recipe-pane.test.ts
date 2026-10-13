import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { groupsDir } from '../hooks/groups'
import { runRecipe } from '../hooks/recipe-run'
import { loadRecipe } from '../hooks/recipes'
import { BACKGROUND_MS, resetRefresh } from '../hooks/refresh'
import { pullView } from './fixtures/github/items'
import { HOME, ROOT, folder, world } from './fixtures/recipes/world'
import type { ScriptAnswer, World } from './fixtures/recipes/world'

const NOW = 10 * 3600_000
const FIGMA = 'https://figma.com/file/abc/Design'
const BROKEN = 'https://figma.com/file/broken/Design'
const SLOW = 'https://figma.com/file/slow/Design'
const PROTO = 'https://figma.com/proto/xyz/Flow'
const PR = 'https://github.com/acme/widgets/pull/42'
const GROUP_ID = 'abcd1234'
// A PNG signature and an 800x600 IHDR chunk: the engine checks both before it draws.
const PNG_HEAD = 'iVBORw0KGgoAAAANSUhEUgAAAyAAAAJYCAIAAAAVFBUn'
const CURL_MARKER = '__peek_curl__ '

type Page = Record<string, unknown>

const designPage = (extra: Page = {}): Page => ({
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
    {
      heading: 'Pages',
      block: { type: 'table', columns: ['Page', 'Frames'], rows: [{ cells: ['Cover', '1'], href: PROTO }, { cells: ['Draft', '4'] }] },
    },
  ],
  actions: [
    { label: 'Open in Figma', open: FIGMA },
    { label: 'Copy file key', copy: 'abc' },
  ],
  ...extra,
})

const protoPage: Page = { title: 'Prototype xyz', sections: [{ heading: 'Flow', block: { type: 'markdown', text: 'Three screens.' } }] }

const answer = (page: Page): ScriptAnswer => ({ stdout: JSON.stringify(page) })

const figmaRecipe = (recipe: Page = {}) =>
  folder('figma-files', { source: { run: ['./fetch.sh'] }, ...recipe }, { 'fetch.sh': '#!/bin/sh\necho page\n' })

const protoRecipe = () =>
  folder('figma-protos', { name: 'Figma prototypes', match: [{ host: 'figma.com', path: '/proto/*' }], source: { run: ['./proto.sh'] } }, { 'proto.sh': '#!/bin/sh\n' })

type PaneOptions = {
  files: Record<string, string | Uint8Array | { link: string }>
  approve?: string[]
  pages?: (url: string, script: string) => ScriptAnswer
  hold?: (url: string) => Promise<void> | undefined
  images?: readonly string[]
  pull?: () => Record<string, unknown>
  webTitle?: string
  isHomeBrokenOnce?: boolean
}

type Pane = {
  w: World
  ran: string[][]
  scripts: () => string[]
  copies: string[]
  toasts: string[]
  started: string[]
  clock: ReturnType<typeof mock.clock>
}

async function approve(w: World, id: string) {
  const loaded = await loadRecipe(w.io, ROOT, id)
  if (!loaded.ok) throw new Error(`fixture recipe ${id} does not load: ${JSON.stringify(loaded.problems)}`)
  const approvals = (w.store.recipeApprovals ?? {}) as Record<string, unknown>
  w.store.recipeApprovals = { ...approvals, [id]: { digest: loaded.digest, files: loaded.files } }
}

async function paneWorld(on: On, options: PaneOptions): Promise<Pane> {
  resetRefresh()
  const clock = mock.clock(on, { now: NOW })
  const started: string[] = []
  const w = world({
    files: options.files,
    script: child => {
      const url = child.env.PEEK_URL ?? ''
      return options.pages ? options.pages(url, child.argv[0] ?? '') : answer(url === PROTO ? protoPage : designPage())
    },
  })
  for (const id of options.approve ?? []) await approve(w, id)
  const ran: string[][] = []
  const copies: string[] = []
  const toasts: string[] = []
  const done = (exitCode: number, stdout = '', stderr = '') => ({ value: { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false } })
  const encode = (text: string) => new TextEncoder().encode(text)
  on('session.id', () => ({ value: 'recipe-pane' }))
  on('session.cwd', () => ({ value: '/repo' }))
  on('session.root', () => ({ value: '/repo' }))
  let isHomeBroken = options.isHomeBrokenOnce === true
  on('env.get', (_$, e) => {
    if (e.name === 'HOME' && isHomeBroken) {
      isHomeBroken = false
      throw new Error('env unavailable')
    }
    return { value: w.env[e.name as keyof typeof w.env] }
  })
  on('ui.open', () => ({ value: { isPlaced: true as const } }))
  on('ui.toast', (_$, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  on('ui.copy', (_$, e) => {
    copies.push(e.text)
    return { value: { isCopied: true } } as never
  })
  on('http.fetch', () => ({ value: { status: 404, ok: false, headers: {} as Record<string, string>, text: '' } }))
  on('store.get', (_$, e) => ({ value: w.store[e.key] }))
  on('store.set', (_$, e) => {
    w.store[e.key] = e.value
    return { value: undefined }
  })
  on('fs.list', async (_$, e) => ({ value: (await w.io.list(e.path)).map(one => ({ ...one, mtimeMs: 0 })) }))
  on('fs.stat', async (_$, e) => {
    const { realPath, ...stat } = await w.io.stat(e.path)
    return { value: { ...stat, mtimeMs: 0, ...(e.resolve && realPath !== undefined ? { realPath } : {}) } }
  })
  on('fs.exists', async (_$, e) => ({ value: await w.io.stat(e.path).then(() => true, () => false) }))
  on('fs.read', async (_$, e) => {
    if (e.as === 'bytes' && e.path.startsWith('/tmp/claude-peek/')) return { value: { base64: `${PNG_HEAD}${'A'.repeat(400)}` } }
    const bytes = await w.io.read(e.path)
    return { value: e.as === 'bytes' ? bytes : new TextDecoder().decode(Uint8Array.from(atob(bytes.base64), c => c.charCodeAt(0))) }
  })
  on('fs.write', (_$, e) => {
    w.write(e.path, encode(e.text))
    return { value: undefined }
  })
  on('process.run', async (_$, e) => {
    const argv = [...e.argv]
    ran.push(argv)
    const [bin = ''] = argv
    if (bin === '/usr/bin/env') {
      const url = argv.at(-1) ?? ''
      started.push(url)
      await options.hold?.(url)
      return { value: await w.io.run(argv, e.init) }
    }
    const line = argv.join(' ')
    if (bin === '/usr/bin/printenv') {
      const value = w.env[(argv[1] ?? '') as keyof typeof w.env]
      return value === undefined ? done(1) : done(0, `${value}\n`)
    }
    if (bin === 'sh') return done(0, 'gh\ncurl\n')
    if (line === 'gh auth status') return done(0)
    if (line.startsWith('gh api repos/acme/widgets/issues/42')) return done(0, JSON.stringify({ number: 42, pull_request: {} }))
    if (line.startsWith('gh pr view 42')) return done(0, JSON.stringify(pullView({ statusCheckRollup: [], ...options.pull?.() })))
    if (line.startsWith('gh api repos/acme/widgets/pulls/42')) return done(0, '2')
    if (bin === '/usr/bin/dscacheutil') return done(0, 'ip_address: 93.184.216.34\n')
    if (bin === 'curl' && argv.includes('-o')) return options.images?.includes(argv.at(-1) ?? '') ? done(0, '200 512 ') : done(22, '404 0 ')
    if (bin === 'curl') {
      const url = argv.at(-1) ?? ''
      return done(0, `<html><head><title>${options.webTitle ?? 'Figma web page'}</title></head><body><p>Web</p></body></html>`, `${CURL_MARKER}200 ${url}`)
    }
    if (bin === 'sips') return done(0, 'pixelWidth: 800\npixelHeight: 600\n')
    return done(0)
  })
  const scripts = () => ran.filter(argv => argv[0] === '/usr/bin/env').map(argv => argv.at(-1) ?? '')
  return { w, ran, scripts, copies, toasts, started, clock }
}

const props = { title: 'Peek', isFocused: true, bodyColumns: 100, placement: 'dock' as const, scroll: { offset: 0, bodyRows: 40 }, view: {} }

type Driver = Parameters<Extract<Parameters<typeof test>[1], (...args: never[]) => unknown>>[0]

const mount = (driver: Driver) => driver.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })

type Ui = Awaited<ReturnType<typeof mount>>

const peek = (driver: Driver, link: string) => driver.command.run({ command: 'peek', args: link } as never)

async function focusedItem(ui: Ui) {
  for (let i = 0; i < 40; i++) if ((await ui.find({ key: `item-${i}` }))?.props.autoFocus === true) return i
  return -1
}

async function until(ui: Ui, isDone: () => Promise<boolean> | boolean, tries = 50) {
  for (let i = 0; i < tries; i++) {
    if (await isDone()) return
    await ui.redraw()
  }
}

function writeGroup(w: World, items: string[]) {
  const group = { projectKey: '/repo', id: GROUP_ID, title: 'Design', description: '', starred: false, updatedAt: NOW, sections: [], items: items.map(ref => ({ ref, addedBy: 'agent', addedAt: NOW })), removed: [] }
  w.write(`${groupsDir(HOME, '/repo')}/${GROUP_ID}.json`, JSON.stringify(group))
}

test('covers AE1: an approved recipe draws a Figma link as its page, not the web reader', async (driver, on) => {
  const pane = await paneWorld(on, { files: figmaRecipe(), approve: ['figma-files'] })
  await peek(driver, FIGMA)
  const ui = await mount(driver)
  expect(await ui.find({ text: 'Design system' })).toBeDefined()
  expect(await ui.find({ text: /^NOTES $/ })).toBeDefined()
  expect(await ui.find({ text: /recipe figma-files · approved · 0s ago/ })).toBeDefined()
  expect(JSON.stringify(await ui.drawn())).toContain('Figma files')
  expect(pane.scripts()).toEqual([FIGMA])
  expect(pane.ran.some(argv => argv[0] === 'curl' && !argv.includes('-o'))).toBe(false)
  await ui.unmount()
})

test('covers AE1: a recipe matching github.com without an override leaves a pull request to the GitHub page', async (driver, on) => {
  const files = folder('gh-pages', { name: 'GitHub pages', match: [{ host: 'github.com', path: '/*' }], source: { run: ['./fetch.sh'] } }, { 'fetch.sh': '#!/bin/sh\n' })
  const pane = await paneWorld(on, { files, approve: ['gh-pages'] })
  await peek(driver, PR)
  const ui = await mount(driver)
  expect(await ui.find({ text: /#42 Teach the parser trailing commas/ })).toBeDefined()
  expect(pane.scripts()).toEqual([])
  await ui.unmount()
})

test('a recipe folder that cannot be read leaves every web link opening as before', async (driver, on) => {
  const pane = await paneWorld(on, { files: figmaRecipe(), approve: ['figma-files'], isHomeBrokenOnce: true })
  await peek(driver, PR)
  const ui = await mount(driver)
  expect(await ui.find({ text: /#42 Teach the parser trailing commas/ })).toBeDefined()
  expect(pane.scripts()).toEqual([])
  await ui.unmount()
})

test('a markdown link to an absolute path on a recipe page opens that file, and b returns', async (driver, on) => {
  const plan = `${HOME}/notes/plan.md`
  const page = { title: 'With a file', sections: [{ block: { type: 'markdown', text: `See [the plan](${plan}).` } }] }
  await paneWorld(on, { files: { ...figmaRecipe(), [plan]: '# Plan\n\nShip it.\n' }, approve: ['figma-files'], pages: () => answer(page) })
  await peek(driver, FIGMA)
  let ui = await mount(driver)
  await ui.press({ key: 'section-0-md-md-0', link: { href: plan } } as never)
  await until(ui, async () => (await ui.find({ text: /Ship it/ })) !== undefined)
  expect(await ui.find({ text: /Ship it/ })).toBeDefined()
  await ui.press({ key: 'back' })
  await ui.unmount()
  ui = await mount(driver)
  expect(await ui.find({ text: 'With a file' })).toBeDefined()
  await ui.unmount()
})

test('a draft recipe never runs on a normal open: the link goes where it would without it', async (driver, on) => {
  const pane = await paneWorld(on, { files: figmaRecipe() })
  await peek(driver, FIGMA)
  const ui = await mount(driver)
  expect(pane.scripts()).toEqual([])
  expect(await ui.find({ text: 'Design system' })).toBeUndefined()
  expect(await ui.find({ text: 'Figma web page' })).toBeDefined()
  expect(JSON.stringify(await ui.drawn())).not.toContain('Figma files')
  await ui.unmount()
})

test('two approved recipes claiming one link show an error page naming both, and run neither', async (driver, on) => {
  const other = folder('figma-all', { name: 'All of Figma', match: [{ host: 'figma.com' }], source: { run: ['./all.sh'] } }, { 'all.sh': '#!/bin/sh\n' })
  const pane = await paneWorld(on, { files: { ...figmaRecipe(), ...other }, approve: ['figma-files', 'figma-all'] })
  await peek(driver, FIGMA)
  const ui = await mount(driver)
  const tree = JSON.stringify(await ui.drawn())
  expect(tree).toContain('figma-all')
  expect(tree).toContain('figma-files')
  expect(pane.scripts()).toEqual([])
  await ui.unmount()
})

test('covers AE2: a recipe page with no timer runs once in five minutes on screen; u runs it again and it stays a recipe page', async (driver, on) => {
  const pane = await paneWorld(on, { files: figmaRecipe(), approve: ['figma-files'] })
  await peek(driver, FIGMA)
  for (let minute = 0; minute < 5; minute++) {
    await driver.session.append({ message: { type: 'user', content: [{ type: 'text', text: 'still here' }] } } as never).catch(() => undefined)
    await pane.clock.advance(60_000)
  }
  expect(pane.scripts()).toEqual([FIGMA])
  const ui = await mount(driver)
  await ui.press({ key: 'refresh' })
  await until(ui, () => pane.scripts().length === 2)
  await until(ui, async () => (await ui.find({ text: /refreshing/ })) === undefined)
  expect(pane.scripts()).toEqual([FIGMA, FIGMA])
  expect(await ui.find({ text: 'Design system' })).toBeDefined()
  expect(await ui.find({ text: /recipe figma-files · approved/ })).toBeDefined()
  await ui.unmount()
})

test('covers AE3: a failing script shows an error page naming the recipe and the error, with no star or group; b goes back and other pages still open', async (driver, on) => {
  const pane = await paneWorld(on, {
    files: { ...figmaRecipe(), ...protoRecipe() },
    approve: ['figma-files', 'figma-protos'],
    pages: url => (url === BROKEN ? { exitCode: 2, stderr: 'boom' } : answer(url === PROTO ? protoPage : designPage())),
  })
  writeGroup(pane.w, [])
  await peek(driver, FIGMA)
  let ui = await mount(driver)
  expect(await ui.find({ key: 'star' })).toBeDefined()
  await driver.command.run({ command: 'peek-menu' } as never)
  await ui.redraw()
  expect(await ui.find({ text: /Add to group: Design/ })).toBeDefined()
  await driver.command.run({ command: 'peek-menu' } as never)
  await ui.redraw()
  await ui.press({ key: 'item-1' })
  await until(ui, async () => (await ui.find({ text: /Recipe page failed/ })) !== undefined)
  const tree = JSON.stringify(await ui.drawn())
  expect(tree).toContain('Recipe \\"Figma files\\" (figma-files): the script exited with code 2: boom')
  expect(await ui.find({ key: 'star' })).toBeUndefined()
  expect(await ui.find({ key: 'refresh' })).toBeDefined()
  expect(await ui.find({ key: 'open' })).toBeDefined()
  await driver.command.run({ command: 'peek-menu' } as never)
  await ui.redraw()
  expect(await ui.find({ text: /Add to group/ })).toBeUndefined()
  expect(await ui.find({ text: /Star or unstar/ })).toBeUndefined()
  await driver.command.run({ command: 'peek-menu' } as never)
  await ui.unmount()
  ui = await mount(driver)
  await ui.press({ key: 'back' })
  await ui.unmount()
  ui = await mount(driver)
  expect(await ui.find({ text: 'Design system' })).toBeDefined()
  await ui.unmount()
  await peek(driver, PROTO)
  ui = await mount(driver)
  expect(await ui.find({ text: 'Prototype xyz' })).toBeDefined()
  await ui.unmount()
})

test('covers AE4: enter on a card opens another recipe\'s link through normal routing, so does a click on it, and b returns', async (driver, on) => {
  const pane = await paneWorld(on, { files: { ...figmaRecipe(), ...protoRecipe() }, approve: ['figma-files', 'figma-protos'] })
  await peek(driver, FIGMA)
  let ui = await mount(driver)
  await ui.press({ key: 'item-0' })
  await until(ui, async () => (await ui.find({ text: 'Prototype xyz' })) !== undefined)
  expect(await ui.find({ text: 'Prototype xyz' })).toBeDefined()
  expect(pane.scripts()).toEqual([FIGMA, PROTO])
  await ui.press({ key: 'back' })
  await ui.unmount()
  ui = await mount(driver)
  expect(await ui.find({ text: 'Design system' })).toBeDefined()
  const layer = 'hover-section-1-0'
  await ui.resize({ columns: 94, rows: 5, in: layer })
  await ui.pointer({ type: 'down', button: 'left', x: 4, y: 2, in: layer })
  await until(ui, async () => (await ui.find({ text: 'Prototype xyz' })) !== undefined)
  expect(await ui.find({ text: 'Prototype xyz' })).toBeDefined()
  expect(pane.scripts()).toEqual([FIGMA, PROTO, PROTO])
  await ui.press({ key: 'back' })
  await ui.unmount()
  ui = await mount(driver)
  expect(await ui.find({ text: 'Design system' })).toBeDefined()
  await ui.unmount()
})

test('a click on a table row with a link opens it; a click on a row or card with no link does nothing', async (driver, on) => {
  const pane = await paneWorld(on, { files: { ...figmaRecipe(), ...protoRecipe() }, approve: ['figma-files', 'figma-protos'] })
  await peek(driver, FIGMA)
  let ui = await mount(driver)
  const rows = 'hover-section-2'
  await ui.resize({ columns: 94, rows: 2, in: rows })
  await ui.pointer({ type: 'down', button: 'left', x: 10, y: 1, in: rows })
  await ui.pointer({ type: 'down', button: 'left', x: 64, y: 2, in: 'hover-section-1-0' })
  await ui.redraw()
  expect(await ui.find({ text: 'Design system' })).toBeDefined()
  expect(pane.scripts()).toEqual([FIGMA])
  await ui.pointer({ type: 'move', x: 10, y: 0, in: rows })
  expect(JSON.stringify(await ui.drawn({ in: rows }))).toContain('\u{f41e}')
  await ui.pointer({ type: 'down', button: 'left', x: 10, y: 0, in: rows })
  await until(ui, async () => (await ui.find({ text: 'Prototype xyz' })) !== undefined)
  expect(pane.scripts()).toEqual([FIGMA, PROTO])
  await ui.press({ key: 'back' })
  await ui.unmount()
  ui = await mount(driver)
  expect(await ui.find({ text: 'Design system' })).toBeDefined()
  await ui.unmount()
})

test('covers AE7: a group holding a recipe link runs no script; its card shows the web title until the person opens it', async (driver, on) => {
  const pane = await paneWorld(on, { files: figmaRecipe(), approve: ['figma-files'], webTitle: 'Figma web page' })
  writeGroup(pane.w, [FIGMA])
  const ui = await mount(driver)
  await ui.press({ key: 'mode-groups' })
  await ui.press({ key: 'item-0' })
  await until(ui, async () => (await ui.find({ text: /Figma web page/ })) !== undefined)
  expect(await ui.find({ text: /Figma web page/ })).toBeDefined()
  expect(pane.scripts()).toEqual([])
  await ui.press({ key: 'item-0' })
  await until(ui, async () => (await ui.find({ text: 'Design system' })) !== undefined)
  expect(pane.scripts()).toEqual([FIGMA])
  await ui.unmount()
})

test('mixed sections: arrows move through the cards then the table rows; action 2 copies its text and says so', async (driver, on) => {
  const pane = await paneWorld(on, { files: figmaRecipe(), approve: ['figma-files'] })
  await peek(driver, FIGMA)
  const ui = await mount(driver)
  expect(await focusedItem(ui)).toBe(0)
  await ui.press({ key: 'right' })
  expect(await focusedItem(ui)).toBe(1)
  await ui.press({ key: 'right' })
  expect(await focusedItem(ui)).toBe(2)
  await ui.press({ key: 'next' })
  expect(await focusedItem(ui)).toBe(3)
  await ui.press({ key: 'next' })
  expect(await focusedItem(ui)).toBe(4)
  await ui.press({ key: 'next' })
  expect(await focusedItem(ui)).toBe(4)
  await ui.press({ key: 'prev' })
  expect(await focusedItem(ui)).toBe(3)
  expect((await ui.find({ key: 'action-1' }))?.props.hotkey).toBe('2')
  await ui.press({ key: 'action-1' })
  expect(pane.copies).toEqual(['abc'])
  expect(pane.toasts).toContain('Copied abc')
  await ui.unmount()
})

test('a loading page names the recipe until the script answers', async (driver, on) => {
  let release = () => {}
  const held = new Promise<void>(resolve => {
    release = resolve
  })
  const pane = await paneWorld(on, { files: figmaRecipe(), approve: ['figma-files'], hold: () => held })
  const opening = peek(driver, FIGMA)
  const ui = await mount(driver)
  await until(ui, () => pane.started.length > 0)
  await ui.redraw()
  expect(await ui.find({ text: /Running Figma files/ })).toBeDefined()
  expect(await ui.find({ text: 'Design system' })).toBeUndefined()
  release()
  await opening
  await ui.redraw()
  expect(await ui.find({ text: /Running Figma files/ })).toBeUndefined()
  expect(await ui.find({ text: 'Design system' })).toBeDefined()
  await ui.unmount()
})

test('opening link B while recipe A\'s script runs leaves B on screen', async (driver, on) => {
  let release = () => {}
  const held = new Promise<void>(resolve => {
    release = resolve
  })
  const pane = await paneWorld(on, {
    files: figmaRecipe(),
    approve: ['figma-files'],
    hold: url => (url === SLOW ? held : undefined),
    pages: url => answer(url === SLOW ? { title: 'Slow file', sections: [] } : designPage()),
  })
  const slow = peek(driver, SLOW)
  const ui = await mount(driver)
  await until(ui, () => pane.started.includes(SLOW))
  await peek(driver, FIGMA)
  release()
  await slow
  await ui.redraw()
  expect(await ui.find({ text: 'Design system' })).toBeDefined()
  expect(await ui.find({ text: 'Slow file' })).toBeUndefined()
  await ui.unmount()
})

test('two quick u presses run the script once', async (driver, on) => {
  let release = () => {}
  let held: Promise<void> | undefined
  const pane = await paneWorld(on, { files: figmaRecipe(), approve: ['figma-files'], hold: () => held })
  await peek(driver, FIGMA)
  held = new Promise<void>(resolve => {
    release = resolve
  })
  const ui = await mount(driver)
  await ui.press({ key: 'refresh' })
  await until(ui, () => pane.started.length === 2)
  await ui.redraw()
  expect(await ui.find({ text: /Refreshing/ })).toBeDefined()
  expect(await ui.find({ text: 'Design system' })).toBeDefined()
  await ui.press({ key: 'refresh' })
  release()
  await until(ui, async () => (await ui.find({ text: /Refreshing/ })) === undefined)
  expect(pane.scripts()).toEqual([FIGMA, FIGMA])
  await ui.unmount()
})

test('a refresh that fails keeps the last page and says why', async (driver, on) => {
  let isBroken = false
  const pane = await paneWorld(on, { files: figmaRecipe(), approve: ['figma-files'], pages: () => (isBroken ? { exitCode: 3, stderr: 'rate limited' } : answer(designPage())) })
  await peek(driver, FIGMA)
  isBroken = true
  const ui = await mount(driver)
  await ui.press({ key: 'refresh' })
  await until(ui, async () => (await ui.find({ text: /Refresh failed/ })) !== undefined)
  expect(await ui.find({ text: 'Design system' })).toBeDefined()
  expect(JSON.stringify(await ui.drawn())).toContain('rate limited')
  expect(pane.scripts()).toEqual([FIGMA, FIGMA])
  await ui.unmount()
})

test('refreshing a page whose recipe was edited since keeps the page, says why, and never falls back to the web reader', async (driver, on) => {
  const pane = await paneWorld(on, { files: figmaRecipe(), approve: ['figma-files'] })
  await peek(driver, FIGMA)
  pane.w.write(`${ROOT}/figma-files/fetch.sh`, '#!/bin/sh\necho edited\n')
  const ui = await mount(driver)
  await ui.press({ key: 'refresh' })
  await until(ui, async () => (await ui.find({ text: /Refresh failed/ })) !== undefined)
  expect(JSON.stringify(await ui.drawn())).toContain('no longer handles this link')
  expect(await ui.find({ text: 'Design system' })).toBeDefined()
  expect(await ui.find({ text: 'Figma web page' })).toBeUndefined()
  expect(pane.scripts()).toEqual([FIGMA])
  await ui.unmount()
})

test('b back to a recipe page restores it without running the script again', async (driver, on) => {
  const pane = await paneWorld(on, { files: { ...figmaRecipe(), ...protoRecipe() }, approve: ['figma-files', 'figma-protos'] })
  await peek(driver, FIGMA)
  let ui = await mount(driver)
  await ui.press({ key: 'item-0' })
  await until(ui, async () => (await ui.find({ text: 'Prototype xyz' })) !== undefined)
  const before = pane.scripts().length
  await ui.press({ key: 'back' })
  await ui.unmount()
  ui = await mount(driver)
  expect(await ui.find({ text: 'Design system' })).toBeDefined()
  expect(pane.scripts().length).toBe(before)
  await ui.unmount()
})

test('a recipe page offers no v Live key and no Live menu row', async (driver, on) => {
  await paneWorld(on, { files: figmaRecipe(), approve: ['figma-files'] })
  await peek(driver, FIGMA)
  await driver.command.run({ command: 'peek-menu' } as never)
  const ui = await mount(driver)
  expect(await ui.find({ text: /Refresh this page/ })).toBeDefined()
  expect(await ui.find({ key: 'live' })).toBeUndefined()
  expect(await ui.find({ text: /Live view/ })).toBeUndefined()
  await ui.unmount()
})

test('an overriding recipe on screen for a pull request in mentions stays the recipe page after a background tick, and its script ran once', async (driver, on) => {
  const files = folder('gh-pulls', { name: 'Pull pages', match: [{ host: 'github.com', path: '/*/pull/*' }], overrides: ['github'], source: { run: ['./fetch.sh'] } }, { 'fetch.sh': '#!/bin/sh\n' })
  let title = 'Teach the parser trailing commas'
  const pane = await paneWorld(on, { files, pull: () => ({ title }), pages: () => answer({ title: 'Pull as a recipe', sections: [] }) })
  await peek(driver, PR)
  let ui = await mount(driver)
  expect(await ui.find({ text: /#42 Teach the parser trailing commas/ })).toBeDefined()
  await ui.unmount()
  await approve(pane.w, 'gh-pulls')
  await peek(driver, PR)
  ui = await mount(driver)
  expect(await ui.find({ text: 'Pull as a recipe' })).toBeDefined()
  await ui.unmount()
  const pulls = () => pane.ran.filter(argv => argv.join(' ').startsWith('gh pr view 42')).length
  const before = pulls()
  title = 'Retitled on GitHub'
  await driver.session.append({ message: { type: 'user', content: [{ type: 'text', text: 'still here' }] } } as never).catch(() => undefined)
  await pane.clock.advance(BACKGROUND_MS + 30_000)
  expect(pulls()).toBeGreaterThan(before)
  ui = await mount(driver)
  expect(await ui.find({ text: 'Pull as a recipe' })).toBeDefined()
  expect(await ui.find({ text: /Retitled on GitHub/ })).toBeUndefined()
  expect(pane.scripts()).toEqual([PR])
  await ui.unmount()
})

test('a media item whose download fails draws an [open image] link, and the page still shows', async (driver, on) => {
  const page = {
    title: 'Shots',
    sections: [
      { heading: 'Screens', block: { type: 'media', items: [{ url: 'https://cdn.test/ok.png', alt: 'Home', kind: 'image' }, { url: 'https://cdn.test/gone.png', alt: 'Gone', kind: 'image' }] } },
      { block: { type: 'markdown', text: 'Inline:\n\n![inline](https://cdn.test/inline.png)\n' } },
    ],
  }
  const pane = await paneWorld(on, { files: figmaRecipe(), approve: ['figma-files'], images: ['https://cdn.test/ok.png'], pages: () => answer(page) })
  await peek(driver, FIGMA)
  const ui = await mount(driver)
  expect(await ui.find({ text: 'Shots' })).toBeDefined()
  expect(await ui.find({ key: 'media-10000-image' })).toBeDefined()
  const tree = JSON.stringify(await ui.drawn())
  expect(tree).toContain('[open image](https://cdn.test/gone.png)')
  expect(tree).toContain('[open image](https://cdn.test/inline.png)')
  expect(tree).not.toContain('![inline]')
  const curls = pane.ran.filter(argv => argv[0] === 'curl' && argv.includes('-o')).map(argv => argv.at(-1))
  expect(curls.toSorted()).toEqual(['https://cdn.test/gone.png', 'https://cdn.test/inline.png', 'https://cdn.test/ok.png'])
  await ui.unmount()
})

test('validatePage production callers: the open and refresh paths both refuse a page outside the vocabulary, through runRecipe', async (driver, on) => {
  let block: Page = { type: 'markdown', text: 'fine' }
  await paneWorld(on, { files: figmaRecipe(), approve: ['figma-files'], pages: () => answer({ title: 'Checked', sections: [{ block }] }) })
  block = { type: 'chart', points: [1, 2] }
  await peek(driver, FIGMA)
  let ui = await mount(driver)
  expect(JSON.stringify(await ui.drawn())).toContain('sections[0].block.type')
  expect(await ui.find({ text: 'Checked' })).toBeUndefined()
  block = { type: 'markdown', text: 'fine' }
  await ui.press({ key: 'refresh' })
  await until(ui, async () => (await ui.find({ text: 'Checked' })) !== undefined)
  expect(await ui.find({ text: 'Checked' })).toBeDefined()
  block = { type: 'list', items: [{ title: 'Local service', href: 'http://127.0.0.1:8080/admin' }] }
  await ui.press({ key: 'refresh' })
  await until(ui, async () => (await ui.find({ text: /Refresh failed/ })) !== undefined)
  expect(JSON.stringify(await ui.drawn())).toContain('sections[0].block.items[0].href')
  expect(await ui.find({ text: /Local service/ })).toBeUndefined()
  await ui.unmount()
  expect(runRecipe.toString()).toContain('validatePage(')
})
