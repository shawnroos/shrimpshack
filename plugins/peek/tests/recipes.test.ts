import { describe, expect, test } from 'claude-code/testing'

import type { Recipe } from '../hooks/page'
import { loadRecipes, matches, overlaps, RECIPE_SHAPE, recipesDir, routeOf } from '../hooks/recipes'
import type { LoadedRecipe, RecipeApprovals, RecipesIo } from '../hooks/recipes'
import { parseRef } from '../hooks/refs'

const HOME = '/home/u'
const ROOT = `${HOME}/.local/share/claude-peek/recipes`
const MIB = 1024 * 1024

type Node = { kind: 'file'; bytes: Uint8Array } | { kind: 'dir' } | { kind: 'link'; target: string }

const encode = (text: string) => new TextEncoder().encode(text)

function base64(bytes: Uint8Array): string {
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary)
}

// Rejects where the real fs rejects: a missing path, listing a file, reading a folder or over 4 MiB.
function fakeFs(files: Record<string, string | Uint8Array | { link: string }>, store: Record<string, unknown> = {}) {
  const nodes = new Map<string, Node>()
  const addDirs = (path: string) => {
    const parts = path.split('/').filter(Boolean)
    for (let index = 1; index < parts.length; index++) nodes.set(`/${parts.slice(0, index).join('/')}`, { kind: 'dir' })
  }
  for (const [path, body] of Object.entries(files)) {
    addDirs(path)
    if (path.endsWith('/')) nodes.set(path.slice(0, -1), { kind: 'dir' })
    else if (typeof body === 'string') nodes.set(path, { kind: 'file', bytes: encode(body) })
    else if (body instanceof Uint8Array) nodes.set(path, { kind: 'file', bytes: body })
    else nodes.set(path, { kind: 'link', target: body.link })
  }
  const missing = (path: string) => Object.assign(new Error(`ENOENT: ${path}`), { code: 'ENOENT' })
  const io: RecipesIo = {
    home: async () => HOME,
    list: async dir => {
      if (nodes.get(dir)?.kind !== 'dir') throw missing(dir)
      return [...nodes.entries()]
        .filter(([path]) => path.slice(0, path.lastIndexOf('/')) === dir)
        .map(([path, node]) => ({
          name: path.slice(path.lastIndexOf('/') + 1),
          kind: node.kind === 'link' ? 'other' : node.kind,
          size: node.kind === 'file' ? node.bytes.length : 0,
          mtimeMs: 0,
          isLink: node.kind === 'link',
        }))
    },
    read: async path => {
      let node = nodes.get(path)
      if (node?.kind === 'link') node = nodes.get(node.target)
      if (node?.kind !== 'file') throw missing(path)
      if (node.bytes.length > 4 * MIB) throw new Error('EFBIG: over 4 MiB')
      return { base64: base64(node.bytes) }
    },
    stat: async path => {
      const node = nodes.get(path)
      if (!node) throw missing(path)
      return { kind: node.kind === 'link' ? 'other' : node.kind, size: 0, mtimeMs: 0, isLink: node.kind === 'link', realPath: path }
    },
    storeGet: async key => store[key],
  }
  return { io, store, write: (path: string, body: string) => nodes.set(path, { kind: 'file', bytes: encode(body) }), nodes }
}

const recipeJson = (over: Record<string, unknown> = {}) =>
  JSON.stringify({ name: 'Figma files', match: [{ host: 'figma.com', path: '/file/*' }], source: { run: ['./fetch.sh'] }, ...over })

function folder(id: string, over: Record<string, unknown> = {}, extra: Record<string, string | Uint8Array | { link: string }> = {}) {
  return { [`${ROOT}/${id}/recipe.json`]: recipeJson(over), [`${ROOT}/${id}/fetch.sh`]: '#!/bin/sh\necho {}\n', ...extra }
}

function valid(recipes: readonly LoadedRecipe[], id: string) {
  const one = recipes.find(recipe => recipe.id === id)
  if (!one?.ok) throw new Error(`${id} did not load: ${JSON.stringify(one)}`)
  return one
}

