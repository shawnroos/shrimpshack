import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { APPROVALS_KEY, loadRecipe } from '../hooks/recipes/recipes'
import { resetRefresh } from '../hooks/refresh'
import { FS_BINS, HOME, ROOT, folder, world } from './fixtures/recipes/world'
import type { ScriptAnswer, World } from './fixtures/recipes/world'

const NOW = 10 * 3600_000
const FIGMA = 'https://figma.com/file/abc/Design'
const PROTO = 'https://figma.com/proto/xyz/Flow'
const PR = 'https://github.com/acme/widgets/pull/42'
const STORE_DIR = `${HOME}/.claude/plugins/store`
const STORE_FILE = `${STORE_DIR}/peek_3f9a2c71.json`
const SCRIPT = '#!/bin/sh\n# fetch the design file\ncurl -s "https://api.figma.com/v1/files/$1"\n'

type Page = Record<string, unknown>

const designPage: Page = {
  title: 'Design system',
  sections: [
    { heading: 'Notes', block: { type: 'markdown', text: 'Tokens and type.' } },
    { heading: 'Frames', block: { type: 'list', items: [{ title: 'Prototype', href: PROTO }, { title: 'Cover' }, { title: 'Spare' }] } },
  ],
}

const figmaRecipe = (recipe: Page = {}, extra: Record<string, string | Uint8Array | { link: string }> = {}) =>
  folder('figma-files', { source: { run: ['./fetch.sh'], env: ['FIGMA_TOKEN'] }, refreshMinutes: 0, ...recipe }, { 'fetch.sh': SCRIPT, ...extra })

const allFigma = () =>
  folder('figma-all', { name: 'All of Figma', match: [{ host: 'figma.com' }], source: { run: ['./all.sh'] } }, { 'all.sh': '#!/bin/sh\necho all\n' })

type Pane = { w: World; scripts: () => string[]; writes: string[]; storeText: () => string }

async function approve(w: World, id: string) {
  const loaded = await loadRecipe(w.io, ROOT, id)
  if (!loaded.ok) throw new Error(`fixture recipe ${id} does not load: ${JSON.stringify(loaded.problems)}`)
  const approvals = (w.store[APPROVALS_KEY] ?? {}) as Record<string, unknown>
  w.store[APPROVALS_KEY] = { ...approvals, [id]: { digest: loaded.digest, files: loaded.files } }
}

