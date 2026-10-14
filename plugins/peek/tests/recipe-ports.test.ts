import { describe, expect, test } from 'claude-code/testing'

import type { Ports } from '../hooks/ports'
import { loadRecipes } from '../hooks/recipes/recipes'
import { runRecipe } from '../hooks/recipes/run'
import { structuredResult } from './fixtures/mcp'
import { mcpFolder, PAGE, ROOT, scriptFolder, world } from './fixtures/recipes/world'
import type { World } from './fixtures/recipes/world'

const LINK = 'https://figma.com/file/abc/Design'

const unused = (name: string) => () => {
  throw new Error(`recipes called ${name}`)
}

// The whole Ports record, as register.tsx hands it to NavIo.recipesIo() and runIo(): the recipe modules must take it
// as it is, not a hand-picked io.
function portsOver(w: World): Ports {
  return {
    sessionId: unused('sessionId'),
    sessionRoot: unused('sessionRoot'),
    cwd: unused('cwd'),
    home: w.io.home,
    linearKeyEnv: unused('linearKeyEnv'),
    envGet: w.io.envGet,
    run: w.io.run,
    spawn: unused('spawn'),
    fetch: unused('fetch'),
    read: unused('read'),
    readBytes: w.io.readBytes,
    write: unused('write'),
    list: async dir => (await w.io.list(dir)).map(entry => ({ ...entry, mtimeMs: 0 })),
    stat: unused('stat'),
    statResolved: async path => ({ ...(await w.io.statResolved(path)), mtimeMs: 0 }),
    exists: unused('exists'),
    now: w.io.now,
    sleep: w.io.sleep,
    every: unused('every'),
    after: unused('after'),
    mcpCall: w.io.mcpCall,
    toolCheck: w.io.toolCheck,
    storeGet: w.io.storeGet,
    pluginRoot: '/plugins/peek',
  }
}

async function ran(w: World, draft = false) {
  const ports = portsOver(w)
  const { recipes } = await loadRecipes(ports)
  const loaded = recipes.find(one => one.id === 'figma-files')
  if (!loaded?.ok) throw new Error(`figma-files did not load: ${JSON.stringify(loaded)}`)
  return runRecipe(ports, { root: ROOT, id: 'figma-files', digest: loaded.digest, draft }, LINK)
}

describe('recipe io built from the full Ports record', () => {
  test('loadRecipes reads the recipe folder under home through readBytes and list', async () => {
    const w = world({ files: scriptFolder('figma-files') })
    const { recipes } = await loadRecipes(portsOver(w))
    expect(recipes.map(one => [one.id, one.ok])).toEqual([['figma-files', true]])
  })

  test('a script reached through a linked home runs from the real path statResolved answers', async () => {
    const real = '/data/u/.local/share/claude-peek/recipes/figma-files'
    const w = world({
      files: {
        [`${real}/recipe.json`]: JSON.stringify({ name: 'Figma files', match: [{ host: 'figma.com' }], source: { run: ['./fetch.sh'] } }),
        [`${real}/fetch.sh`]: '#!/bin/sh\n',
        '/home': { link: '/data' },
      },
    })
    const outcome = await ran(w)
    expect(outcome.ok).toBe(true)
    expect(w.calls.run[0]?.init?.cwd).toBe(real)
  })

  test('a script whose statResolved answer has no real path is refused before running', async () => {
    const w = world({ files: scriptFolder('figma-files') })
    const ports = portsOver(w)
    const stat = ports.statResolved
    const { recipes } = await loadRecipes(ports)
    const loaded = recipes.find(one => one.id === 'figma-files')
    if (!loaded?.ok) throw new Error('figma-files did not load')
    const unresolved: Ports = { ...ports, statResolved: async path => {
      const { realPath: _dropped, ...rest } = await stat(path)
      return rest
    } }
    const outcome = await runRecipe(unresolved, { root: ROOT, id: 'figma-files', digest: loaded.digest, draft: false }, LINK)
    expect(outcome.ok).toBe(false)
    expect(w.calls.run).toHaveLength(0)
  })

  test('an MCP source reads the structured content of the tool result', async () => {
    const w = world({ files: mcpFolder('figma-files', { server: 'linear', tool: 'get_issue' }), mcp: () => structuredResult(PAGE) })
    const outcome = await ran(w)
    expect(outcome.ok && outcome.page).toEqual(PAGE)
    expect(w.calls.mcp.map(one => `${one.server}/${one.tool}`)).toEqual(['linear/get_issue'])
  })

  test('a draft MCP source asks toolCheck before it calls the tool', async () => {
    const w = world({ files: mcpFolder('figma-files', { server: 'linear', tool: 'get_issue' }), decision: 'deny' })
    const outcome = await ran(w, true)
    expect(outcome.ok ? 'ok' : outcome.kind).toBe('needs-permission')
    expect(w.calls.mcp).toHaveLength(0)
  })
})