function invalid(recipes: readonly LoadedRecipe[], id: string) {
  const one = recipes.find(recipe => recipe.id === id)
  if (!one || one.ok) throw new Error(`${id} should be invalid: ${JSON.stringify(one)}`)
  return one
}

async function approve(world: ReturnType<typeof fakeFs>, ...ids: string[]) {
  const { recipes } = await loadRecipes(world.io)
  const approvals = { ...(world.store.recipeApprovals as RecipeApprovals | undefined) }
  for (const id of ids) {
    const one = valid(recipes, id)
    approvals[id] = { digest: one.digest, files: one.files }
  }
  world.store.recipeApprovals = approvals
}

async function route(world: ReturnType<typeof fakeFs>, link: string, allowDraft = false) {
  const { recipes, approvals } = await loadRecipes(world.io)
  const ref = parseRef(link)
  if (!ref) throw new Error(`no ref for ${link}`)
  return routeOf(ref, link, recipes, approvals, { allowDraft })
}

const PR = 'https://github.com/o/r/pull/42'
const FIGMA = 'https://figma.com/file/abc/Design'

const recipe = (match: Recipe['match'], over: Partial<Recipe> = {}): Recipe => ({
  id: 'r',
  name: 'R',
  match,
  overrides: [],
  source: { run: ['./a.sh'] },
  refreshMinutes: 0,
  ...over,
})

