import { expect, test } from 'claude-code/testing'

import { SHAPE } from './fixtures/plugin-shape'

const BUILDER = 'peek-recipe-builder'
const ALLOWED = ['Bash', 'Edit', 'Glob', 'Read', 'ToolSearch', 'Write', 'mcp__peek__check_recipe', 'mcp__peek__open']
const builder = () => SHAPE.agents.find(agent => agent.name === BUILDER)

test('the recipe builder agent runs on haiku, named after its file', () => {
  expect(builder()?.model).toBe('haiku')
  expect(builder()?.file).toBe(`agents/${BUILDER}.md`)
})

test('the recipe builder agent has exactly the allowed tools, and no peek tool that saves or approves', () => {
  expect([...(builder()?.tools ?? [])].toSorted()).toEqual(ALLOWED)
})

test('the recipe builder returns ready, stuck or needs-permission, never done, and cannot approve', () => {
  const body = SHAPE.agentBodies[BUILDER] ?? ''
  expect(body).toContain('status: ready | stuck | needs-permission')
  expect(body).not.toMatch(/status:[^\n]*\bdone\b/)
  expect(body).toContain('You cannot approve a recipe')
  expect(body).toContain('never ask')
  expect(body).toContain('outcome.allow')
  expect(body).toContain('5 failed')
})

test('the skill dispatches the builder in the background, and names the fallback brief', () => {
  expect(SHAPE.skill).toContain(`peek:${BUILDER}`)
  expect(SHAPE.skill).toContain('run_in_background')
  expect(SHAPE.skill).toContain('general-purpose')
  expect(SHAPE.skill).toContain('"haiku"')
  expect(SHAPE.skill).toContain(`agents/${BUILDER}.md`)
})

test('the skill reports done only after the person approves and the check says isApproved', () => {
  expect(SHAPE.skill).toContain('Approve')
  expect(SHAPE.skill).toContain('isApproved')
  expect(SHAPE.skill).toContain('needs-permission')
  expect(SHAPE.skill).toContain('stuck')
})

test('no skill shares the builder agent name', () => {
  expect(SHAPE.skillNames).toContain('peek-recipes')
  expect(SHAPE.skillNames).not.toContain(BUILDER)
})

test('no peek command shares the builder agent name', async (driver, on) => {
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
  expect(commands).not.toContain(BUILDER)
})
