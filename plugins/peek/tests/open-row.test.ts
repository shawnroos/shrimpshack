import { expect, test } from 'claude-code/testing'
import { groupRowAt } from '../hooks/pane/layout'
import type { NavItem } from '../hooks/pane/types'

const row = (group: string, href: string, line: number): NavItem => ({ href, key: `group-row-${line}`, line, col: 0, groupItem: { group, title: group, key: href } })
const PAGE_G = [row('G', 'file:///repo/a.md', 0), row('G', 'file:///repo/b.md', 1)]

// The last drawn layout can be a page the person has left: a click on it is handled after the mode or the open
// group changed and before the next draw. Base dc8f33a opened such a click plain, so Back did not lead to it.
const CASES = [
  ['the drawn group page, still open', 'groups', { id: 'G' }, 1],
  ['Groups home after leaving the page', 'groups', null, -1],
  ['another group opened since the draw', 'groups', { id: 'H' }, -1],
  ['Recent since the draw', 'recent', { id: 'G' }, -1],
  ['the reader since the draw', 'view', { id: 'G' }, -1],
] as const

for (const [name, mode, opened, expected] of CASES) {
  test(`an open message for a drawn group row: ${name}`, () => {
    expect(groupRowAt(PAGE_G, 'file:///repo/b.md', mode, opened)).toBe(expected)
  })
}

test('an open message names no row for an href the page did not draw, or a row with no group item', () => {
  expect(groupRowAt(PAGE_G, 'file:///repo/c.md', 'groups', { id: 'G' })).toBe(-1)
  expect(groupRowAt([{ href: 'file:///repo/b.md', key: 'item-0', line: 0, col: 0 }], 'file:///repo/b.md', 'groups', { id: 'G' })).toBe(-1)
})