describe('loadRecipes', () => {
  test('a missing recipes folder gives an empty list', async () => {
    const world = fakeFs({ [`${HOME}/.bashrc`]: '' })
    expect(await loadRecipes(world.io)).toEqual({ recipes: [], approvals: {} })
  })

  test('the folder lives beside the groups store', () => {
    expect(recipesDir(HOME)).toBe(ROOT)
  })

  test('a valid folder loads with its recipe, a sha-256 digest and per-file hashes', async () => {
    const world = fakeFs(folder('figma'))
    const one = valid((await loadRecipes(world.io)).recipes, 'figma')
    expect(one.recipe.name).toBe('Figma files')
    expect(one.dir).toBe(`${ROOT}/figma`)
    expect(one.digest).toMatch(/^[0-9a-f]{64}$/)
    expect(Object.keys(one.files)).toEqual(['fetch.sh', 'recipe.json'])
    expect(Object.values(one.files).every(hash => /^[0-9a-f]{64}$/.test(hash))).toBe(true)
  })

  test('a bad recipe.json is listed invalid with its problems and never routes', async () => {
    const world = fakeFs({
      ...folder('figma'),
      [`${ROOT}/broken/recipe.json`]: '{ not json',
      [`${ROOT}/wrong/recipe.json`]: recipeJson({ source: { run: ['fetch.sh'] } }),
      [`${ROOT}/empty/notes.txt`]: 'x',
    })
    const { recipes } = await loadRecipes(world.io)
    expect(invalid(recipes, 'broken').problems[0]?.path).toBe('recipe.json')
    expect(invalid(recipes, 'wrong').problems.map(one => one.path)).toContain('source.run[0]')
    expect(invalid(recipes, 'empty').problems[0]).toEqual({ path: 'recipe.json', message: expect.stringContaining('missing') })
    await approve(world, 'figma')
    world.store.recipeApprovals = { ...(world.store.recipeApprovals as object), broken: { digest: 'x', files: {} } }
    expect(await route(world, 'https://figma.com/proto/x', true)).toEqual({ kind: 'web' })
  })

  test('a script source must name a file inside the folder', async () => {
    const world = fakeFs({ [`${ROOT}/figma/recipe.json`]: recipeJson({ source: { run: ['./gone.sh'] } }) })
    expect(invalid((await loadRecipes(world.io)).recipes, 'figma').problems).toEqual([
      { path: 'source.run[0]', message: expect.stringContaining('./gone.sh') },
    ])
  })

  test('a script in a subfolder, spelled with ./ segments, counts as inside', async () => {
    const world = fakeFs({ [`${ROOT}/figma/recipe.json`]: recipeJson({ source: { run: ['./bin/./fetch.sh'] } }), [`${ROOT}/figma/bin/fetch.sh`]: 'x' })
    expect(valid((await loadRecipes(world.io)).recipes, 'figma').files['bin/fetch.sh']).toMatch(/^[0-9a-f]{64}$/)
  })

  test('an mcp recipe must name a map script inside the folder', async () => {
    const source = { mcp: { server: 'linear', tool: 'get_doc' }, map: ['./map.py'] }
    const missing = fakeFs({ [`${ROOT}/lin/recipe.json`]: recipeJson({ source }) })
    expect(invalid((await loadRecipes(missing.io)).recipes, 'lin').problems).toEqual([{ path: 'source.map[0]', message: expect.stringContaining('./map.py') }])
    const present = fakeFs({ [`${ROOT}/lin/recipe.json`]: recipeJson({ source }), [`${ROOT}/lin/map.py`]: 'x' })
    expect(valid((await loadRecipes(present.io)).recipes, 'lin').recipe.source).toEqual(source)
  })

  test('a symlink in the folder makes the recipe invalid, named by its path', async () => {
    const world = fakeFs(folder('figma', {}, { [`${ROOT}/figma/lib/helper.sh`]: { link: '/usr/local/bin/helper' } }))
    expect(invalid((await loadRecipes(world.io)).recipes, 'figma').problems).toEqual([
      { path: 'lib/helper.sh', message: expect.stringContaining('symbolic link') },
    ])
  })

  test('a symlinked recipe folder is invalid', async () => {
    const world = fakeFs({ ...folder('real'), [`${ROOT}/alias`]: { link: `${ROOT}/real` } })
    expect(invalid((await loadRecipes(world.io)).recipes, 'alias').problems[0]?.message).toContain('symbolic link')
  })

  test('a file over 4 MiB makes the recipe invalid; exactly 4 MiB is fine', async () => {
    const world = fakeFs({
      ...folder('big', {}, { [`${ROOT}/big/data.bin`]: new Uint8Array(4 * MIB + 1) }),
      ...folder('edge', {}, { [`${ROOT}/edge/data.bin`]: new Uint8Array(4 * MIB) }),
    })
    const { recipes } = await loadRecipes(world.io)
    expect(invalid(recipes, 'big').problems).toEqual([{ path: 'data.bin', message: expect.stringContaining('4 MiB') }])
    valid(recipes, 'edge')
  })

  test('fifty files load; fifty-one make the recipe invalid and point to the shape rule', async () => {
    const pad = (id: string, count: number) =>
      Object.fromEntries(Array.from({ length: count }, (_, index) => [`${ROOT}/${id}/lib/f${index}.txt`, `${index}`]))
    const world = fakeFs({ ...folder('fifty', {}, pad('fifty', 48)), ...folder('many', {}, pad('many', 49)) })
    const { recipes } = await loadRecipes(world.io)
    expect(Object.keys(valid(recipes, 'fifty').files)).toHaveLength(RECIPE_SHAPE.files)
    const problem = invalid(recipes, 'many').problems[0]
    expect(problem?.message).toContain('50 files')
    expect(problem?.message).toContain('npm install')
  })

  test('a folder name that is not a recipe id is listed invalid and its contents are not read', async () => {
    const world = fakeFs({ ...folder('Bad_Name'), [`${ROOT}/README.md`]: 'notes' })
    const { recipes } = await loadRecipes(world.io)
    expect(recipes).toEqual([{ ok: false, id: 'Bad_Name', problems: [{ path: 'id', message: expect.stringContaining('recipe id') }] }])
  })

  test('approvals from the store are kept only in the { id: { digest, files } } shape', async () => {
    const world = fakeFs(folder('figma'), { recipeApprovals: { figma: { digest: 'abc', files: { 'a.sh': 'h' } }, junk: 'yes', bad: { digest: 7 } } })
    expect((await loadRecipes(world.io)).approvals).toEqual({ figma: { digest: 'abc', files: { 'a.sh': 'h' } } })
  })
})