// The engine keeps a plugin's store as one JSON file under <config dir>/plugins/store/, named with an install hash.
async function paneWorld(on: On, options: { files: Record<string, string | Uint8Array | { link: string }>; approve?: string[]; env?: Record<string, string>; storeDir?: string }): Promise<Pane> {
  resetRefresh()
  mock.clock(on, { now: NOW })
  const storeFile = `${options.storeDir ?? STORE_DIR}/peek_3f9a2c71.json`
  const w = world({ files: { ...options.files, [storeFile]: '{}' }, env: options.env, script: child => ({ stdout: JSON.stringify(child.env.PEEK_URL === PR ? { title: 'Pull as a recipe', sections: [] } : designPage) }) as ScriptAnswer })
  for (const id of options.approve ?? []) await approve(w, id)
  const writes: string[] = []
  const done = (exitCode: number, stdout = '') => ({ value: { exitCode, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } })
  const persist = () => w.write(storeFile, JSON.stringify(w.store))
  persist()
  on('session.id', () => ({ value: 'recipe-approval' }))
  on('session.cwd', () => ({ value: '/repo' }))
  on('session.root', () => ({ value: '/repo' }))
  on('env.get', (_$, e) => ({ value: w.env[e.name as keyof typeof w.env] }))
  on('ui.open', () => ({ value: { isPlaced: true as const } }))
  on('ui.toast', () => ({ value: undefined }))
  on('http.fetch', () => ({ value: { status: 404, ok: false, headers: {} as Record<string, string>, text: '' } }))
  on('store.get', (_$, e) => ({ value: w.store[e.key] }))
  on('store.set', (_$, e) => {
    w.store[e.key] = e.value
    persist()
    return { value: undefined }
  })
  on('tool.check', () => ({ decision: 'allow' as const }))
  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc
  on('tool.call', { tool: /^(?:Write|Edit|MultiEdit|NotebookEdit)$/ }, (_$, e) => {
    const input = e as unknown as { file_path?: string; notebook_path?: string }
    writes.push(input.file_path ?? input.notebook_path ?? '')
    return { result: 'written' }
  })
  on('fs.list', async (_$, e) => ({ value: (await w.io.list(e.path)).map(one => ({ ...one, mtimeMs: 0 })) }))
  on('fs.stat', async (_$, e) => {
    const { realPath, ...stat } = await w.io.statResolved(e.path)
    return { value: { ...stat, mtimeMs: 0, ...(e.resolve && realPath !== undefined ? { realPath } : {}) } }
  })
  on('fs.exists', async (_$, e) => ({ value: await w.io.statResolved(e.path).then(() => true, () => false) }))
  on('fs.read', async (_$, e) => {
    const bytes = await w.io.readBytes(e.path)
    return { value: e.as === 'bytes' ? bytes : new TextDecoder().decode(Uint8Array.from(atob(bytes.base64), c => c.charCodeAt(0))) }
  })
  on('fs.write', (_$, e) => {
    w.write(e.path, e.text)
    return { value: undefined }
  })
  on('process.run', async (_$, e) => {
    const argv = [...e.argv]
    const [bin = ''] = argv
    if (bin === '/usr/bin/env' || FS_BINS.includes(bin)) return { value: await w.io.run(argv, e.init) }
    if (bin === '/usr/bin/printenv') {
      const value = w.env[(argv[1] ?? '') as keyof typeof w.env]
      return value === undefined ? done(1) : done(0, `${value}\n`)
    }
    if (bin === 'sh') return done(0, 'gh\ncurl\n')
    if (bin === 'curl') return { value: { ...done(0, '<html><head><title>Figma web page</title></head><body><p>Web</p></body></html>').value, stderr: `__peek_curl__ 200 ${argv.at(-1) ?? ''}` } }
    return done(0)
  })
  const scripts = () => w.calls.children.map(child => child.env.PEEK_URL ?? '')
  return { w, scripts, writes, storeText: () => JSON.stringify(w.store[APPROVALS_KEY] ?? null) }
}

const props = { title: 'Peek', isFocused: true, bodyColumns: 100, placement: 'dock' as const, scroll: { offset: 0, bodyRows: 40 }, view: {} }

type Driver = Parameters<Extract<Parameters<typeof test>[1], (...args: never[]) => unknown>>[0]
type Ui = Awaited<ReturnType<typeof mount>>

const mount = (driver: Driver) => driver.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })

const peek = (driver: Driver, link: string) => driver.command.run({ command: 'peek', args: link } as never)

// The agent's preview: the open tool routes with drafts allowed.
const preview = (driver: Driver, link: string) =>
  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc
  driver.tool.call({ tool: 'mcp__peek__open', tool_use_id: `open-${Math.random()}`, link } as never)

// @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc
const write = (driver: Driver, input: Record<string, unknown>) => driver.tool.call({ tool_use_id: `w-${Math.random()}`, ...input } as never).then(
  answer => JSON.stringify(answer),
  (error: unknown) => `rejected: ${error instanceof Error ? error.message : String(error)}`,
)

const textOf = async (ui: Ui) => JSON.stringify(await ui.drawn())

async function until(ui: Ui, isDone: () => Promise<boolean> | boolean, tries = 50) {
  for (let i = 0; i < tries; i++) {
    if (await isDone()) return
    await ui.redraw()
  }
}

