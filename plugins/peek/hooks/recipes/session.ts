import type { View } from '../../types'
import type { RecipePage, RecipeRouted, ReviewRefusal } from '../../types/recipes'
import type { Picture } from '../images'
import { remotePicture } from '../images'
import { isWebUrl } from '../live'
import type { NavIo } from '../navigation'
import { downloadFile } from '../net'
import { parseRef } from '../refs'
import { BACKOFF_MAX_MS, notePageTitle, snapshotTitles, takeTitleChange } from '../refresh'
import { cacheRecipeRun } from '../views/recipe-source'
import type { Page } from './page'
import { APPROVALS_KEY, isApproved, loadRecipe, loadRecipes, overlaps, recipesDir, reviewOf, routeOf } from './recipes'
import { recipeFailureText, runRecipe } from './run'
import { PAGE_PICTURES, conflictText, imageExt, mediaOf, pageView, refreshed, settled } from './state'
import type { PageLoad } from './state'

type Unconflicted = Exclude<RecipePage, { phase: 'conflict' }>

const pageLoads = new Map<string, Promise<PageLoad>>()
const pageBackoff = new Map<string, { waitMs: number; until: number }>()

async function recipeMedia(io: NavIo, page: Page): Promise<Pick<Extract<RecipePage, { phase: 'ready' }>, 'media' | 'pictures'>> {
  const { media, images } = mediaOf(page)
  if (Object.keys(media).length === 0) return {}
  const found = await Promise.all(
    images.slice(0, PAGE_PICTURES).map(async url => {
      const got = await downloadFile(io.remoteIo(), url, imageExt(url)).catch(() => undefined)
      if (!got || /^text\//i.test(got.type ?? '')) return [url, undefined] as const
      media[url] = { file: got.file }
      return [url, await remotePicture(io, got.file)] as const
    }),
  )
  const pictures = Object.fromEntries(found.filter((one): one is readonly [string, Picture] => Boolean(one[1])))
  return { media, ...(Object.keys(pictures).length ? { pictures } : {}) }
}

async function notePage(io: NavIo, href: string, state: RecipePage) {
  if (state.phase !== 'ready') return
  notePageTitle(href, { title: state.page.title, kind: 'web', trail: [state.name] }, await io.now())
  if (takeTitleChange()) await io.storeSet('titles', snapshotTitles()).catch(() => undefined)
}

export function loadPage(io: NavIo, link: string, allowDraft: boolean, onRouted: (state: RecipePage) => Promise<void> = async () => undefined): Promise<PageLoad> {
  const key = `${allowDraft ? 'draft' : 'approved'}|${link}`
  const running = pageLoads.get(key)
  if (running) return running
  const loading = (async (): Promise<PageLoad> => {
    const ref = parseRef(link)
    if (!ref) return { kind: 'none' }
    // Every web link passes through here: a folder that cannot be read means no recipe, not a broken open.
    const { recipes, approvals } = await loadRecipes(io.recipesIo()).catch(() => ({ recipes: [], approvals: {} }))
    const route = routeOf(ref, link, recipes, approvals, { allowDraft })
    if (route.kind === 'conflict') return { kind: 'conflict', ids: route.ids }
    if (route.kind !== 'recipe') return { kind: 'none' }
    const drafted = route.draft ? recipes.find(one => one.ok && one.id === route.id) : undefined
    const review = drafted?.ok ? await reviewOf(io.recipesIo(), drafted, recipes, approvals).catch(() => undefined) : undefined
    const base: RecipeRouted = { id: route.id, name: route.recipe.name, link, isDraft: route.draft, digest: route.digest, refreshMinutes: route.recipe.refreshMinutes, ...(review ? { review } : {}) }
    await onRouted({ ...base, phase: 'loading' })
    try {
      const root = recipesDir((await io.home()) ?? '')
      const outcome = await runRecipe(io.runIo(), { root, id: route.id, digest: route.digest, draft: route.draft }, link)
      if (!outcome.ok) return { kind: 'ran', state: { ...base, phase: 'failed', failure: recipeFailureText(outcome), failureKind: outcome.kind } }
      await cacheRecipeRun(io, route.id, link, outcome)
      return { kind: 'ran', state: { ...base, phase: 'ready', fetchedAt: outcome.ranAt, page: outcome.page, ...(await recipeMedia(io, outcome.page)) } }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error)
      return { kind: 'ran', state: { ...base, phase: 'failed', failure: `Recipe "${base.name}" (${base.id}) could not run: ${message}`, failureKind: 'started-failed' } }
    }
  })().finally(() => pageLoads.delete(key))
  pageLoads.set(key, loading)
  return loading
}

