import { describe, expect, test } from 'claude-code/testing'

import { nav, pressLink, show } from '../hooks/navigation'
import type { NavIo } from '../hooks/navigation'
import { proseParts } from '../hooks/pane/screens/view/prose'
import type { ProsePart } from '../hooks/pane/screens/view/prose'
import { loadRecipe } from '../hooks/recipes/recipes'
import { tickPage } from '../hooks/recipes/session'
import { checkRecipeTool } from '../hooks/recipes/tools'
import { resetRefresh } from '../hooks/refresh'
import { RECIPE_RECORDS, readRecipeCache, recipeCacheFile, recordsOfPage, writeRecipeCache } from '../hooks/views/recipe-source'
import type { Item } from '../hooks/views/items'
import type { Page } from '../hooks/recipes/page'
import { cacheFaults, cacheNav, written } from './fixtures/recipes/cache-nav'
import { approve, gate, recipeNav, until } from './fixtures/recipes/nav'
import { HOME, ROOT, folder, world } from './fixtures/recipes/world'

const FIGMA = 'https://figma.com/file/abc/Design'
const io = cacheNav

const LINKED: Page = {
  title: 'Design system',
  sections: [
    { heading: 'Files', block: { type: 'list', items: [{ title: 'Tokens file', href: 'https://figma.com/file/tokens' }, { title: 'Scratch without a link' }] } },
    { heading: 'Boards', block: { type: 'cards', items: [{ title: 'Launch board', href: 'https://figma.com/file/board' }] } },
    { heading: 'Specs', block: { type: 'table', columns: ['Name', 'Owner'], rows: [{ cells: ['Spec A', 'Ann'], href: 'https://figma.com/file/spec' }, { cells: ['Loose row', 'Bo'] }] } },
    { heading: 'Notes', block: { type: 'markdown', text: 'See [the brief](https://figma.com/file/brief)' } },
  ],
}

const figmaRecipe = (recipe: Record<string, unknown> = {}) =>
  folder('figma-files', { source: { run: ['./fetch.sh'] }, ...recipe }, { 'fetch.sh': '#!/bin/sh\necho page\n' })

async function session(options: { files: Parameters<typeof world>[0]['files']; approved?: string[]; hold?: (url: string) => Promise<void> | undefined }) {
  resetRefresh()
  written.clear()
  cacheFaults.isMoveFailing = false
  cacheFaults.isWriteFailing = false
  const w = world({ files: options.files, script: () => ({ stdout: JSON.stringify(LINKED) }) })
  for (const id of options.approved ?? []) await approve(w, id)
  const active = recipeNav.use(w, { hold: options.hold })
  return { w, scripts: () => active.started }
}

const el = (type: string) => (props: Record<string, unknown>) => {
  const { children, ...rest } = props
  return { type, props: rest, children: [children].flat(Infinity).filter(one => one !== undefined && one !== null && one !== false && one !== true) }
}

const palette = new Proxy({}, { get: () => '#888888' })

const ctx = {
  Box: el('Box'),
  Text: el('Text'),
  Button: el('Button'),
  Markdown: el('Markdown'),
  Code: el('Code'),
  C: palette,
  isMenuOpen: false,
  textWidth: 80,
  current: { href: 'peek://group/launch', title: 'Launch', location: 'Launch' },
} as never

type Node = { type: string; props: Record<string, unknown>; children: unknown[] }

function textOf(node: unknown): string {
  if (typeof node === 'string' || typeof node === 'number') return String(node)
  if (!node || typeof node !== 'object') return ''
  const { type, props, children } = node as Node
  if (type === 'Button') return String(props.label ?? '')
  return children.map(textOf).join(type === 'Text' ? '' : '\n')
}

const TASK: Item = { id: 't1', href: '/repo/.peek/tasks/t1.md', type: 'task', name: 'A task, not a record', props: { status: 'todo' }, source: 'task-folder' }

const fence = (info: string) => `Launch notes\n\n\`\`\`peek-list ${info}\n\`\`\`\n`