test('pressing Approve on an unchanged preview records the digest and files, the source line turns approved, and a normal open shows the recipe page', async (driver, on) => {
  const pane = await paneWorld(on, { files: figmaRecipe() })
  await preview(driver, FIGMA)
  let ui = await mount(driver)
  expect(await ui.find({ text: /recipe figma-files · draft/ })).toBeDefined()
  expect(pane.storeText()).toBe('null')
  await ui.press({ key: 'approve' })
  await until(ui, async () => (await ui.find({ text: /recipe figma-files · approved/ })) !== undefined)
  expect(await ui.find({ text: /recipe figma-files · approved/ })).toBeDefined()
  expect(await ui.find({ key: 'approve' })).toBeUndefined()
  const loaded = await loadRecipe(pane.w.io, ROOT, 'figma-files')
  if (!loaded.ok) throw new Error('fixture does not load')
  expect(pane.w.store[APPROVALS_KEY]).toEqual({ 'figma-files': { digest: loaded.digest, files: loaded.files } })
  await ui.unmount()
  const before = pane.scripts().length
  await peek(driver, FIGMA)
  ui = await mount(driver)
  expect(await ui.find({ text: 'Design system' })).toBeDefined()
  expect(await ui.find({ text: /recipe figma-files · approved/ })).toBeDefined()
  expect(await ui.find({ key: 'approve' })).toBeUndefined()
  expect(pane.scripts().length).toBe(before + 1)
  await ui.unmount()
})

async function showFiles(ui: Ui) {
  await ui.press({ key: 'review-toggle-files' })
  await until(ui, async () => (await ui.find({ key: 'review-toggle-files' }))?.props.label === 'Hide files')
}

test('Show files and Hide files toggle the file text without moving focus off Approve', async (driver, on) => {
  await paneWorld(on, { files: figmaRecipe() })
  await preview(driver, FIGMA)
  const ui = await mount(driver)
  expect((await ui.find({ key: 'review-toggle-files' }))?.props.label).toBe('Show files')
  expect(await textOf(ui)).not.toContain('curl -s')
  await showFiles(ui)
  expect(await textOf(ui)).toContain('curl -s')
  await ui.press({ key: 'review-toggle-files' })
  await until(ui, async () => (await ui.find({ key: 'review-toggle-files' }))?.props.label === 'Show files')
  expect(await textOf(ui)).not.toContain('curl -s')
  expect((await ui.find({ key: 'approve' }))?.props.autoFocus).toBe(true)
  await ui.unmount()
})

test('the approval surface draws above the page with what will run, the script in full behind Show files before Approve, and Approve holding the first focus', async (driver, on) => {
  await paneWorld(on, { files: figmaRecipe(), env: { FIGMA_TOKEN: 'tok_SECRET' } })
  await preview(driver, FIGMA)
  const ui = await mount(driver)
  const hidden = await textOf(ui)
  expect(hidden).toContain('New file: fetch.sh')
  expect(hidden).not.toContain('curl -s')
  await showFiles(ui)
  const tree = await textOf(ui)
  const at = (needle: string) => tree.indexOf(needle)
  expect(at('Draft recipe')).toBeGreaterThan(-1)
  expect(at('Draft recipe')).toBeLessThan(at('Design system'))
  expect(tree).toContain('./fetch.sh')
  expect(tree).toContain('figma.com/file/*')
  expect(tree).toMatch(/Overrides: none/)
  expect(tree).toMatch(/Refresh: only when opened or refreshed/)
  expect(tree).toContain('FIGMA_TOKEN')
  expect(tree).not.toContain('tok_SECRET')
  expect(tree).toContain('New file: fetch.sh')
  expect(tree).toContain('curl -s \\"https://api.figma.com/v1/files/$1\\"')
  expect(tree).toContain('New file: recipe.json')
  expect(at('curl -s')).toBeLessThan(at('"approve"'))
  expect(at('"approve"')).toBeLessThan(at('Design system'))
  const button = await ui.find({ key: 'approve' })
  expect(button?.props.autoFocus).toBe(true)
  expect(await ui.find({ key: 'item-0' })).toBeDefined()
  for (let i = 0; i < 10; i++) expect((await ui.find({ key: `item-${i}` }))?.props.autoFocus).toBeUndefined()
  await ui.press({ key: 'next' })
  await ui.redraw()
  expect((await ui.find({ key: 'item-0' }))?.props.autoFocus).toBe(true)
  await ui.unmount()
})

