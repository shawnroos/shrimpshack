import { expect, test } from 'claude-code/testing'

import { armEscape, nav, personClose, setMenu } from '../hooks/navigation'
import type { NavIo } from '../hooks/navigation'

function fakeIo() {
  const opens: Record<string, unknown>[] = []
  const io = { open: async (options: Record<string, unknown>) => void opens.push(options) } as unknown as NavIo
  return { io, opens }
}

test('a person close while Esc is armed goes Back instead of closing; unarmed, it is left to the engine', async () => {
  const { io, opens } = fakeIo()
  nav.isEscapeArmed = false
  nav.paneTitle = 'plan.md'
  let backs = 0
  const back = () => void (backs += 1)

  armEscape(io, true, false, back)
  expect(opens.at(-1)).toEqual({ title: 'plan.md', closeOnEscape: true })
  expect(await personClose(io, false)).toBe(true)
  expect(backs).toBe(1)

  armEscape(io, false, false, back)
  expect(opens.at(-1)).toEqual({ title: 'plan.md' })
  expect(await personClose(io, false)).toBe(false)
  expect(backs).toBe(1)

  armEscape(io, true, false, null)
  expect(await personClose(io, false)).toBe(false)
  expect(backs).toBe(1)
})

test('arming asks the pane only when the answer changes', () => {
  const { io, opens } = fakeIo()
  nav.isEscapeArmed = false
  const back = () => undefined
  armEscape(io, true, false, back)
  armEscape(io, true, false, back)
  expect(opens.length).toBe(1)
  armEscape(io, false, false, back)
  armEscape(io, false, false, back)
  expect(opens.length).toBe(2)
})

test('opening the menu asks for the keys on its filter; closing it does not', async () => {
  const asked: string[] = []
  const store = { value: '' as string | boolean }
  const io = {
    open: async () => undefined,
    focus: async (key: string) => void asked.push(key),
    menuFilter: { update: async (change: (old: string) => string) => void (store.value = change('')) },
    menuOpen: { update: async (change: (old: boolean) => boolean) => void (store.value = change(false)) },
  } as unknown as NavIo
  await setMenu(io, true)
  expect(asked).toEqual(['menu-filter'])
  await setMenu(io, false)
  expect(asked).toEqual(['menu-filter'])
})
