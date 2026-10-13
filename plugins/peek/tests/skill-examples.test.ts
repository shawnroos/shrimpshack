import { expect, test } from 'claude-code/testing'

import { BLOCK_TYPES, validatePage, validateRecipe } from '../hooks/page'
import { mapStdin } from '../hooks/recipe-run'
import { matches, overlaps } from '../hooks/recipes'
import { EXAMPLES } from './fixtures/skill-examples'

for (const example of EXAMPLES) {
  test(`the ${example.id} example page passes validatePage unchanged`, () => {
    const checked = validatePage(example.page)
    expect(checked.ok ? [] : checked.problems).toEqual([])
    expect(checked.ok && checked.page).toEqual(example.page)
  })

  test(`the ${example.id} example recipe passes validateRecipe with no warnings, and matches its own sample link`, () => {
    const checked = validateRecipe(example.id, example.recipe)
    expect(checked.ok ? [] : checked.problems).toEqual([])
    expect(checked.warnings).toEqual([])
    expect(checked.ok && matches(checked.recipe, example.link)).toBeTruthy()
  })
}

test('the examples cover every block type and both source kinds', () => {
  const used = new Set(EXAMPLES.flatMap(one => one.page.sections.map(section => section.block.type)))
  expect([...BLOCK_TYPES].filter(type => !used.has(type))).toEqual([])
  const kinds = EXAMPLES.map(one => ('run' in one.recipe.source ? 'script' : 'mcp'))
  expect(kinds.toSorted()).toEqual(['mcp', 'script'])
})

test('an MCP example saves its sample tool result in exactly the stdin shape peek gives the map', () => {
  const mcp = EXAMPLES.filter(one => 'mcp' in one.recipe.source)
  expect(mcp.length).toBeGreaterThan(0)
  for (const example of mcp) {
    const sample = JSON.parse(example.sample ?? 'null') as { text: string; structured: unknown }
    expect(Object.keys(sample)).toEqual(['text', 'structured'])
    expect(example.sample).toBe(mapStdin(sample.text, sample.structured))
  }
})

test('the examples do not claim each other links, so a person can copy both', () => {
  const [a, b] = EXAMPLES.map(one => validateRecipe(one.id, one.recipe))
  expect(a?.ok && b?.ok && overlaps(a.recipe, b.recipe)).toBeFalsy()
  for (const example of EXAMPLES) {
    for (const other of EXAMPLES) {
      if (other === example) continue
      const checked = validateRecipe(other.id, other.recipe)
      expect(checked.ok && matches(checked.recipe, example.link)).toBeFalsy()
    }
  }
})

test('no peek command is named peek-recipes, so the skill is reachable by its name', async (driver, on) => {
  const commands: string[] = []
  on('command.register', (_$, e) => {
    commands.push(String((e as unknown as { name: unknown }).name))
    return { value: undefined } as never
  })
  on('tool.register', () => ({ value: undefined }) as never)
  on('clock.now', () => ({ value: 10 * 3600_000 }))
  on('session.start', () => ({ cwd: '/repo' }) as never)
  await driver.session.start({ cwd: '/repo', source: 'startup' } as never)
  expect(commands).toContain('peek')
  expect(commands).not.toContain('peek-recipes')
})
