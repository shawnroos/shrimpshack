import { describe, expect, test } from 'claude-code/testing'

import { nav, openExternally, pressLink, refresh, show } from '../hooks/navigation'
import { APPROVALS_KEY } from '../hooks/recipes/recipes'
import { approveRecipe, tickPage, toggleReviewFiles } from '../hooks/recipes/session'
import { openTool } from '../hooks/recipes/tools'
import { pageView } from '../hooks/recipes/state'
import { BACKGROUND_MS, cached, refreshItem, resetRefresh, snapshotTitles } from '../hooks/refresh'
import type { RemoteRecord, View } from '../types'
import type { RecipePage } from '../types/recipes'
import { approve, gate, recipeNav, until } from './fixtures/recipes/nav'
import { ROOT, folder, world } from './fixtures/recipes/world'
import type { ScriptAnswer } from './fixtures/recipes/world'

const FIGMA = 'https://figma.com/file/abc/Design'
const SLOW = 'https://figma.com/file/slow/Design'
const PR = 'https://github.com/acme/widgets/pull/42'

const io = recipeNav.io

const designPage = { title: 'Design system', sections: [{ heading: 'Notes', block: { type: 'markdown', text: 'Tokens and type.' } }] }
const answer = (page: Record<string, unknown>): ScriptAnswer => ({ stdout: JSON.stringify(page) })

const figmaRecipe = (recipe: Record<string, unknown> = {}) =>
  folder('figma-files', { source: { run: ['./fetch.sh'] }, ...recipe }, { 'fetch.sh': '#!/bin/sh\necho page\n' })
const timedRecipe = () => figmaRecipe({ refreshMinutes: 5 })
const figmaAll = () => folder('figma-all', { name: 'All of Figma', match: [{ host: 'figma.com' }], source: { run: ['./all.sh'] } }, { 'all.sh': '#!/bin/sh\n' })

type Options = { files: ReturnType<typeof figmaRecipe>; approved?: string[]; pages?: (url: string) => ScriptAnswer } & Parameters<typeof recipeNav.use>[1]

async function session(options: Options) {
  resetRefresh()
  const w = world({ files: options.files, script: child => (options.pages ? options.pages(child.env.PEEK_URL ?? '') : answer(designPage)) })
  for (const id of options.approved ?? []) await approve(w, id)
  const active = recipeNav.use(w, { hold: options.hold, holdList: options.holdList, refuseView: options.refuseView })
  return { w, active, scripts: () => active.started }
}

const shown = async () => (await io.view.read()) as View
const pageOf = async () => (await shown()).page as RecipePage

// A minute of a person working with the pane, as the ticker sees it: activity, then the clock, then the tick's run.
async function stayActive(w: ReturnType<typeof world>, minutes: number) {
  for (let minute = 0; minute < minutes; minute++) {
    nav.lastActivity = w.now()
    w.advance(60_000)
    await tickPage(io)
  }
}

