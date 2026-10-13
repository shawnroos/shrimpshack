import { expect, test } from 'claude-code/testing'
import { ICON } from '../hooks/theme'
import { PANE_PROPS, fakeFs } from './fixtures/world'

type Node = { type?: string; props?: Record<string, unknown>; children?: unknown[] }

function strips(node: unknown, found: Record<string, unknown> = {}) {
  if (!node || typeof node !== 'object') return found
  const one = node as Node
  const key = one.props?.key
  if (key === 'tabs-left' || key === 'tabs-right') found[key] = { width: one.props?.width, tabs: (one.props?.props as { tabs?: unknown })?.tabs }
  for (const child of one.children ?? []) strips(child, found)
  return found
}

const full = (icon: string, name: string) => ` ${icon} ${name} `
const compact = (icon: string) => ` ${icon} `
const left = (isOn: boolean) => ({ width: 8, tabs: [{ id: 'view', label: full(ICON.peek, 'PEEK'), isOn }] })
const right = (on: string) => ({
  width: 32,
  tabs: [
    { id: 'recent', label: full(ICON.recent, 'RECENT'), isOn: on === 'recent' },
    { id: 'gallery', label: full(ICON.gallery, 'GALLERY'), isOn: on === 'gallery' },
    { id: 'groups', label: full(ICON.groups, 'GROUPS'), isOn: on === 'groups' },
  ],
})
// A long crumb compacts the tabs that are not chosen, which only the reader's crumb is long enough to do here.
const VIEW = {
  'tabs-left': left(true),
  'tabs-right': {
    width: 10,
    tabs: [
      { id: 'recent', label: compact(ICON.recent), isOn: false },
      { id: 'gallery', label: compact(ICON.gallery), isOn: false },
      { id: 'groups', label: compact(ICON.groups), isOn: false },
    ],
  },
}
const LISTS = Object.fromEntries(['recent', 'gallery', 'groups'].map(mode => [mode, { 'tabs-left': left(false), 'tabs-right': right(mode) }]))

// The header's two tab strips, as each mode draws them at a wide and a crowded width.
test('the header tab strips for every mode, wide and crowded', async (e, on) => {
  fakeFs(on, { '/repo/a-file-with-a-rather-long-name-for-the-crumbs.md': 'a\n' })
  const drawn: Record<string, unknown> = {}
  for (const columns of [100, 64]) {
    const ui = await e.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: { ...PANE_PROPS, bodyColumns: columns }, requestId: 'peek' })
    await e.command.run({ command: 'peek', args: '/repo/a-file-with-a-rather-long-name-for-the-crumbs.md' } as never)
    for (const mode of ['view', 'recent', 'gallery', 'groups']) {
      await ui.press({ key: `mode-${mode}` })
      await ui.redraw()
      drawn[`${columns} ${mode}`] = strips(await ui.drawn())
    }
    await ui.unmount()
  }
  const expected = Object.fromEntries([100, 64].flatMap(columns => Object.entries({ view: VIEW, ...LISTS }).map(([mode, strip]) => [`${columns} ${mode}`, strip])))
  expect(drawn).toEqual(expected)
})