describe('digest', () => {
  async function digestOf(files: Parameters<typeof fakeFs>[0]) {
    return valid((await loadRecipes(fakeFs(files).io)).recipes, 'figma').digest
  }

  test('is stable for the same files', async () => {
    expect(await digestOf(folder('figma'))).toBe(await digestOf(folder('figma')))
  })

  test('renaming a file changes it', async () => {
    const base = folder('figma', {}, { [`${ROOT}/figma/notes.txt`]: 'n' })
    const renamed = folder('figma', {}, { [`${ROOT}/figma/notes.md`]: 'n' })
    expect(await digestOf(renamed)).not.toBe(await digestOf(base))
  })

  test('a new file in a subfolder changes it', async () => {
    const base = folder('figma', {}, { [`${ROOT}/figma/lib/a.txt`]: 'a' })
    const added = folder('figma', {}, { [`${ROOT}/figma/lib/a.txt`]: 'a', [`${ROOT}/figma/lib/deep/b.txt`]: 'b' })
    expect(await digestOf(added)).not.toBe(await digestOf(base))
  })

  test('an empty new subfolder changes it', async () => {
    expect(await digestOf(folder('figma', {}, { [`${ROOT}/figma/cache/`]: '' }))).not.toBe(await digestOf(folder('figma')))
  })

  test('changing one byte changes it and that file hash only', async () => {
    const base = valid((await loadRecipes(fakeFs(folder('figma')).io)).recipes, 'figma')
    const edited = valid((await loadRecipes(fakeFs({ ...folder('figma'), [`${ROOT}/figma/fetch.sh`]: '#!/bin/sh\necho []\n' }).io)).recipes, 'figma')
    expect(edited.digest).not.toBe(base.digest)
    expect(edited.files['recipe.json']).toBe(base.files['recipe.json'])
    expect(edited.files['fetch.sh']).not.toBe(base.files['fetch.sh'])
  })

  test('moving bytes between a path and its content does not collide', async () => {
    const a = folder('figma', {}, { [`${ROOT}/figma/ab`]: 'c' })
    const b = folder('figma', {}, { [`${ROOT}/figma/a`]: 'bc' })
    expect(await digestOf(a)).not.toBe(await digestOf(b))
  })
})

describe('matches', () => {
  test('an exact host matches only that host', () => {
    const one = recipe([{ host: 'figma.com' }])
    expect(matches(one, 'https://figma.com/anything')).toEqual({ host: 'figma.com' })
    expect(matches(one, 'https://FIGMA.com./x')).toEqual({ host: 'figma.com' })
    expect(matches(one, 'https://www.figma.com/x')).toBeUndefined()
    expect(matches(one, 'https://notfigma.com/x')).toBeUndefined()
  })

  test('*. matches any subdomain depth but not the bare domain', () => {
    const one = recipe([{ host: '*.figma.com' }])
    expect(matches(one, 'https://www.figma.com/x')).toBeDefined()
    expect(matches(one, 'https://a.b.figma.com/x')).toBeDefined()
    expect(matches(one, 'https://figma.com/x')).toBeUndefined()
    expect(matches(one, 'https://evilfigma.com/x')).toBeUndefined()
  })

  test('* in a path crosses slashes; the query and fragment are not part of the path', () => {
    const one = recipe([{ host: 'figma.com', path: '/file/*' }])
    expect(matches(one, 'https://figma.com/file/abc/Design?node-id=1#x')).toBeDefined()
    expect(matches(one, 'https://figma.com/file')).toBeUndefined()
    expect(matches(one, 'https://figma.com/proto/abc')).toBeUndefined()
  })

  test('a path without * must match exactly', () => {
    const one = recipe([{ host: 'figma.com', path: '/files/recent' }])
    expect(matches(one, 'https://figma.com/files/recent')).toBeDefined()
    expect(matches(one, 'https://figma.com/files/recent/x')).toBeUndefined()
  })

  test('only web links match', () => {
    expect(matches(recipe([{ host: 'figma.com' }]), 'ftp://figma.com/x')).toBeUndefined()
    expect(matches(recipe([{ host: 'figma.com' }]), 'not a url')).toBeUndefined()
  })
})

