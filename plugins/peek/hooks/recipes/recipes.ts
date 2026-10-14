import type { RecipeReview, ReviewFile } from '../../types/recipes'
import { RECIPE_CAPS, RECIPE_ID, cleanLine, cleanText, idProblem, isRecord, validateRecipe } from './page'
import type { Problem, Recipe, RecipeMatch } from './page'
import type { Ports } from '../ports'
import type { Ref } from '../refs'
import { adapterOfKind } from '../sources/adapter'

export const RECIPE_SHAPE = { files: 50, folders: 50, fileBytes: 4 * 1024 * 1024 }

type EntryKind = 'file' | 'dir' | 'other'

// list and statResolved name only the fields recipes read, so a fake without mtimeMs still serves; Ports' engine
// answers carry more and still fit.
export type RecipesIo = Pick<Ports, 'home' | 'readBytes' | 'storeGet'> & {
  list: (dir: string) => Promise<readonly { name: string; kind: EntryKind; size: number; isLink: boolean }[]>
  statResolved: (path: string) => Promise<{ kind: EntryKind; size: number; isLink: boolean; realPath?: string }>
}

export type RecipeApproval = { digest: string; files: Record<string, string> }
export type RecipeApprovals = Record<string, RecipeApproval>

export type LoadedRecipe =
  | { ok: true; id: string; dir: string; recipe: Recipe; warnings: string[]; digest: string; files: Record<string, string> }
  | { ok: false; id: string; dir?: string; problems: Problem[] }

export type RecipeRoute =
  | { kind: 'builtin' }
  | { kind: 'web' }
  | { kind: 'recipe'; id: string; recipe: Recipe; draft: boolean; digest: string }
  | { kind: 'conflict'; ids: string[] }

export const APPROVALS_KEY = 'recipeApprovals'

export const recipesDir = (home: string) => `${home}/.local/share/claude-peek/recipes`

const SHAPE_RULE = 'a recipe is recipe.json plus single scripts that use interpreters and libraries already on PATH, never npm install or a virtualenv inside the folder'

function decodeBase64(text: string): Uint8Array {
  const binary = atob(text)
  const bytes = new Uint8Array(binary.length)
  for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index)
  return bytes
}

async function sha256(bytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))
  return [...digest].map(byte => byte.toString(16).padStart(2, '0')).join('')
}

export function approvalsOf(raw: unknown): RecipeApprovals {
  if (!isRecord(raw)) return {}
  const approvals: RecipeApprovals = {}
  for (const [id, one] of Object.entries(raw)) {
    if (!RECIPE_ID.test(id) || !isRecord(one) || typeof one.digest !== 'string' || !isRecord(one.files)) continue
    const files = Object.entries(one.files).filter((entry): entry is [string, string] => typeof entry[1] === 'string')
    approvals[id] = { digest: one.digest, files: Object.fromEntries(files) }
  }
  return approvals
}

type Walked = { path: string; kind: 'file' | 'dir'; size: number; hash: string; bytes?: Uint8Array }