describe('opening a link a recipe handles', () => {
  test('an approved recipe opens its link as a page view, and two opens at once run its script once', async () => {
    const run = gate()
    const { scripts } = await session({ files: figmaRecipe(), approved: ['figma-files'], hold: () => run.held })
    const first = show(io, FIGMA)
    const second = show(io, FIGMA)
    await until(() => scripts().length > 0)
    run.release()
    await Promise.all([first, second])
    expect(scripts()).toEqual([FIGMA])
    const view = await shown()
    expect(view.kind).toBe('recipe')
    expect(view.title).toBe('Design system')
    expect(view.page?.phase).toBe('ready')
  })

  test('a loading page names the recipe until the script answers', async () => {
    const run = gate()
    const { scripts } = await session({ files: figmaRecipe(), approved: ['figma-files'], hold: () => run.held })
    const opening = show(io, FIGMA)
    await until(() => scripts().length > 0)
    expect((await pageOf()).phase).toBe('loading')
    expect((await shown()).title).toBe('Figma files')
    run.release()
    await opening
    expect((await pageOf()).phase).toBe('ready')
  })

  test("opening link B while recipe A's script runs leaves B on screen", async () => {
    const run = gate()
    const { scripts } = await session({
      files: figmaRecipe(),
      approved: ['figma-files'],
      hold: url => (url === SLOW ? run.held : undefined),
      pages: url => answer(url === SLOW ? { title: 'Slow file', sections: [] } : designPage),
    })
    const slow = show(io, SLOW)
    await until(() => scripts().length > 0)
    expect(scripts()).toEqual([SLOW])
    await show(io, FIGMA)
    run.release()
    await slow
    expect((await shown()).title).toBe('Design system')
  })

  test("a link opened while an earlier open is still reading its recipes keeps the screen when the earlier one routes", async () => {
    const reading = gate()
    let isFirst = true
    const { scripts } = await session({
      files: figmaRecipe(),
      approved: ['figma-files'],
      holdList: () => {
        if (!isFirst) return undefined
        isFirst = false
        return reading.held
      },
      pages: url => answer(url === SLOW ? { title: 'Slow file', sections: [] } : designPage),
    })
    const slow = show(io, SLOW)
    await until(() => !isFirst)
    await show(io, FIGMA)
    reading.release()
    await slow
    expect(scripts()).toEqual([FIGMA, SLOW])
    expect((await shown()).href).toBe(FIGMA)
    expect((await shown()).title).toBe('Design system')
  })

  test('a draft recipe never runs on a normal open: the link goes where it would without it', async () => {
    const { scripts } = await session({ files: figmaRecipe() })
    await show(io, FIGMA)
    expect(scripts()).toEqual([])
    expect((await shown()).kind).toBe('web')
    expect((await shown()).page).toBeUndefined()
  })

  test('a draft recipe runs when the open allows drafts, and the page says draft', async () => {
    const { scripts } = await session({ files: figmaRecipe() })
    await show(io, FIGMA, false, { allowDraft: true })
    expect(scripts()).toEqual([FIGMA])
    const page = await pageOf()
    expect(page.phase).toBe('ready')
    expect(page.isDraft).toBe(true)
    expect(page.phase !== 'conflict' && page.review !== undefined).toBe(true)
  })

  test("the agent's open runs a draft recipe as a draft page", async () => {
    const { scripts } = await session({ files: figmaRecipe() })
    await openTool(io, FIGMA)
    expect(scripts()).toEqual([FIGMA])
    const page = await pageOf()
    expect(page.phase).toBe('ready')
    expect(page.isDraft).toBe(true)
  })

  test('two approved recipes claiming one link show a conflict naming both, and run neither', async () => {
    const { scripts } = await session({ files: { ...figmaRecipe(), ...figmaAll() }, approved: ['figma-files', 'figma-all'] })
    await show(io, FIGMA)
    const page = await pageOf()
    expect(page.phase).toBe('conflict')
    expect(page.phase === 'conflict' && page.failure).toContain('figma-all')
    expect(page.phase === 'conflict' && page.failure).toContain('figma-files')
    expect(scripts()).toEqual([])
  })

  test("an opened page's title is kept with the other titles", async () => {
    const { w } = await session({ files: figmaRecipe(), approved: ['figma-files'], pages: () => answer({ title: 'Titled once', sections: [] }) })
    await show(io, FIGMA)
    expect(snapshotTitles()[FIGMA]).toMatchObject({ title: 'Titled once', kind: 'web', trail: ['Figma files'] })
    expect((w.store.titles as Record<string, unknown>)[FIGMA]).toBeDefined()
  })
})

