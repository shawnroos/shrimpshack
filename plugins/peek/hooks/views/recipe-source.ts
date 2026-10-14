import type { PropValue } from '../../types'
import { clip } from '../format'
import type { NavIo } from '../navigation'
import { PAGE_CAPS, focusItemsOf, isRecord } from '../recipes/page'
import type { Page } from '../recipes/page'
import { APPROVALS_KEY, approvalsOf, isApproved, loadRecipe, recipesDir } from '../recipes/recipes'
import { itemFromRecord } from './items'
import type { Item, ItemRecord } from './items'

export type RecipeCacheIo = Pick<NavIo, 'home' | 'readFile' | 'writeFile' | 'run'>
export type RecipeSourceIo = RecipeCacheIo & Pick<NavIo, 'recipesIo'>

export type RecipeCache = { recipe: string; link: string; digest: string; fetchedAt: number; records: ItemRecord[] }
export type RecipeBlock = { kind: 'records'; items: Item[]; fetchedAt: number } | { kind: 'load'; link: string } | { kind: 'error'; text: string }

// A page holds up to 30 sections of 200 rows; 200 records of capped title and link keep a cache file near 0.5 MB.
export const RECIPE_RECORDS = 200
// The engine has no file delete, so the cap is a fixed set of files: a key takes the slot its hash names and
// replaces whatever key held it.
export const RECIPE_CACHE_SLOTS = 64

export const recipeCacheDir = (home: string) => `${home}/.local/share/claude-peek/recipe-cache`

export function recordsOfPage(page: Page, recipe: string): ItemRecord[] {
  return focusItemsOf(page)
    .flatMap((row, index): ItemRecord[] => {
      if (!row.href) return []
      const section = page.sections[row.section]?.heading
      return [{ id: `${recipe}#${index}`, href: row.href, type: 'recipe', name: clip(row.title, PAGE_CAPS.title), props: { recipe, ...(section ? { section } : {}) } }]
    })
    .slice(0, RECIPE_RECORDS)
}

async function slotOf(key: string): Promise<number> {
  const hash = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(key)))
  return (((hash[0] ?? 0) << 8) | (hash[1] ?? 0)) % RECIPE_CACHE_SLOTS
}

const keyOf = (recipe: string, link: string) => `${recipe}\n${link}`

async function fileOf(io: RecipeCacheIo, recipe: string, link: string): Promise<string | null> {
  const home = await io.home()
  return home ? `${recipeCacheDir(home)}/${await slotOf(keyOf(recipe, link))}.json` : null
}

// fs.write has no rename, so a whole file goes to a temporary name and mv puts it in place: a reader never sees half.
export async function writeRecipeCache(io: RecipeCacheIo, cache: RecipeCache): Promise<void> {
  const file = await fileOf(io, cache.recipe, cache.link)
  if (!file) return
  const temporary = `${file}.${Math.random().toString(36).slice(2)}.tmp`
  await io.writeFile(temporary, JSON.stringify({ ...cache, records: cache.records.slice(0, RECIPE_RECORDS) }))
  const moved = await io.run(['/bin/mv', '-f', temporary, file])
  if (moved.exitCode !== 0) throw new Error(`could not move the recipe cache into place: ${moved.stderr.trim()}`)
}

const isText = (value: unknown): value is string => typeof value === 'string'

function recordOf(raw: unknown): ItemRecord | null {
  if (!isRecord(raw) || !isText(raw.id) || !isText(raw.href) || !isText(raw.type) || !isRecord(raw.props)) return null
  const props: Record<string, PropValue> = {}
  for (const [key, value] of Object.entries(raw.props)) if (isText(value)) props[key] = value
  return { id: raw.id, href: raw.href, type: raw.type, ...(isText(raw.name) ? { name: raw.name } : {}), props }
}

// A slot another key took, a file cut short, or one in an older shape all read as no cache.
export async function readRecipeCache(io: RecipeCacheIo, recipe: string, link: string): Promise<RecipeCache | null> {
  const file = await fileOf(io, recipe, link)
  if (!file) return null
  let raw: unknown
  try {
    raw = JSON.parse(await io.readFile(file))
  } catch {
    return null
  }
  if (!isRecord(raw) || raw.recipe !== recipe || raw.link !== link || !isText(raw.digest) || typeof raw.fetchedAt !== 'number' || !Array.isArray(raw.records)) return null
  const records = raw.records.slice(0, RECIPE_RECORDS).map(recordOf)
  if (records.some(one => one === null)) return null
  return { recipe, link, digest: raw.digest, fetchedAt: raw.fetchedAt, records: records as ItemRecord[] }
}

// A cache failure never fails the page that ran.
export function cacheRecipeRun(io: RecipeCacheIo, recipe: string, link: string, ran: { page: Page; digest: string; ranAt: number }): Promise<void> {
  return writeRecipeCache(io, { recipe, link, digest: ran.digest, fetchedAt: ran.ranAt, records: recordsOfPage(ran.page, recipe) }).catch(() => undefined)
}

// Reads only: a block never runs its recipe. Opening the link is what runs it, and that run fills the cache.
export async function recipeBlock(io: RecipeSourceIo, recipe: string, url: string | undefined): Promise<RecipeBlock> {
  if (!url) return { kind: 'error', text: `Recipe block "${recipe}" names no link; add url=<link> to its fence` }
  const recipesIo = io.recipesIo()
  const loaded = await loadRecipe(recipesIo, recipesDir((await io.home()) ?? ''), recipe)
  if (!loaded.ok) return { kind: 'error', text: `Recipe "${recipe}" is missing or invalid, so this block draws nothing` }
  const approvals = approvalsOf(await recipesIo.storeGet(APPROVALS_KEY).catch(() => undefined))
  if (!isApproved(loaded, approvals)) return { kind: 'error', text: `Recipe "${loaded.recipe.name}" (${recipe}) is a draft; approve it in the pane before a block draws it` }
  const cache = await readRecipeCache(io, recipe, url).catch(() => null)
  if (!cache || cache.digest !== loaded.digest) return { kind: 'load', link: url }
  return { kind: 'records', items: cache.records.map(itemFromRecord), fetchedAt: cache.fetchedAt }
}