async function walk(io: RecipesIo, dir: string): Promise<{ entries: Walked[]; problems: Problem[] }> {
  const entries: Walked[] = []
  const problems: Problem[] = []
  const pending = ['']
  let files = 0
  let folders = 0
  while (pending.length > 0 && problems.length === 0) {
    const relative = pending.shift() ?? ''
    const listed = await io.list(relative ? `${dir}/${relative}` : dir).catch((error: unknown) => {
      problems.push({ path: relative || '.', message: `could not be listed: ${String(error)}` })
      return []
    })
    for (const one of listed) {
      const path = relative ? `${relative}/${one.name}` : one.name
      if (one.isLink || one.kind === 'other') {
        problems.push({ path, message: `is a symbolic link or special file; ${SHAPE_RULE}` })
      } else if (one.kind === 'dir') {
        if (++folders > RECIPE_SHAPE.folders) problems.push({ path: '.', message: `holds more than ${RECIPE_SHAPE.folders} folders; ${SHAPE_RULE}` })
        entries.push({ path, kind: 'dir', size: 0, hash: '' })
        pending.push(path)
      } else if (++files > RECIPE_SHAPE.files) {
        problems.push({ path: '.', message: `holds more than ${RECIPE_SHAPE.files} files; ${SHAPE_RULE}` })
      } else if (one.size > RECIPE_SHAPE.fileBytes) {
        problems.push({ path, message: `is ${one.size} bytes, over the 4 MiB a recipe file may hold` })
      } else {
        try {
          const bytes = decodeBase64((await io.readBytes(`${dir}/${path}`)).base64)
          entries.push({ path, kind: 'file', size: bytes.length, hash: await sha256(bytes), ...(path === 'recipe.json' ? { bytes } : {}) })
        } catch (error) {
          problems.push({ path, message: `could not be read: ${String(error)}` })
        }
      }
      if (problems.length > 0) break
    }
  }
  return { entries, problems }
}

const byPath = (a: { path: string }, b: { path: string }) => (a.path < b.path ? -1 : (a.path > b.path ? 1 : 0))

function scriptPath(run: readonly string[]): string {
  return (run[0] ?? '')
    .split('/')
    .filter(part => part !== '' && part !== '.')
    .join('/')
}

export async function loadRecipe(io: RecipesIo, root: string, id: string): Promise<LoadedRecipe> {
  const badId = idProblem(id)
  if (badId) return { ok: false, id, problems: [{ path: 'id', message: badId }] }
  const dir = `${root}/${id}`
  const walked = await walk(io, dir)
  if (walked.problems.length > 0) return { ok: false, id, dir, problems: walked.problems }
  const entries = walked.entries.toSorted(byPath)
  const json = entries.find(one => one.path === 'recipe.json' && one.kind === 'file')
  if (!json?.bytes) return { ok: false, id, dir, problems: [{ path: 'recipe.json', message: 'is missing; every recipe folder holds one' }] }
  let raw: unknown
  try {
    raw = JSON.parse(new TextDecoder().decode(json.bytes))
  } catch (error) {
    return { ok: false, id, dir, problems: [{ path: 'recipe.json', message: `is not JSON: ${String(error)}` }] }
  }
  const checked = validateRecipe(id, raw)
  if (!checked.ok) return { ok: false, id, dir, problems: checked.problems }
  const { recipe, warnings } = checked
  const [field, argv] = 'run' in recipe.source ? ['run', recipe.source.run] : ['map', recipe.source.map]
  const script = scriptPath(argv)
  if (!entries.some(one => one.kind === 'file' && one.path === script)) {
    return { ok: false, id, dir, problems: [{ path: `source.${field}[0]`, message: `"${argv[0]}" names no file in the recipe folder` }] }
  }
  const manifest = JSON.stringify(entries.map(one => [one.path, one.kind, one.size, one.hash]))
  const digest = await sha256(new TextEncoder().encode(manifest))
  const files = Object.fromEntries(entries.filter(one => one.kind === 'file').map(one => [one.path, one.hash]))
  return { ok: true, id, dir, recipe, warnings, digest, files }
}

export async function loadRecipes(io: RecipesIo): Promise<{ recipes: LoadedRecipe[]; approvals: RecipeApprovals }> {
  const home = await io.home()
  if (!home) return { recipes: [], approvals: {} }
  const root = recipesDir(home)
  const listed = await io.list(root).catch(() => [])
  const recipes = await Promise.all(
    listed
      .filter(one => one.kind !== 'file')
      .map(async (one): Promise<LoadedRecipe> =>
        one.kind === 'dir' && !one.isLink
          ? loadRecipe(io, root, one.name)
          : { ok: false, id: one.name, problems: [{ path: 'id', message: `${one.name} is a symbolic link or special file, not a recipe folder` }] },
      ),
  )
  const approvals = approvalsOf(await io.storeGet(APPROVALS_KEY).catch(() => undefined))
  return { recipes: recipes.toSorted((a, b) => byPath({ path: a.id }, { path: b.id })), approvals }
}