describe('refreshing a recipe page', () => {
  test('refresh runs the script again and the page stays a recipe page', async () => {
    const { scripts } = await session({ files: figmaRecipe(), approved: ['figma-files'] })
    await show(io, FIGMA)
    await refresh(io, FIGMA)
    expect(scripts()).toEqual([FIGMA, FIGMA])
    const page = await pageOf()
    expect(page.phase).toBe('ready')
    expect(page.phase !== 'conflict' && page.isRefreshing).toBeUndefined()
  })

  test('two quick refreshes run the script once', async () => {
    let run: ReturnType<typeof gate> | undefined
    const { scripts } = await session({ files: figmaRecipe(), approved: ['figma-files'], hold: () => run?.held })
    await show(io, FIGMA)
    run = gate()
    const first = refresh(io, FIGMA)
    await until(() => scripts().length > 1)
    const refreshing = await pageOf()
    expect(refreshing.phase !== 'conflict' && refreshing.isRefreshing).toBe(true)
    expect((await shown()).title).toBe('Design system')
    const second = refresh(io, FIGMA)
    run.release()
    await Promise.all([first, second])
    expect(scripts()).toEqual([FIGMA, FIGMA])
  })

  test('a refresh that fails keeps the last page and says why', async () => {
    let isBroken = false
    const { scripts } = await session({ files: figmaRecipe(), approved: ['figma-files'], pages: () => (isBroken ? { exitCode: 3, stderr: 'rate limited' } : answer(designPage)) })
    await show(io, FIGMA)
    isBroken = true
    await refresh(io, FIGMA)
    const page = await pageOf()
    expect(page.phase).toBe('ready')
    expect((await shown()).title).toBe('Design system')
    expect(page.phase === 'ready' && page.refreshFailure).toContain('rate limited')
    expect(scripts()).toEqual([FIGMA, FIGMA])
  })

  test('refreshing a page whose recipe was edited since keeps the page, says why, and never falls back to the web reader', async () => {
    const { w, scripts } = await session({ files: figmaRecipe(), approved: ['figma-files'] })
    await show(io, FIGMA)
    w.write(`${ROOT}/figma-files/fetch.sh`, '#!/bin/sh\necho edited\n')
    await refresh(io, FIGMA)
    const page = await pageOf()
    expect(page.phase === 'ready' && page.refreshFailure).toContain('no longer handles this link')
    expect((await shown()).title).toBe('Design system')
    expect((await shown()).kind).toBe('recipe')
    expect(scripts()).toEqual([FIGMA])
  })

  test('refresh on a conflict between two approved recipes keeps the conflict page', async () => {
    const { scripts } = await session({ files: { ...figmaRecipe(), ...figmaAll() }, approved: ['figma-files', 'figma-all'] })
    await show(io, FIGMA)
    await refresh(io, FIGMA)
    expect((await pageOf()).phase).toBe('conflict')
    expect(scripts()).toEqual([])
  })

  test('refresh on a conflict between two drafts the agent opened keeps the draft preview, and a lifted conflict runs the draft', async () => {
    const { w, scripts } = await session({ files: { ...figmaRecipe(), ...figmaAll() } })
    await show(io, FIGMA, false, { allowDraft: true })
    expect((await pageOf()).phase).toBe('conflict')
    await refresh(io, FIGMA)
    expect((await pageOf()).phase).toBe('conflict')
    expect((await pageOf()).isDraft).toBe(true)
    w.write(`${ROOT}/figma-all/recipe.json`, JSON.stringify({ name: 'All of Figma', match: [{ host: 'example.com' }], source: { run: ['./all.sh'] } }))
    await refresh(io, FIGMA)
    const page = await pageOf()
    expect(page.phase).toBe('ready')
    expect(page.isDraft).toBe(true)
    expect(scripts()).toEqual([FIGMA])
  })
})

