import { expect, test } from 'claude-code/testing'

import { rankCommands } from '../hooks/pane/rank'

const rows = [
  { id: 'a', label: 'Go to stop.md' },
  { id: 'b', label: 'Scroll to top' },
  { id: 'c', label: 'Top up the list' },
  { id: 'd', label: 'top' },
]

test('the closest match comes first: exact label, then label prefix, then word prefix, then anywhere', () => {
  expect(rankCommands(rows, 'top').map(one => one.id)).toEqual(['d', 'c', 'b', 'a'])
})

test('every typed word must appear, and ties keep the menu order', () => {
  expect(rankCommands(rows, 'to s').map(one => one.id)).toEqual(['a', 'b', 'c'])
  expect(rankCommands(rows, 'zzz')).toEqual([])
})

test('with nothing typed the menu keeps its own order', () => {
  expect(rankCommands(rows, '  ').map(one => one.id)).toEqual(['a', 'b', 'c', 'd'])
})