export const isApproved = (loaded: LoadedRecipe, approvals: RecipeApprovals): boolean =>
  loaded.ok && approvals[loaded.id]?.digest === loaded.digest

// `*` stands for any run of characters, `/` and `.` included; nothing else is special.
function globsMeet(a: string, b: string): boolean {
  const seen = new Set<number>()
  const meet = (i: number, j: number): boolean => {
    if (i === a.length && j === b.length) return true
    const key = i * (b.length + 1) + j
    if (seen.has(key)) return false
    seen.add(key)
    const starA = a[i] === '*'
    const starB = b[j] === '*'
    if (starA && meet(i + 1, j)) return true
    if (starB && meet(i, j + 1)) return true
    if (i === a.length || j === b.length) return false
    if (starA && meet(i, j + 1)) return true
    if (starB && meet(i + 1, j)) return true
    return !starA && !starB && a[i] === b[j] && meet(i + 1, j + 1)
  }
  return meet(0, 0)
}

const ANY_PATH = '*'

type MatchTarget = { host: string; pathname: string }

function targetOf(href: string): MatchTarget | undefined {
  let url: URL
  try {
    url = new URL(href)
  } catch {
    return undefined
  }
  if (url.protocol !== 'https:' && url.protocol !== 'http:') return undefined
  return { host: url.hostname.toLowerCase().replace(/\.$/, ''), pathname: url.pathname }
}

const matchAt = (recipe: Recipe, at: MatchTarget | undefined): RecipeMatch | undefined =>
  at && recipe.match.find(one => globsMeet(one.host, at.host) && globsMeet(one.path ?? ANY_PATH, at.pathname))

export const matches = (recipe: Recipe, href: string): RecipeMatch | undefined => matchAt(recipe, targetOf(href))

export function overlaps(a: Recipe, b: Recipe): [RecipeMatch, RecipeMatch] | undefined {
  for (const mine of a.match) {
    for (const theirs of b.match) {
      if (globsMeet(mine.host, theirs.host) && globsMeet(mine.path ?? ANY_PATH, theirs.path ?? ANY_PATH)) return [mine, theirs]
    }
  }
  return undefined
}

export const recipeFamilyOf = (kind: Ref['kind']) => adapterOfKind(kind).id