async function drawBlock(info = `recipe=figma-files url=${FIGMA}`, through: NavIo = io): Promise<{ text: string; parts: ProsePart[] }> {
  const parts = await proseParts(ctx, { ...through, cursor: { read: async () => -1, update: io.cursor.update } }, 'group-description', fence(info), {
    picture: () => null,
    items: () => [TASK],
  })
  return { text: parts.map(part => textOf(part.node)).join('\n'), parts }
}

// Every path a draw reads, lists, stats, writes or hands to a command.
function watched(): { io: NavIo; paths: string[]; reads: string[] } {
  const paths: string[] = []
  const reads: string[] = []
  const recipesIo = () => {
    const inner = recipeNav.runIo()
    return {
      ...inner,
      list: async (dir: string) => (paths.push(dir), inner.list(dir)),
      readBytes: async (path: string) => (paths.push(path), reads.push(path), inner.readBytes(path)),
      statResolved: async (path: string) => (paths.push(path), inner.statResolved(path)),
    }
  }
  return {
    paths,
    reads,
    io: {
      ...io,
      recipesIo,
      runIo: recipesIo,
      readFile: async path => (paths.push(path), io.readFile(path)),
      writeFile: async (path, text) => (paths.push(path), io.writeFile(path, text)),
      run: async (argv, init) => (paths.push(...argv), io.run(argv, init)),
    },
  }
}

const cacheFiles = () => [...written.keys()].filter(path => path.includes('/recipe-cache/') && path.endsWith('.json'))

async function digestOf(w: ReturnType<typeof world>) {
  const loaded = await loadRecipe(w.io, ROOT, 'figma-files')
  if (!loaded.ok) throw new Error('fixture recipe does not load')
  return loaded.digest
}