// Null when no recipe handles the link; the caller starts the ticker for a page it gets back.
export async function recipeView(io: NavIo, href: string, raw: string, allowDraft: boolean, onRouted: (state: RecipePage) => Promise<void>): Promise<View | null> {
  const link = raw.trim()
  if (!isWebUrl(link)) return null
  const loaded = await loadPage(io, link, allowDraft, onRouted)
  if (loaded.kind === 'none') return null
  pageBackoff.delete(href)
  const state: RecipePage = loaded.kind === 'ran' ? loaded.state : { phase: 'conflict', link, isDraft: allowDraft, failure: conflictText(loaded.ids) }
  await notePage(io, href, state)
  return pageView(href, state)
}

// A conflict page re-opens through show(), which navigation does before it gets here.
export async function refreshPage(io: NavIo, href: string, was: Unconflicted): Promise<boolean> {
  const write = (state: RecipePage) => io.view.update(now => (now?.href === href && now.page ? pageView(href, state) : now))
  const idle = settled(was)
  await write({ ...idle, isRefreshing: true })
  try {
    const loaded = await loadPage(io, was.link, was.isDraft).catch((error: unknown) => ({ kind: 'error' as const, message: error instanceof Error ? error.message : String(error) }))
    const next = refreshed(idle, loaded)
    if (next.isFresh) {
      pageBackoff.delete(href)
      await notePage(io, href, next.state)
    }
    await write(next.state)
    return next.isFresh
  } catch (error) {
    // tickPage skips a page marked refreshing, so a marker left by a failed write would stop its timer for the session.
    await io.view
      .update(now => {
        if (now?.href !== href || now.page?.phase === 'conflict' || !now.page?.isRefreshing) return now
        return pageView(href, settled(now.page))
      })
      .catch(() => undefined)
    throw error
  }
}

export function toggleReviewFiles(io: NavIo, href: string) {
  return io.view.update(now =>
    now?.href === href && now.page?.phase !== 'conflict' && now.page?.review ? { ...now, page: { ...now.page, review: { ...now.page.review, isShowingFiles: !now.page.review.isShowingFiles } } } : now,
  )
}

export async function approveRecipe(io: NavIo, href: string) {
  const shown = (await io.view.read())?.page
  if (!shown || shown.phase === 'conflict' || !shown.isDraft || !shown.review) return
  const { id, digest } = shown
  const shownAt = (now: View | null) => (now?.href === href && now.page && now.page.phase !== 'conflict' && now.page.id === id && now.page.digest === digest ? now.page : undefined)
  const refuse = (refusal: ReviewRefusal) =>
    io.view.update(now => {
      const state = shownAt(now)
      return now && state?.review ? { ...now, page: { ...state, review: { ...state.review, refusal } } } : now
    })
  if (shown.review.refusal?.kind === 'changed') return refuse({ kind: 'changed' })
  try {
    const recipesIo = io.recipesIo()
    const loaded = await loadRecipe(recipesIo, recipesDir((await io.home()) ?? ''), id)
    if (!loaded.ok || loaded.digest !== digest) return refuse({ kind: 'changed' })
    const { recipes, approvals } = await loadRecipes(recipesIo)
    const other = recipes.find(one => one.ok && one.id !== id && isApproved(one, approvals) && overlaps(loaded.recipe, one.recipe) !== undefined)
    if (other) return refuse({ kind: 'overlap', id: other.id })
    await io.storeSet(APPROVALS_KEY, { ...approvals, [id]: { digest: loaded.digest, files: loaded.files } })
  } catch (error) {
    return refuse({ kind: 'failed', message: error instanceof Error ? error.message : String(error) })
  }
  await io.view.update(now => {
    const state = shownAt(now)
    if (!state) return now
    const { review: _, ...approved } = state
    return pageView(href, { ...approved, isDraft: false })
  })
  await io.cursor.update(() => 0)
}

// Only an approved page that opted in and shows a page re-runs: an error page waits for u, a draft runs only through the agent's open.
export async function tickPage(io: NavIo) {
  const shown = (await io.mode.read()) === 'view' ? await io.view.read() : null
  const state = shown?.page
  if (!shown || state?.phase !== 'ready' || state.isDraft || state.isRefreshing || !(state.refreshMinutes > 0)) return
  const now = await io.now()
  const everyMs = state.refreshMinutes * 60_000
  if (now < state.fetchedAt + everyMs || now < (pageBackoff.get(shown.href)?.until ?? 0)) return
  if (await refreshPage(io, shown.href, state)) return
  const waitMs = Math.min((pageBackoff.get(shown.href)?.waitMs ?? everyMs) * 2, Math.max(BACKOFF_MAX_MS, everyMs))
  pageBackoff.set(shown.href, { waitMs, until: now + waitMs })
}