test('Approve has no hotkey and no keybinding action, and neither the footer nor the ctrl+k menu offers it', async (driver, on) => {
  await paneWorld(on, { files: figmaRecipe() })
  await preview(driver, FIGMA)
  const ui = await mount(driver)
  const closed = (await textOf(ui)).match(/Approve/g)?.length ?? 0
  await driver.command.run({ command: 'peek-menu' } as never)
  await ui.redraw()
  const button = await ui.find({ key: 'approve' })
  expect(button).toBeDefined()
  expect(button?.props.hotkey).toBeUndefined()
  expect(button?.props.action).toBeUndefined()
  expect(await ui.find({ text: /Refresh this page/ })).toBeDefined()
  const tree = await textOf(ui)
  expect(tree.match(/"key":"approve"/g)?.length).toBe(1)
  expect(tree.match(/"label":"Approve"/g)?.length).toBe(1)
  expect(tree.match(/Approve/g)?.length).toBe(closed)
  expect(await ui.find({ key: 'footer-keys' })).toBeDefined()
  expect(JSON.stringify((await ui.find({ key: 'footer-keys' }))?.props)).not.toMatch(/approve/i)
  await ui.unmount()
})

test('a file edited between preview and press says changed since preview and records nothing; Preview again re-captures and then Approve records', async (driver, on) => {
  const pane = await paneWorld(on, { files: figmaRecipe() })
  await preview(driver, FIGMA)
  const ui = await mount(driver)
  pane.w.write(`${ROOT}/figma-files/fetch.sh`, `${SCRIPT}echo extra\n`)
  await ui.press({ key: 'approve' })
  await until(ui, async () => (await ui.find({ text: /Changed since preview/ })) !== undefined)
  expect(await ui.find({ text: /Changed since preview/ })).toBeDefined()
  expect(pane.storeText()).toBe('null')
  expect(await ui.find({ key: 'preview-again' })).toBeDefined()
  await ui.press({ key: 'preview-again' })
  await until(ui, async () => (await ui.find({ text: /Changed since preview/ })) === undefined && (await ui.find({ key: 'review-toggle-files' })) !== undefined)
  await showFiles(ui)
  expect(await ui.find({ text: /Changed since preview/ })).toBeUndefined()
  expect(await textOf(ui)).toContain('echo extra')
  await ui.press({ key: 'approve' })
  await until(ui, async () => (await ui.find({ text: /recipe figma-files · approved/ })) !== undefined)
  const loaded = await loadRecipe(pane.w.io, ROOT, 'figma-files')
  if (!loaded.ok) throw new Error('fixture does not load')
  expect(pane.w.store[APPROVALS_KEY]).toEqual({ 'figma-files': { digest: loaded.digest, files: loaded.files } })
  await ui.unmount()
})

test('covers AE6: an approval marker the agent writes into the folder leaves the recipe a draft, and an edit after approval returns it to draft', async (driver, on) => {
  const pane = await paneWorld(on, { files: figmaRecipe({}, { '.approved': 'yes', 'approval.json': '{"approved":true}' }) })
  await peek(driver, FIGMA)
  let ui = await mount(driver)
  expect(await ui.find({ text: 'Figma web page' })).toBeDefined()
  expect(pane.scripts()).toEqual([])
  await ui.unmount()
  await preview(driver, FIGMA)
  ui = await mount(driver)
  expect(await ui.find({ text: /recipe figma-files · draft/ })).toBeDefined()
  await ui.press({ key: 'approve' })
  await until(ui, async () => (await ui.find({ text: /recipe figma-files · approved/ })) !== undefined)
  await ui.unmount()
  pane.w.write(`${ROOT}/figma-files/fetch.sh`, `${SCRIPT}echo edited\n`)
  await peek(driver, FIGMA)
  ui = await mount(driver)
  expect(await ui.find({ text: 'Figma web page' })).toBeDefined()
  expect(await ui.find({ text: 'Design system' })).toBeUndefined()
  await ui.unmount()
  await preview(driver, FIGMA)
  ui = await mount(driver)
  expect(await ui.find({ text: /recipe figma-files · draft/ })).toBeDefined()
  expect(await ui.find({ key: 'approve' })).toBeDefined()
  await ui.unmount()
})