describe('a recipe-backed block', () => {
  test('opening a group whose description holds a recipe block does not run the recipe, and draws one Open to load row', async () => {
    const { scripts } = await session({ files: figmaRecipe(), approved: ['figma-files'] })
    const { text, parts } = await drawBlock()
    expect(scripts()).toEqual([])
    expect(cacheFiles()).toEqual([])
    expect(text).toContain('Open to load')
    expect(text).not.toContain('A task, not a record')
    expect(parts.flatMap(part => part.nav ?? []).map(one => one.href)).toEqual([FIGMA])
  })

  test('Enter on Open to load runs the recipe once, even when pressed twice, and fills the cache', async () => {
    const run = gate()
    const { w, scripts } = await session({ files: figmaRecipe(), approved: ['figma-files'], hold: () => run.held })
    const href = (await drawBlock()).parts.flatMap(part => part.nav ?? [])[0]?.href ?? ''
    const first = pressLink(io, href)
    const second = pressLink(io, href)
    await until(() => scripts().length > 0)
    run.release()
    await Promise.all([first, second])
    expect(scripts()).toEqual([FIGMA])
    const cache = await readRecipeCache(io, 'figma-files', FIGMA)
    expect(cache?.digest).toBe(await digestOf(w))
    expect(cache?.records.map(one => one.name)).toEqual(['Tokens file', 'Launch board', 'Spec A | Ann'])
  })

  test('after the run the block draws the page rows that have a link, with how long ago they were fetched', async () => {
    const { w, scripts } = await session({ files: figmaRecipe(), approved: ['figma-files'] })
    await show(io, FIGMA)
    w.advance(3 * 60_000)
    const { text, parts } = await drawBlock()
    expect(text).toContain('Tokens file')
    expect(text).toContain('Launch board')
    expect(text).toContain('Spec A | Ann')
    expect(text).not.toContain('Scratch without a link')
    expect(text).not.toContain('Loose row')
    expect(text).not.toContain('Open to load')
    expect(text).toContain('fetched 3m ago')
    expect(parts.flatMap(part => part.nav ?? []).map(one => one.href).toSorted()).toEqual(['https://figma.com/file/board', 'https://figma.com/file/spec', 'https://figma.com/file/tokens'])
    expect(scripts()).toEqual([FIGMA])
  })

  test("the fence's rule options still select among the recipe's rows", async () => {
    await session({ files: figmaRecipe(), approved: ['figma-files'] })
    await show(io, FIGMA)
    const { text } = await drawBlock(`recipe=figma-files url=${FIGMA} section=Boards`)
    expect(text).toContain('Launch board')
    expect(text).not.toContain('Tokens file')
  })

  test('a block naming a draft recipe draws one error row naming it, never runs it, and ignores a cache for it', async () => {
    const { w, scripts } = await session({ files: figmaRecipe() })
    await writeRecipeCache(io, { recipe: 'figma-files', link: FIGMA, digest: await digestOf(w), fetchedAt: w.now(), records: recordsOfPage(LINKED, 'figma-files') })
    const { text, parts } = await drawBlock()
    expect(text).toContain('figma-files')
    expect(text).toContain('draft')
    expect(text).not.toContain('Tokens file')
    expect(text).not.toContain('Open to load')
    expect(parts.flatMap(part => part.nav ?? [])).toEqual([])
    expect(scripts()).toEqual([])
  })

  test('a block naming a recipe that does not exist draws one error row naming it', async () => {
    const { scripts } = await session({ files: figmaRecipe(), approved: ['figma-files'] })
    const { text } = await drawBlock(`recipe=no-such url=${FIGMA}`)
    expect(text).toContain('no-such')
    expect(text).not.toContain('Open to load')
    expect(scripts()).toEqual([])
  })

  test('a block without a url draws one error row, since a recipe always runs against a link', async () => {
    await session({ files: figmaRecipe(), approved: ['figma-files'] })
    const { text } = await drawBlock('recipe=figma-files')
    expect(text).toContain('url=')
    expect(text).not.toContain('Open to load')
  })

  test('a cache written under an older recipe digest draws Open to load, not its rows', async () => {
    const { w } = await session({ files: figmaRecipe(), approved: ['figma-files'] })
    await writeRecipeCache(io, { recipe: 'figma-files', link: FIGMA, digest: 'an-older-digest', fetchedAt: w.now(), records: recordsOfPage(LINKED, 'figma-files') })
    const { text } = await drawBlock()
    expect(text).toContain('Open to load')
    expect(text).not.toContain('Tokens file')
  })

  test('a cache slot holding another link of the same recipe reads as no cache', async () => {
    const { w } = await session({ files: figmaRecipe(), approved: ['figma-files'] })
    await writeRecipeCache(io, { recipe: 'figma-files', link: FIGMA, digest: await digestOf(w), fetchedAt: w.now(), records: recordsOfPage(LINKED, 'figma-files') })
    const [file = ''] = cacheFiles()
    written.set(file, (written.get(file) ?? '').replace(JSON.stringify(FIGMA), JSON.stringify('https://figma.com/file/other/X')))
    expect(await readRecipeCache(io, 'figma-files', FIGMA)).toBe(null)
    expect((await drawBlock()).text).toContain('Open to load')
  })

  test('a cache file that does not parse reads as no cache', async () => {
    const { w } = await session({ files: figmaRecipe(), approved: ['figma-files'] })
    await writeRecipeCache(io, { recipe: 'figma-files', link: FIGMA, digest: await digestOf(w), fetchedAt: w.now(), records: recordsOfPage(LINKED, 'figma-files') })
    const [file] = cacheFiles()
    written.set(file ?? '', '{"recipe": "figma-fi')
    expect(await readRecipeCache(io, 'figma-files', FIGMA)).toBe(null)
    expect((await drawBlock()).text).toContain('Open to load')
  })
})