describe('the timers and a recipe page', () => {
  test('the 15 s tick does not turn an overriding recipe page back into the built-in page', async () => {
    const files = folder('gh-pulls', { name: 'Pull pages', match: [{ host: 'github.com', path: '/*/pull/*' }], overrides: ['github'], source: { run: ['./fetch.sh'] } }, { 'fetch.sh': '#!/bin/sh\n' })
    const { w, scripts } = await session({ files, approved: ['gh-pulls'], pages: () => answer({ title: 'Pull as a recipe', sections: [] }) })
    const record: RemoteRecord = { address: PR, kind: 'gh-pr', title: 'Teach the parser trailing commas', trail: ['acme/widgets'], meta: [], browserUrl: PR }
    await refreshItem(PR, async () => ({ ok: true, record, tier: 'cli', fetchedAt: w.now() }), w.now())
    await show(io, PR)
    expect((await shown()).title).toBe('Pull as a recipe')
    w.advance(BACKGROUND_MS + 30_000)
    nav.lastActivity = w.now()
    expect(recipeNav.tick()).toBeGreaterThan(0)
    await until(() => cached(PR)?.state === 'stale-since')
    expect(cached(PR)?.state).toBe('stale-since')
    await until(async () => (await shown()).title !== 'Pull as a recipe', 20)
    expect((await shown()).title).toBe('Pull as a recipe')
    expect((await shown()).page?.phase).toBe('ready')
    expect(scripts()).toEqual([PR])
  })

  test('an opted-in recipe page re-runs after its minutes on screen', async () => {
    const { w, scripts } = await session({ files: timedRecipe(), approved: ['figma-files'] })
    await show(io, FIGMA)
    await stayActive(w, 4)
    expect(scripts()).toEqual([FIGMA])
    await stayActive(w, 2)
    expect(scripts()).toEqual([FIGMA, FIGMA])
    expect((await pageOf()).phase).toBe('ready')
  })

  test('the 15 s tick runs an opted-in recipe page once its minutes are up', async () => {
    const { w, scripts } = await session({ files: timedRecipe(), approved: ['figma-files'] })
    await show(io, FIGMA)
    w.advance(5 * 60_000 + 1)
    nav.lastActivity = w.now()
    expect(recipeNav.tick()).toBeGreaterThan(0)
    await until(async () => {
      const page = await pageOf()
      return scripts().length === 2 && page.phase === 'ready' && !page.isRefreshing
    })
    expect(scripts()).toEqual([FIGMA, FIGMA])
  })

  test('a recipe with no timer never runs on a tick', async () => {
    const { w, scripts } = await session({ files: figmaRecipe({ refreshMinutes: 0 }), approved: ['figma-files'] })
    await show(io, FIGMA)
    await stayActive(w, 12)
    expect(scripts()).toEqual([FIGMA])
  })

  test('an opted-in recipe page does not run on a timer while another page shows', async () => {
    const { w, scripts } = await session({ files: timedRecipe(), approved: ['figma-files'] })
    await show(io, FIGMA)
    await show(io, 'https://example.com/other')
    await stayActive(w, 12)
    expect(scripts()).toEqual([FIGMA])
  })

  test('an opted-in recipe page does not run on a timer while the pane shows another list', async () => {
    const { w, scripts } = await session({ files: timedRecipe(), approved: ['figma-files'] })
    await show(io, FIGMA)
    await io.mode.update(() => 'recent')
    await stayActive(w, 12)
    expect(scripts()).toEqual([FIGMA])
  })

  test('a draft preview with a timer never runs on a tick', async () => {
    const { w, scripts } = await session({ files: timedRecipe() })
    await show(io, FIGMA, false, { allowDraft: true })
    await stayActive(w, 12)
    expect(scripts()).toEqual([FIGMA])
  })

  test('a failing timed run keeps the last page with its failure and backs off before the next try', async () => {
    let isBroken = false
    const { w, scripts } = await session({ files: timedRecipe(), approved: ['figma-files'], pages: () => (isBroken ? { exitCode: 3, stderr: 'rate limited' } : answer(designPage)) })
    await show(io, FIGMA)
    isBroken = true
    await stayActive(w, 6)
    expect(scripts()).toEqual([FIGMA, FIGMA])
    const failed = await pageOf()
    expect(failed.phase === 'ready' && failed.refreshFailure).toContain('rate limited')
    await stayActive(w, 6)
    expect(scripts()).toEqual([FIGMA, FIGMA])
    isBroken = false
    await stayActive(w, 5)
    expect(scripts()).toEqual([FIGMA, FIGMA, FIGMA])
    const after = await pageOf()
    expect(after.phase === 'ready' && after.refreshFailure).toBeUndefined()
  })

  test('a timed run whose page write fails once does not leave the page refreshing, and the next timed run still goes', async () => {
    let isArmed = false
    let opened = 0
    const refuseView = (view: View | null) => {
      const page = view?.page
      if (!isArmed || page?.phase !== 'ready' || page.isRefreshing || page.fetchedAt === opened) return false
      isArmed = false
      return true
    }
    const { w, scripts } = await session({ files: timedRecipe(), approved: ['figma-files'], refuseView })
    await show(io, FIGMA)
    const page = await pageOf()
    opened = page.phase === 'ready' ? page.fetchedAt : 0
    isArmed = true
    for (let minute = 0; minute < 8 && isArmed; minute++) await stayActive(w, 1).catch(() => undefined)
    expect(isArmed).toBe(false)
    const left = await pageOf()
    expect(left.phase !== 'conflict' && left.isRefreshing).toBeUndefined()
    await stayActive(w, 1)
    expect(scripts()).toEqual([FIGMA, FIGMA, FIGMA])
    const after = await pageOf()
    expect(after.phase !== 'conflict' && after.isRefreshing).toBeUndefined()
    expect(after.phase).toBe('ready')
  })
})