test('a hover-layer message and /peek record nothing', async (driver, on) => {
  const pane = await paneWorld(on, { files: figmaRecipe() })
  await preview(driver, FIGMA)
  const ui = await mount(driver)
  const posts: Record<string, string | boolean>[] = [{ approve: 'figma-files' }, { approve: true }, { open: FIGMA }, { toggle: FIGMA }, { star: '' }]
  for (const data of posts) for (const layer of ['tabs-left', 'tabs-right']) await ui.post(data, { in: layer })
  await driver.command.run({ command: 'peek', args: FIGMA } as never)
  await ui.redraw()
  expect(pane.storeText()).toBe('null')
  await ui.unmount()
})

test('the guard denies a file tool on the real store file, and lets a write elsewhere through', async (driver, on) => {
  const pane = await paneWorld(on, { files: { ...figmaRecipe(), '/repo/link-to-store': { link: STORE_DIR } } })
  await preview(driver, FIGMA)
  const ui = await mount(driver)
  await ui.press({ key: 'approve' })
  await until(ui, async () => (await ui.find({ text: /recipe figma-files · approved/ })) !== undefined)
  await ui.unmount()
  const names = (await pane.w.io.list(STORE_DIR)).map(one => one.name)
  const holding: string[] = []
  for (const name of names) {
    const { base64 } = await pane.w.io.readBytes(`${STORE_DIR}/${name}`)
    if (atob(base64).includes(APPROVALS_KEY)) holding.push(`${STORE_DIR}/${name}`)
  }
  expect(holding).toEqual([STORE_FILE])
  const [file = ''] = holding
  const denied = [
    await write(driver, { tool: 'Write', file_path: file, content: '{}' }),
    await write(driver, { tool: 'Edit', file_path: file, old_string: 'a', new_string: 'b' }),
    await write(driver, { tool: 'MultiEdit', file_path: file, edits: [] }),
    await write(driver, { tool: 'NotebookEdit', notebook_path: file, new_source: '' }),
    await write(driver, { tool: 'Write', file_path: '/repo/link-to-store/peek_3f9a2c71.json', content: '{}' }),
    await write(driver, { tool: 'Write', file_path: `${STORE_DIR}/peek_new.json`, content: '{}' }),
    await write(driver, { tool: 'Write', file_path: `${HOME}/.claude/plugins/store/../store/peek_3f9a2c71.json`, content: '{}' }),
    await write(driver, { tool: 'Write', file_path: `/nowhere/at/all/../../..${STORE_DIR}/peek_new.json`, content: '{}' }),
  ]
  for (const answer of denied) expect(answer).toMatch(/peek's approval store/)
  expect(pane.writes).toEqual([])
  const allowed = await write(driver, { tool: 'Write', file_path: '/repo/notes.md', content: 'hi' })
  const other = await write(driver, { tool: 'Write', file_path: `${STORE_DIR}/other_plugin.json`, content: '{}' })
  expect(allowed).not.toMatch(/approval store/)
  expect(other).not.toMatch(/approval store/)
  expect(pane.writes).toEqual(['/repo/notes.md', `${STORE_DIR}/other_plugin.json`])
})

test('the guard follows CLAUDE_CONFIG_DIR when it is set', async (driver, on) => {
  const config = '/cfg/claude'
  const pane = await paneWorld(on, { files: figmaRecipe(), env: { CLAUDE_CONFIG_DIR: config }, storeDir: `${config}/plugins/store` })
  expect(await write(driver, { tool: 'Write', file_path: `${config}/plugins/store/peek_3f9a2c71.json`, content: '{}' })).toMatch(/peek's approval store/)
  await write(driver, { tool: 'Write', file_path: STORE_FILE, content: '{}' })
  expect(pane.writes).toEqual([STORE_FILE])
})

test('on re-approval after an edit, only the changed file is shown as changed', async (driver, on) => {
  const pane = await paneWorld(on, { files: figmaRecipe({}, { 'notes.txt': 'unchanged notes body\n' }), approve: ['figma-files'] })
  pane.w.write(`${ROOT}/figma-files/fetch.sh`, `${SCRIPT}echo second\n`)
  await preview(driver, FIGMA)
  const ui = await mount(driver)
  await showFiles(ui)
  const tree = await textOf(ui)
  expect(tree).toContain('Changed file: fetch.sh')
  expect(tree).toContain('echo second')
  expect(tree).not.toContain('unchanged notes body')
  expect(tree).not.toContain('recipe.json')
  expect(tree).not.toContain('New file')
  await ui.unmount()
})

// The world cannot hold an empty folder, so the approval is given a digest that no longer matches while every
// file hash still does: the state an added empty folder leaves.
test('a digest that moved with no file changed says the folder structure changed rather than showing no change', async (driver, on) => {
  const pane = await paneWorld(on, { files: figmaRecipe(), approve: ['figma-files'] })
  const approvals = pane.w.store[APPROVALS_KEY] as Record<string, { digest: string; files: Record<string, string> }>
  pane.w.store[APPROVALS_KEY] = { 'figma-files': { ...approvals['figma-files'], digest: 'moved' } }
  await preview(driver, FIGMA)
  const ui = await mount(driver)
  const tree = await textOf(ui)
  expect(tree).toContain('Folder structure changed')
  expect(tree).not.toContain('Changed file')
  expect(tree).not.toContain('New file')
  expect(tree).not.toMatch(/No change/i)
  expect(await ui.find({ key: 'approve' })).toBeDefined()
  await ui.unmount()
})

test('a second recipe overlapping an approved one: the surface names it and Approve refuses, naming the other recipe', async (driver, on) => {
  const pane = await paneWorld(on, { files: { ...figmaRecipe(), ...allFigma() }, approve: ['figma-files'] })
  await preview(driver, PROTO)
  const ui = await mount(driver)
  expect(await ui.find({ text: /recipe figma-all · draft/ })).toBeDefined()
  const tree = await textOf(ui)
  expect(tree).toContain('Overlaps approved recipe \\"figma-files\\"')
  expect(tree.indexOf('Overlaps approved recipe')).toBeLessThan(tree.indexOf('"approve"'))
  await ui.press({ key: 'approve' })
  await until(ui, async () => (await ui.find({ text: /Not approved:/ })) !== undefined)
  expect(await textOf(ui)).toMatch(/Not approved: its links overlap approved recipe \\"figma-files\\"/)
  expect(Object.keys(pane.w.store[APPROVALS_KEY] as object)).toEqual(['figma-files'])
  await ui.unmount()
})

test('an overlapping recipe approved after the preview still makes Approve refuse', async (driver, on) => {
  const pane = await paneWorld(on, { files: { ...figmaRecipe(), ...allFigma() } })
  await preview(driver, PROTO)
  const ui = await mount(driver)
  expect(await textOf(ui)).not.toContain('Overlaps approved recipe')
  await approve(pane.w, 'figma-files')
  await ui.press({ key: 'approve' })
  await until(ui, async () => (await ui.find({ text: /Not approved:/ })) !== undefined)
  expect(await textOf(ui)).toContain('figma-files')
  expect(Object.keys(pane.w.store[APPROVALS_KEY] as object)).toEqual(['figma-files'])
  await ui.unmount()
})

test("an overriding recipe's surface shows overrides: github before Approve", async (driver, on) => {
  const files = folder('gh-pulls', { name: 'Pull pages', match: [{ host: 'github.com', path: '/*/pull/*' }], overrides: ['github'], source: { run: ['./fetch.sh'] } }, { 'fetch.sh': '#!/bin/sh\n' })
  await paneWorld(on, { files })
  await preview(driver, PR)
  const ui = await mount(driver)
  const tree = await textOf(ui)
  expect(tree).toContain('Overrides: github')
  expect(tree.indexOf('Overrides: github')).toBeLessThan(tree.indexOf('"approve"'))
  await ui.unmount()
})

test('an MCP recipe calling create_comment shows the server, tool, arguments and the mutating warning, even when its page failed', async (driver, on) => {
  const map = '#!/usr/bin/env python3\nimport json, sys\nprint(json.dumps({"title": json.load(sys.stdin)["text"], "sections": []}))\n'
  const files = folder('figma-comments', { source: { mcp: { server: 'figma', tool: 'create_comment', args: { fileKey: 'abc' } }, map: ['./map.py'] } }, { 'map.py': map })
  await paneWorld(on, { files })
  await preview(driver, FIGMA)
  const ui = await mount(driver)
  await until(ui, async () => (await ui.find({ text: /Recipe page failed/ })) !== undefined)
  await showFiles(ui)
  const tree = await textOf(ui)
  expect(tree).toContain('MCP server \\"figma\\", tool \\"create_comment\\" (mcp__figma__create_comment)')
  expect(tree).toContain('fileKey')
  expect(tree).toContain('then maps its result through ./map.py <link>')
  expect(tree).toContain('New file: map.py')
  expect(tree.indexOf('json.load(sys.stdin)')).toBeGreaterThan(-1)
  expect(tree.indexOf('json.load(sys.stdin)')).toBeLessThan(tree.indexOf('"approve"'))
  expect(tree).toMatch(/looks like it changes something/)
  expect(tree.indexOf('looks like it changes something')).toBeLessThan(tree.indexOf('"approve"'))
  expect(await ui.find({ key: 'approve' })).toBeDefined()
  await ui.unmount()
})

test('a script line that reaches outside the folder is named; the shebang and a URL are not', async (driver, on) => {
  const script = '#!/bin/sh\nsource ~/.secrets\npython3 ../shared/tool.py\ncat /etc/hosts\ncurl https://example.com/a/b\ncd ..\n'
  await paneWorld(on, { files: figmaRecipe({}, { 'fetch.sh': script }) })
  await preview(driver, FIGMA)
  const ui = await mount(driver)
  const tree = await textOf(ui)
  const warnings = tree.match(/fetch\.sh line \d+ reaches outside the folder/g) ?? []
  expect(warnings).toEqual([
    'fetch.sh line 2 reaches outside the folder',
    'fetch.sh line 3 reaches outside the folder',
    'fetch.sh line 4 reaches outside the folder',
    'fetch.sh line 6 reaches outside the folder',
  ])
  await ui.unmount()
})

test('a non-text file is marked binary with its size, not drawn', async (driver, on) => {
  await paneWorld(on, { files: figmaRecipe({}, { 'logo.png': new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0, 1, 2, 3, 0xff, 0xfe]) }) })
  await preview(driver, FIGMA)
  const ui = await mount(driver)
  expect(await textOf(ui)).toContain('Binary file: logo.png (10 bytes)')
  await ui.unmount()
})

test('a normal open of a draft never shows the approval surface', async (driver, on) => {
  await paneWorld(on, { files: figmaRecipe() })
  await peek(driver, FIGMA)
  const ui = await mount(driver)
  expect(await ui.find({ key: 'approve' })).toBeUndefined()
  expect(await ui.find({ text: /Draft recipe/ })).toBeUndefined()
  await ui.unmount()
})