describe('a recipe block and the link it names', () => {
  const ghPages = () => folder('gh-pages', { name: 'GitHub pages', match: [{ host: 'github.com' }], source: { run: ['./fetch.sh'] } }, { 'fetch.sh': '#!/bin/sh\n' })
  const figmaAll = () => folder('figma-all', { name: 'All of Figma', match: [{ host: 'figma.com' }], source: { run: ['./all.sh'] } }, { 'all.sh': '#!/bin/sh\n' })

  test('a link the recipe does not match draws one error row naming the recipe, not Open to load', async () => {
    await session({ files: figmaRecipe(), approved: ['figma-files'] })
    const { text, parts } = await drawBlock('recipe=figma-files url=https://example.com/notes')
    expect(text).toContain('figma-files')
    expect(text).toContain('does not handle https://example.com/notes')
    expect(text).not.toContain('Open to load')
    expect(parts.flatMap(part => part.nav ?? [])).toEqual([])
  })

  test('a link a built-in page keeps, because the recipe does not override it, draws the error row', async () => {
    await session({ files: ghPages(), approved: ['gh-pages'] })
    const { text } = await drawBlock('recipe=gh-pages url=https://github.com/acme/widgets/pull/42')
    expect(text).toContain('gh-pages')
    expect(text).toContain('does not handle')
    expect(text).not.toContain('Open to load')
  })

  test('a link two approved recipes both claim draws the error row naming both', async () => {
    await session({ files: { ...figmaRecipe(), ...figmaAll() }, approved: ['figma-files', 'figma-all'] })
    const { text } = await drawBlock()
    expect(text).toContain('figma-all')
    expect(text).not.toContain('Open to load')
  })

  test('a hostile recipe id draws an error row and touches nothing outside the recipes folder', async () => {
    await session({ files: figmaRecipe(), approved: ['figma-files'] })
    const seen = watched()
    for (const id of ['../x', '../../.ssh', 'figma-files/../../x']) {
      const { text } = await drawBlock(`recipe=${id} url=${FIGMA}`, seen.io)
      expect(text).not.toContain('Open to load')
      expect(text).toContain(id)
    }
    expect(seen.paths.filter(path => path !== ROOT && !path.startsWith(`${ROOT}/`))).toEqual([])
  })

  test('a second draw over unchanged recipe files reads none of them; a changed file is read again', async () => {
    // A file no other test writes, so what an earlier draw remembered cannot stand in for this first read.
    const files = folder('figma-files', { source: { run: ['./fetch.sh'] } }, { 'fetch.sh': '#!/bin/sh\necho page\n', 'notes.txt': 'only in this test' })
    const { w } = await session({ files, approved: ['figma-files'] })
    const seen = watched()
    await drawBlock(undefined, seen.io)
    expect(seen.reads.length).toBeGreaterThan(0)
    seen.reads.length = 0
    expect((await drawBlock(undefined, seen.io)).text).toContain('Open to load')
    expect(seen.reads).toEqual([])
    w.write(`${ROOT}/figma-files/fetch.sh`, '#!/bin/sh\necho a longer page\n')
    const { text } = await drawBlock(undefined, seen.io)
    expect(seen.reads).toContain(`${ROOT}/figma-files/fetch.sh`)
    expect(text).toContain('draft')
  })
})

