import { expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { fakeFs } from './fixtures/world'

const reply = (text: string) => ({ result: [{ type: 'text', text }], text })

function world(on: On, booted?: { workspace: string; teamKeys: string[] }) {
  const w = fakeFs(on)
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('command.run', () => ({ text: '' }))
  const mentions: string[][] = []
  on('store.get', (_$, e, next) => (e.key === 'linear' && booted ? { value: { ...booted, fetchedAt: w.now } } : next(e)))
  on('state.set', (_$, e, next) => {
    const write = e as { key?: string; value?: { href: string }[] }
    if (write.key === 'mentions') mentions.push((write.value ?? []).map(one => one.href))
    return next(e)
  })
  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc
  on('tool.call', async (_$, e) => reply(String((e as { answer?: string }).answer ?? '{}')) as never)
  return { w, mentions }
}

const CAPTURED = { tool: 'mcp__claude_ai_Linear__get_issue', id: 'CAP-3', answer: JSON.stringify({ url: 'https://linear.app/capws/issue/CAP-3/x' }) }

async function peek($: { command: { run: (input: never) => Promise<unknown> } }, args: string): Promise<unknown> {
  return $.command.run({ command: 'peek', args } as never)
}

async function read($: { tool: { call: (input: never) => Promise<unknown> } }, input: Record<string, unknown>) {
  await $.tool.call({ tool_use_id: `t-${Math.random()}`, ...input } as never)
}

test('from capture alone: a captured issue teaches its workspace and team, and a bare key resolves against them', async ($, on) => {
  world(on)
  expect(await peek($, 'CAP-7')).not.toEqual({ text: 'Peeking at https://linear.app/capws/issue/CAP-7' })
  await read($, CAPTURED)
  expect(await peek($, 'CAP-7')).toEqual({ text: 'Peeking at https://linear.app/capws/issue/CAP-7' })
  expect(await peek($, 'cap-8')).toEqual({ text: 'Peeking at https://linear.app/capws/issue/CAP-8' })
})

test('from boot and capture: the booted workspace wins, and both team lists resolve', async ($, on) => {
  world(on, { workspace: 'bootws', teamKeys: ['BOOT'] })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)
  expect(await peek($, 'BOOT-5')).toEqual({ text: 'Peeking at https://linear.app/bootws/issue/BOOT-5' })
  await read($, CAPTURED)
  expect(await peek($, 'BOOT-6')).toEqual({ text: 'Peeking at https://linear.app/bootws/issue/BOOT-6' })
  expect(await peek($, 'CAP-7')).toEqual({ text: 'Peeking at https://linear.app/bootws/issue/CAP-7' })
})

test('a captured read of a bare key only the booted team list knows stores no page and adds no mention', async ($, on) => {
  const { mentions } = world(on, { workspace: 'bootws', teamKeys: ['BOOT'] })
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true } as never)
  await read($, CAPTURED)
  const before = mentions.length
  await read($, { tool: 'mcp__linear__get_issue', id: 'BOOT-9', answer: '{"title":"no url"}' })
  expect(mentions.length).toBe(before)
  await read($, { tool: 'mcp__linear__get_issue', id: 'CAP-9', answer: '{"title":"no url"}' })
  expect(mentions.at(-1)).toContain('https://linear.app/capws/issue/CAP-9')
})