export function routeOf(
  ref: Ref,
  href: string,
  recipes: readonly LoadedRecipe[],
  approvals: RecipeApprovals,
  options: { allowDraft?: boolean } = {},
): RecipeRoute {
  const family = recipeFamilyOf(ref.kind)
  const at = targetOf(/^https?:\/\//i.test(href.trim()) ? href.trim() : ref.address)
  const claiming = recipes.filter(
    (one): one is Extract<LoadedRecipe, { ok: true }> =>
      one.ok && (family === 'web' || one.recipe.overrides.includes(family)) && matchAt(one.recipe, at) !== undefined,
  )
  const approved = claiming.filter(one => isApproved(one, approvals))
  const eligible = options.allowDraft ? claiming : approved
  if (eligible.length > 1) return { kind: 'conflict', ids: eligible.map(one => one.id) }
  const [winner] = eligible
  if (winner) return { kind: 'recipe', id: winner.id, recipe: winner.recipe, draft: !isApproved(winner, approvals), digest: winner.digest }
  return family === 'web' ? { kind: 'web' } : { kind: 'builtin' }
}

type ReadyRecipe = Extract<LoadedRecipe, { ok: true }>

const OUTSIDE_SHOWN = 20
const URLS = /\b[a-z][\w+.-]*:\/\/\S*/gi
// An absolute path, a home path (`~`, `~/x`, `~user`) or a `..` step, each starting a word.
const OUTSIDE_PATH = /(?:^|[\s"'`=(:;,|&<>])(?:\/(?=[\w.~-])|~(?=[\s/"'`;)]|$|[A-Za-z_])|\.\.(?![\w.]))/

// The hooks runtime's TextDecoder takes no `fatal` option, so a round trip finds bytes that are not UTF-8.
function textOf(bytes: Uint8Array): string | undefined {
  if (bytes.includes(0)) return undefined
  const text = new TextDecoder().decode(bytes)
  const again = new TextEncoder().encode(text)
  return again.length === bytes.length && again.every((byte, index) => byte === bytes[index]) ? text : undefined
}

export const mcpToolName = (server: string, tool: string) => `mcp__${server.replaceAll(/[^\w-]/g, '_')}__${tool}`

const matchLine = (one: RecipeMatch) => `${one.host}${one.path ?? ' (any path)'}`

function runsLine(recipe: Recipe): string {
  const { source } = recipe
  const timeout = `timeout ${source.timeoutSeconds ?? RECIPE_CAPS.defaultTimeoutSeconds}s`
  if ('run' in source) return `Runs ${source.run.join(' ')} <link> (${timeout})`
  return `Calls MCP server "${source.mcp.server}", tool "${source.mcp.tool}" (${mcpToolName(source.mcp.server, source.mcp.tool)}), arguments ${JSON.stringify(source.mcp.args ?? {})}, then maps its result through ${source.map.join(' ')} <link> (${timeout} for both)`
}

function outsideLines(path: string, text: string): string[] {
  return text.split('\n').flatMap((line, index) => {
    if (index === 0 && line.startsWith('#!')) return []
    if (!OUTSIDE_PATH.test(line.replaceAll(URLS, ''))) return []
    return [`${path} line ${index + 1} reaches outside the folder, which approval does not pin: ${cleanLine(line.trim()).slice(0, 80)}`]
  })
}

// The files are read again after hashing, so each read is checked against the hash the digest covers: a file that
// moved in between marks the review changed, and Approve then asks for a fresh preview.
export async function reviewOf(io: RecipesIo, loaded: ReadyRecipe, recipes: readonly LoadedRecipe[], approvals: RecipeApprovals): Promise<RecipeReview> {
  const { recipe } = loaded
  const before = approvals[loaded.id]?.files ?? {}
  const overlap = recipes.find((one): one is ReadyRecipe => one.ok && one.id !== loaded.id && isApproved(one, approvals) && overlaps(recipe, one.recipe) !== undefined)
  const files: ReviewFile[] = []
  const outside: string[] = []
  let isTorn = false
  for (const path of Object.keys(loaded.files).toSorted()) {
    const bytes = decodeBase64((await io.readBytes(`${loaded.dir}/${path}`)).base64)
    if ((await sha256(bytes)) !== loaded.files[path]) isTorn = true
    const text = textOf(bytes)
    if (text !== undefined && path !== 'recipe.json') outside.push(...outsideLines(path, text))
    if (before[path] === loaded.files[path]) continue
    files.push({ path, change: path in before ? 'changed' : 'new', size: bytes.length, ...(text === undefined ? {} : { text: cleanText(text) }) })
  }
  const removed = Object.keys(before).filter(path => !(path in loaded.files)).toSorted()
  const shown = outside.length > OUTSIDE_SHOWN ? [...outside.slice(0, OUTSIDE_SHOWN), `and ${outside.length - OUTSIDE_SHOWN} more lines that reach outside the folder`] : outside
  return {
    runs: runsLine(recipe),
    match: recipe.match.map(matchLine),
    overrides: [...recipe.overrides],
    refreshMinutes: recipe.refreshMinutes,
    env: [...(recipe.source.env ?? [])],
    ...(overlap ? { overlap: overlap.id } : {}),
    warnings: [...loaded.warnings, ...shown],
    files,
    removed,
    isStructureOnly: loaded.id in approvals && files.length === 0 && removed.length === 0,
    ...(isTorn ? { refusal: { kind: 'changed' as const } } : {}),
  }
}