describe('the recipe cache', () => {
  test('a draft run, from the pane or from check_recipe, writes no cache', async () => {
    await session({ files: figmaRecipe() })
    await show(io, FIGMA, false, { allowDraft: true })
    expect(((await io.view.read())?.page)?.phase).toBe('ready')
    const checked = await checkRecipeTool(io, { recipe: 'figma-files', link: FIGMA })
    expect(checked.result.startsWith('Check passed')).toBe(true)
    expect(cacheFiles()).toEqual([])
  })

  test('a cache that cannot be moved into place still lets the page and check_recipe pass, and leaves no temporary file', async () => {
    await session({ files: figmaRecipe(), approved: ['figma-files'] })
    cacheFaults.isMoveFailing = true
    await show(io, FIGMA)
    expect(((await io.view.read())?.page)?.phase).toBe('ready')
    const checked = await checkRecipeTool(io, { recipe: 'figma-files', link: FIGMA })
    expect(checked.result.startsWith('Check passed')).toBe(true)
    expect([...written.keys()]).toEqual([])
  })

  test('a cache that cannot be written still lets the page and check_recipe pass', async () => {
    await session({ files: figmaRecipe(), approved: ['figma-files'] })
    cacheFaults.isWriteFailing = true
    await show(io, FIGMA)
    expect(((await io.view.read())?.page)?.phase).toBe('ready')
    expect((await checkRecipeTool(io, { recipe: 'figma-files', link: FIGMA })).result.startsWith('Check passed')).toBe(true)
    expect([...written.keys()]).toEqual([])
  })

  test('two keys that share a slot: the later write wins and the earlier key reads as no cache', async () => {
    const { w } = await session({ files: figmaRecipe(), approved: ['figma-files'] })
    const slot = await recipeCacheFile(HOME, 'figma-files', FIGMA)
    let other = ''
    for (let i = 0; i < 2000 && !other; i++) {
      const link = `https://figma.com/file/n${i}/X`
      if ((await recipeCacheFile(HOME, 'figma-files', link)) === slot) other = link
    }
    expect(other).not.toBe('')
    const digest = await digestOf(w)
    await writeRecipeCache(io, { recipe: 'figma-files', link: FIGMA, digest, fetchedAt: w.now(), records: recordsOfPage(LINKED, 'figma-files') })
    await writeRecipeCache(io, { recipe: 'figma-files', link: other, digest, fetchedAt: w.now(), records: [] })
    expect(await readRecipeCache(io, 'figma-files', FIGMA)).toBe(null)
    expect((await readRecipeCache(io, 'figma-files', other))?.link).toBe(other)
    expect(cacheFiles()).toEqual([slot])
  })

  test('rows without a link are skipped; each kept row carries the recipe id and its section title', () => {
    const records = recordsOfPage(LINKED, 'figma-files')
    expect(records.map(one => [one.name, one.href, one.props?.recipe, one.props?.section])).toEqual([
      ['Tokens file', 'https://figma.com/file/tokens', 'figma-files', 'Files'],
      ['Launch board', 'https://figma.com/file/board', 'figma-files', 'Boards'],
      ['Spec A | Ann', 'https://figma.com/file/spec', 'figma-files', 'Specs'],
    ])
  })

  test('a page with more linked rows than the cap keeps the first ones', () => {
    const many: Page = { title: 'Many', sections: [{ block: { type: 'list', items: Array.from({ length: RECIPE_RECORDS + 7 }, (_, i) => ({ title: `Row ${i}`, href: `https://figma.com/file/${i}` })) } }] }
    const records = recordsOfPage(many, 'figma-files')
    expect(records.length).toBe(RECIPE_RECORDS)
    expect(records[0]?.name).toBe('Row 0')
  })

  test('the cache is written to a temporary file and moved into place, under the peek state folder', async () => {
    const { w } = await session({ files: figmaRecipe(), approved: ['figma-files'] })
    await writeRecipeCache(io, { recipe: 'figma-files', link: FIGMA, digest: 'd1', fetchedAt: w.now(), records: [] })
    const [file] = cacheFiles()
    expect(file?.startsWith('/home/u/.local/share/claude-peek/recipe-cache/')).toBe(true)
    expect([...written.keys()].filter(path => path.endsWith('.tmp'))).toEqual([])
    expect((await readRecipeCache(io, 'figma-files', FIGMA))?.digest).toBe('d1')
  })

  test('the opted-in timer refreshes the cache while the recipe page is open, and nothing refreshes it once another page shows', async () => {
    const { w, scripts } = await session({ files: figmaRecipe({ refreshMinutes: 5 }), approved: ['figma-files'] })
    await show(io, FIGMA)
    const opened = (await readRecipeCache(io, 'figma-files', FIGMA))?.fetchedAt ?? 0
    for (let minute = 0; minute < 6; minute++) {
      nav.lastActivity = w.now()
      w.advance(60_000)
      await tickPage(io)
    }
    expect(scripts()).toEqual([FIGMA, FIGMA])
    const ticked = (await readRecipeCache(io, 'figma-files', FIGMA))?.fetchedAt ?? 0
    expect(ticked).toBeGreaterThan(opened)
    await show(io, 'https://example.com/other')
    for (let minute = 0; minute < 12; minute++) {
      nav.lastActivity = w.now()
      w.advance(60_000)
      await tickPage(io)
    }
    expect(scripts()).toEqual([FIGMA, FIGMA])
    expect((await readRecipeCache(io, 'figma-files', FIGMA))?.fetchedAt).toBe(ticked)
  })

  test('check_recipe running an approved recipe fills the cache for its link', async () => {
    const { w } = await session({ files: figmaRecipe(), approved: ['figma-files'] })
    const checked = await checkRecipeTool(io, { recipe: 'figma-files', link: FIGMA })
    expect(checked.result.startsWith('Check passed')).toBe(true)
    const cache = await readRecipeCache(io, 'figma-files', FIGMA)
    expect(cache?.digest).toBe(await digestOf(w))
    expect(cache?.records.length).toBe(3)
  })
})