describe('overlaps', () => {
  test('/file/* against /* on one host overlap', () => {
    expect(overlaps(recipe([{ host: 'figma.com', path: '/file/*' }]), recipe([{ host: 'figma.com', path: '/*' }]))).toEqual([
      { host: 'figma.com', path: '/file/*' },
      { host: 'figma.com', path: '/*' },
    ])
  })

  test('/file/* against /proto/* do not overlap', () => {
    expect(overlaps(recipe([{ host: 'figma.com', path: '/file/*' }]), recipe([{ host: 'figma.com', path: '/proto/*' }]))).toBeUndefined()
  })

  test('*.figma.com against www.figma.com overlap; against figma.com they do not', () => {
    expect(overlaps(recipe([{ host: '*.figma.com' }]), recipe([{ host: 'www.figma.com' }]))).toBeDefined()
    expect(overlaps(recipe([{ host: '*.figma.com' }]), recipe([{ host: 'figma.com' }]))).toBeUndefined()
    expect(overlaps(recipe([{ host: '*.a.figma.com' }]), recipe([{ host: '*.figma.com' }]))).toBeDefined()
  })

  test('globs that share a string in the middle overlap; disjoint literals do not', () => {
    expect(overlaps(recipe([{ host: 'x.com', path: '/a*z' }]), recipe([{ host: 'x.com', path: '/*b*' }]))).toBeDefined()
    expect(overlaps(recipe([{ host: 'x.com', path: '/a*z' }]), recipe([{ host: 'x.com', path: '/b*' }]))).toBeUndefined()
    expect(overlaps(recipe([{ host: 'x.com', path: '/a*' }]), recipe([{ host: 'x.com' }]))).toBeDefined()
  })

  test('different hosts never overlap', () => {
    expect(overlaps(recipe([{ host: 'figma.com' }]), recipe([{ host: 'miro.com' }]))).toBeUndefined()
  })
})