describe('approving a draft from its page', () => {
  test('Approve on an unchanged preview records the digest and files, and the page turns approved', async () => {
    const { w } = await session({ files: figmaRecipe() })
    await show(io, FIGMA, false, { allowDraft: true })
    await io.cursor.update(() => 3)
    await approveRecipe(io, FIGMA)
    const approvals = w.store[APPROVALS_KEY] as Record<string, { digest: string; files: Record<string, string> }>
    const page = await pageOf()
    expect(page.phase !== 'conflict' && approvals['figma-files']?.digest).toBe(page.phase !== 'conflict' ? page.digest : 'none')
    expect(Object.keys(approvals['figma-files']?.files ?? {}).sort()).toEqual(['fetch.sh', 'recipe.json'])
    expect(page.isDraft).toBe(false)
    expect(page.phase !== 'conflict' && page.review).toBeUndefined()
    expect(await io.cursor.read()).toBe(0)
  })

  test('a file edited between preview and Approve records nothing and says changed', async () => {
    const { w } = await session({ files: figmaRecipe() })
    await show(io, FIGMA, false, { allowDraft: true })
    w.write(`${ROOT}/figma-files/fetch.sh`, '#!/bin/sh\necho edited\n')
    await approveRecipe(io, FIGMA)
    expect(w.store[APPROVALS_KEY]).toBeUndefined()
    const page = await pageOf()
    expect(page.isDraft).toBe(true)
    expect(page.phase !== 'conflict' && page.review?.refusal).toEqual({ kind: 'changed' })
  })

  test('Show files toggles the file text on the page on screen', async () => {
    await session({ files: figmaRecipe() })
    await show(io, FIGMA, false, { allowDraft: true })
    await toggleReviewFiles(io, FIGMA)
    const page = await pageOf()
    expect(page.phase !== 'conflict' && page.review?.isShowingFiles).toBe(true)
  })
})

describe('leaving a recipe page', () => {
  test('a link to an absolute path on a recipe page opens that file', async () => {
    const { active } = await session({ files: figmaRecipe(), approved: ['figma-files'] })
    await show(io, FIGMA)
    await pressLink(io, '/repo/notes.md')
    expect(active.loadedUrls).toEqual([])
    expect(await shown()).toEqual({ href: 'file:///repo/notes.md', title: '/repo/notes.md', location: '/repo/notes.md' })
    expect(nav.backStack.at(-1)?.view.page?.phase).toBe('ready')
    nav.backStack.length = 0
  })

  test('Open in browser on a recipe page opens the link the recipe ran on', async () => {
    const { active } = await session({ files: figmaRecipe(), approved: ['figma-files'] })
    const state: RecipePage = { phase: 'conflict', link: FIGMA, isDraft: false, failure: 'two' }
    await openExternally(io, pageView(PR, state))
    expect(active.ran).toEqual([['open', FIGMA]])
  })

  test('the page view carries the recipe state under the link it was opened with', () => {
    const state: RecipePage = { phase: 'conflict', link: FIGMA, isDraft: false, failure: 'two' }
    expect(pageView(FIGMA, state)).toEqual({ href: FIGMA, title: 'Recipe conflict', location: FIGMA, kind: 'recipe', page: state })
  })
})
