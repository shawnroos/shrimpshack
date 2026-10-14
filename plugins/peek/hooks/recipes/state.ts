import type { RecipePage, RecipeRouted } from '../../types/recipes'
import { fetchedAge } from '../format'
import type { Page } from './page'

export type RecipeRan = Extract<RecipePage, { phase: 'ready' | 'failed' }>
export type PageLoad = { kind: 'none' } | { kind: 'conflict'; ids: string[] } | { kind: 'ran'; state: RecipeRan }
type Unconflicted = Exclude<RecipePage, { phase: 'conflict' }>
type Media = Record<string, { file?: string; play?: string }>

export const PAGE_PICTURES = 12
// The pane draws a whole trimmed line of this shape as a picture, so the page downloads exactly those.
export const PICTURE_LINE = /^!\[([^\]]*)\]\(([^)\s]+)\)\s*$/

export const conflictText = (ids: readonly string[]) =>
  `Recipes ${ids.map(id => `"${id}"`).join(' and ')} both handle this link, so peek ran neither. Change one recipe's match so only one claims it.`

export const recipeLabel = (state: RecipePage) => (state.phase === 'conflict' ? 'Recipe conflict' : state.name)

const routedOf = ({ id, name, link, isDraft, digest, refreshMinutes, review }: RecipeRouted): RecipeRouted => ({ id, name, link, isDraft, digest, refreshMinutes, ...(review ? { review } : {}) })

export function settled(state: Unconflicted): Unconflicted {
  const { isRefreshing: _, ...rest } = state
  if (rest.phase !== 'ready') return rest
  const { refreshFailure: __, ...ready } = rest
  return ready
}

export function refreshed(idle: Unconflicted, loaded: PageLoad | { kind: 'error'; message: string }): { isFresh: boolean; state: Unconflicted } {
  const fresh = loaded.kind === 'ran' && loaded.state.id === idle.id ? loaded.state : undefined
  if (fresh?.phase === 'ready') return { isFresh: true, state: fresh }
  const reason =
    fresh?.failure ??
    (loaded.kind === 'error'
      ? `Recipe "${idle.name}" (${idle.id}) could not be read: ${loaded.message}`
      : loaded.kind === 'conflict'
        ? conflictText(loaded.ids)
        : `Recipe "${idle.name}" (${idle.id}) no longer handles this link: it was edited, removed or replaced. Open the link again.`)
  const state: Unconflicted =
    idle.phase === 'ready' ? { ...idle, refreshFailure: reason } : { ...routedOf(idle), phase: 'failed', failure: reason, failureKind: fresh?.failureKind ?? 'route' }
  return { isFresh: false, state }
}

export function pageSourceLine(state: RecipePage, now: number): string {
  if (state.phase === 'conflict') return 'recipe conflict'
  const marker = state.isRefreshing ? 'refreshing…' : state.phase === 'ready' && state.refreshFailure ? 'refresh failed' : ''
  const age = state.phase === 'ready' ? fetchedAge(state.fetchedAt, now) : ''
  return [`recipe ${state.id}`, state.isDraft ? 'draft' : 'approved', age, marker].filter(Boolean).join(' · ')
}

export function mediaOf(page: Page): { media: Media; images: string[] } {
  const media: Media = {}
  const images: string[] = []
  const addImage = (url: string) => {
    if (url && !(url in media)) {
      media[url] = {}
      images.push(url)
    }
  }
  for (const { block } of page.sections) {
    if (block.type === 'media') for (const one of block.items) one.kind === 'video' ? (media[one.url] = { play: one.url }) : addImage(one.url)
    if (block.type === 'markdown') for (const line of block.text.split('\n')) addImage(PICTURE_LINE.exec(line.trim())?.[2] ?? '')
    if (block.type === 'cards') for (const one of block.items) addImage(one.image ?? '')
  }
  return { media, images }
}

const IMAGE_EXT = /\.(png|jpe?g|gif|webp|bmp|svg)$/i

export function imageExt(url: string): string {
  try {
    return IMAGE_EXT.exec(new URL(url).pathname)?.[1]?.toLowerCase() ?? 'img'
  } catch {
    return 'img'
  }
}