describe('routeOf', () => {
  test('covers AE1: a github.com recipe without an override leaves a PR to the built-in page', async () => {
    const world = fakeFs(folder('gh', { match: [{ host: 'github.com' }] }))
    await approve(world, 'gh')
    expect(await route(world, PR)).toEqual({ kind: 'builtin' })
  })

  test('covers AE1: the same recipe overriding github takes the PR', async () => {
    const world = fakeFs(folder('gh', { match: [{ host: 'github.com' }], overrides: ['github'] }))
    await approve(world, 'gh')
    expect(await route(world, PR)).toMatchObject({ kind: 'recipe', id: 'gh', draft: false })
  })

  test('an override for one family does not take another', async () => {
    const world = fakeFs(folder('gh', { match: [{ host: 'github.com' }], overrides: ['linear', 'slack'] }))
    await approve(world, 'gh')
    expect(await route(world, PR)).toEqual({ kind: 'builtin' })
  })

  test('a github.com page peek treats as web goes to the recipe without an override', async () => {
    const world = fakeFs(folder('gh', { match: [{ host: 'github.com' }] }))
    await approve(world, 'gh')
    expect(await route(world, 'https://github.com/about')).toMatchObject({ kind: 'recipe', id: 'gh' })
  })

  test('covers AE1: a figma.com recipe takes a Figma link over the web page', async () => {
    const world = fakeFs(folder('figma'))
    await approve(world, 'figma')
    const result = await route(world, FIGMA)
    expect(result).toMatchObject({ kind: 'recipe', id: 'figma', draft: false })
    if (result.kind === 'recipe') expect(result.recipe.name).toBe('Figma files')
  })

  test('a link no recipe matches falls back to the web page', async () => {
    const world = fakeFs(folder('figma'))
    await approve(world, 'figma')
    expect(await route(world, 'https://example.com/a')).toEqual({ kind: 'web' })
  })

  test('a draft never routes without allowDraft, and previews marked draft with it', async () => {
    const world = fakeFs(folder('figma'))
    expect(await route(world, FIGMA)).toEqual({ kind: 'web' })
    expect(await route(world, FIGMA, true)).toMatchObject({ kind: 'recipe', id: 'figma', draft: true })
  })

  test('covers AE6: an approved recipe whose script changes routes as a draft', async () => {
    const world = fakeFs(folder('figma'))
    await approve(world, 'figma')
    world.write(`${ROOT}/figma/fetch.sh`, '#!/bin/sh\ncurl evil\n')
    expect(await route(world, FIGMA)).toEqual({ kind: 'web' })
    const preview = await route(world, FIGMA, true)
    expect(preview).toMatchObject({ kind: 'recipe', id: 'figma', draft: true })
    if (preview.kind === 'recipe') expect(preview.digest).not.toBe((world.store.recipeApprovals as RecipeApprovals).figma?.digest)
  })

  test('covers AE6: an approval marker written into the folder has no effect', async () => {
    const world = fakeFs(folder('figma'))
    world.write(`${ROOT}/figma/.approved`, 'yes')
    world.write(`${ROOT}/figma/approval.json`, JSON.stringify({ digest: 'anything' }))
    expect(await route(world, FIGMA)).toEqual({ kind: 'web' })
    await approve(world, 'figma')
    world.write(`${ROOT}/figma/.approved`, 'still yes')
    expect(await route(world, FIGMA)).toEqual({ kind: 'web' })
  })

  test('a draft built-in override still leaves the PR built-in without allowDraft', async () => {
    const world = fakeFs(folder('gh', { match: [{ host: 'github.com' }], overrides: ['github'] }))
    expect(await route(world, PR)).toEqual({ kind: 'builtin' })
    expect(await route(world, PR, true)).toMatchObject({ kind: 'recipe', id: 'gh', draft: true })
  })

  test('two approved recipes on /file/* and /* conflict, naming both', async () => {
    const world = fakeFs({ ...folder('files'), ...folder('all', { match: [{ host: 'figma.com', path: '/*' }] }) })
    await approve(world, 'files', 'all')
    expect(await route(world, FIGMA)).toEqual({ kind: 'conflict', ids: ['all', 'files'] })
    expect(await route(world, 'https://figma.com/proto/x')).toMatchObject({ kind: 'recipe', id: 'all' })
  })

  test('a draft overlapping an approved recipe: the approved one routes, and a preview reports the conflict', async () => {
    const world = fakeFs({ ...folder('files'), ...folder('draft', { match: [{ host: 'figma.com' }] }) })
    await approve(world, 'files')
    expect(await route(world, FIGMA)).toMatchObject({ kind: 'recipe', id: 'files', draft: false })
    expect(await route(world, FIGMA, true)).toEqual({ kind: 'conflict', ids: ['draft', 'files'] })
  })

  test('the link as typed is matched, not the address peek derives from it', async () => {
    const world = fakeFs(folder('w', { match: [{ host: 'www.example.com', path: '/a' }] }))
    await approve(world, 'w')
    expect(await route(world, 'https://www.example.com/a#frag')).toMatchObject({ kind: 'recipe', id: 'w' })
  })

  test('a reference that is not a link matches against its address', async () => {
    const world = fakeFs(folder('gh', { match: [{ host: 'github.com', path: '/o/r/*' }], overrides: ['github'] }))
    await approve(world, 'gh')
    const { recipes, approvals } = await loadRecipes(world.io)
    const ref = parseRef('o/r#42')
    if (!ref) throw new Error('no ref')
    expect(routeOf(ref, 'o/r#42', recipes, approvals)).toMatchObject({ kind: 'recipe', id: 'gh' })
  })
})
