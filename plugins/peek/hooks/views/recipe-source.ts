import type { PropValue } from '../../types'
import { clip } from '../format'
import type { NavIo } from '../navigation'
import { PAGE_CAPS, focusItemsOf, isRecord } from '../recipes/page'
import type { Page } from '../recipes/page'
import { RECIPE_SHAPE, isApproved, loadRecipe, loadRecipes, routeOf } from '../recipes/recipes'
import type { LoadedRecipe, RecipesIo } from '../recipes/recipes'
import { conflictText } from '../recipes/state'
import { parseRef } from '../refs'
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

export const recipeCacheFile = async (home: string, recipe: string, link: string) => `${recipeCacheDir(home)}/${await slotOf(keyOf(recipe, link))}.json`

async function fileOf(io: RecipeCacheIo, recipe: string, link: string): Promise<string | null> {
  const home = await io.home()
  return home ? recipeCacheFile(home, recipe, link) : null
}

// fs.write has no rename, so a whole file goes to a temporary name and mv puts it in place: a reader never sees half.
export async function writeRecipeCache(io: RecipeCacheIo, cache: RecipeCache): Promise<void> {
  const file = await fileOf(io, cache.recipe, cache.link)
  if (!file) return
  const temporary = `${file}.${Math.random().toString(36).slice(2)}.tmp`
  try {
    await io.writeFile(temporary, JSON.stringify({ ...cache, records: cache.records.slice(0, RECIPE_RECORDS) }))
    const moved = await io.run(['/bin/mv', '-f', temporary, file])
    if (moved.exitCode !== 0) throw new Error(`could not move the recipe cache into place: ${moved.stderr.trim()}`)
  } catch (error) {
    // The slot cap bounds the cache only while no temporary file outlives its write.
    await io.run(['/bin/rm', '-f', temporary]).catch(() => undefined)
    throw error
  }
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

const drawnRecipes = new Map<string, { shape: string; loaded: LoadedRecipe }>()
const DRAWN_RECIPES = 100

// What a draw can learn without reading a file: every entry's path, kind, size and mtime.
async function shapeOf(io: RecipesIo, dir: string): Promise<string | undefined> {
  const seen: unknown[] = []
  const pending = ['']
  while (pending.length > 0) {
    if (seen.length > RECIPE_SHAPE.files + RECIPE_SHAPE.folders) return undefined
    const relative = pending.shift() ?? ''
    const listed = await io.list(relative ? `${dir}/${relative}` : dir).catch(() => undefined)
    if (!listed) return undefined
    for (const one of listed) {
      const path = relative ? `${relative}/${one.name}` : one.name
      seen.push([path, one.kind, one.size, one.mtimeMs ?? null, one.isLink])
      if (one.kind === 'dir' && !one.isLink) pending.push(path)
    }
  }
  return JSON.stringify(seen)
}

// A block is drawn on every redraw, so a recipe whose files look unchanged is not read and hashed again. A run
// never comes through here: it hashes the folder itself.
async function drawnRecipe(io: RecipesIo, root: string, id: string): Promise<LoadedRecipe> {
  const dir = `${root}/${id}`
  const shape = await shapeOf(io, dir)
  const known = drawnRecipes.get(dir)
  if (shape !== undefined && known?.shape === shape) return known.loaded
  const loaded = await loadRecipe(io, root, id)
  if (shape === undefined) return loaded
  if (drawnRecipes.size >= DRAWN_RECIPES) drawnRecipes.clear()
  drawnRecipes.set(dir, { shape, loaded })
  return loaded
}

// Reads only: a block never runs its recipe. Opening the link is what runs it, and that run fills the cache.
export async function recipeBlock(io: RecipeSourceIo, recipe: string, url: string | undefined): Promise<RecipeBlock> {
  if (!url) return { kind: 'error', text: `Recipe block "${recipe}" names no link; add url=<link> to its fence` }
  const { recipes, approvals } = await loadRecipes(io.recipesIo(), drawnRecipe).catch(() => ({ recipes: [], approvals: {} }))
  const loaded = recipes.find(one => one.id === recipe)
  if (!loaded?.ok) return { kind: 'error', text: `Recipe "${recipe}" is missing or invalid, so this block draws nothing` }
  const who = `Recipe "${loaded.recipe.name}" (${recipe})`
  if (!isApproved(loaded, approvals)) return { kind: 'error', text: `${who} is a draft; approve it in the pane before a block draws it` }
  const link = url.trim()
  const ref = parseRef(link)
  const route = ref ? routeOf(ref, link, recipes, approvals) : undefined
  if (route?.kind === 'conflict') return { kind: 'error', text: conflictText(route.ids) }
  if (route?.kind !== 'recipe' || route.id !== recipe) return { kind: 'error', text: `${who} does not handle ${clip(link, 200)}, so opening it would never fill this block` }
  const cache = await readRecipeCache(io, recipe, url).catch(() => null)
  if (!cache || cache.digest !== loaded.digest) return { kind: 'load', link: url }
  return { kind: 'records', items: cache.records.map(itemFromRecord), fetchedAt: cache.fetchedAt }
}
