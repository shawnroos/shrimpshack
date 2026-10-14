import { describe, expect, test } from 'claude-code/testing'

import type { PropValue } from '../types'
import { itemFromDoc, itemFromRecord } from '../hooks/views/items'
import type { Item } from '../hooks/views/items'
import { focus, matchesRule, nest, order, parseRule, sectioned, select, split } from '../hooks/views/select'
import type { TreeNode } from '../hooks/views/select'

const task = (id: string, props: Record<string, PropValue> = {}): Item =>
  itemFromDoc({ path: `/repo/.peek/tasks/${id}.md`, props: { id, status: 'todo', ...props } }, { type: 'task', source: 'task-folder' })

const ids = (items: readonly Item[]) => items.map(one => one.id)
const shape = (nodes: readonly TreeNode[]): unknown[] =>
  nodes.map(node => (node.children.length ? { [node.item.id]: shape(node.children) } : node.item.id))

describe('items', () => {
  test('a doc becomes an item named after its file, with no undefined fields', () => {
    const item = itemFromDoc({ path: '/repo/.peek/tasks/Write the brief.md', props: { id: 't1', status: 'todo' }, mtimeMs: 5 }, { type: 'task', source: 'task-folder' })
    expect(item).toEqual({ id: 't1', href: '/repo/.peek/tasks/Write the brief.md', type: 'task', name: 'Write the brief', props: { id: 't1', status: 'todo' }, source: 'task-folder' })
    expect(Object.values(item).some(value => value === undefined)).toBe(false)
  })

  test('a doc with no id prop uses its path, and worktree and missing carry over', () => {
    const item = itemFromDoc({ path: '/wt/notes/plan.md', worktree: '/wt' }, { type: 'deliverable', source: 'deliverable', missing: ['status'] })
    expect(item).toEqual({ id: '/wt/notes/plan.md', href: '/wt/notes/plan.md', type: 'deliverable', name: 'plan', props: {}, source: 'deliverable', worktree: '/wt', missing: ['status'] })
  })

  test('a plain record becomes an item', () => {
    expect(itemFromRecord({ id: 'pr-7', href: 'https://github.com/o/r/pull/7', type: 'gh-pr', name: 'Fix it', props: { state: 'open' } })).toEqual({
      id: 'pr-7', href: 'https://github.com/o/r/pull/7', type: 'gh-pr', name: 'Fix it', props: { state: 'open' }, source: 'record',
    })
  })
})

describe('rules', () => {
  test('parseRule reads key=value pairs joined by "and"', () => {
    expect(parseRule('parent=plan and status=todo')).toEqual({ parent: 'plan', status: 'todo' })
    expect(parseRule('  ')).toEqual({})
  })

  test('a rule matches props by equality, every pair must hold, and option text matches a boolean or number prop', () => {
    const item = task('a', { isTask: true, rank: 2, tags: ['x', 'y'] })
    expect(matchesRule(item, { status: 'todo', isTask: 'true' })).toBe(true)
    expect(matchesRule(item, { rank: '2' })).toBe(true)
    expect(matchesRule(item, { tags: 'y' })).toBe(true)
    expect(matchesRule(item, { status: 'todo', isTask: false })).toBe(false)
    expect(matchesRule(item, { creator: 'shawn' })).toBe(false)
    expect(matchesRule(item, {})).toBe(true)
  })

  test('the rule applies before the cap: a cap of 3 returns 3 matching items', () => {
    const items = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'].map((id, at) => task(id, { creator: at % 2 ? 'agent' : 'shawn' }))
    expect(ids(select(items, { rule: { creator: 'agent' }, cap: 3 }))).toEqual(['b', 'd', 'f'])
  })

  test('Covers AE9: a rule "parent is X" picks up a new task with that parent, and a split by status gives todo, doing and done sections', () => {
    const plan = '/repo/docs/plans/markdown-views.md'
    const before = [task('a', { parent: plan, status: 'done' }), task('b', { parent: plan, status: 'doing' }), task('other', { parent: 'elsewhere' })]
    const rule = parseRule(`parent=${plan}`)
    expect(ids(select(before, { rule }))).toEqual(['a', 'b'])
    const after = [...before, task('new', { parent: plan, status: 'todo' })]
    const members = select(after, { rule })
    expect(ids(members)).toEqual(['a', 'b', 'new'])
    const sections = split(members, 'status', ['todo', 'doing', 'done', 'cancelled'])
    expect(sections.map(one => [one.key, ids(one.items)])).toEqual([['todo', ['new']], ['doing', ['b']], ['done', ['a']]])
  })
})

describe('order', () => {
  test('tasks order by sequence, then due date, then name', () => {
    const items = [
      task('late', { due: '2026-11-01' }),
      task('soon', { due: '2026-10-15' }),
      task('nodue-b'),
      task('nodue-a'),
      task('forced', { due: '2026-10-01', sequence: { after: 'late' } }),
    ]
    const result = order(items)
    expect(ids(result.items)).toEqual(['soon', 'late', 'forced', 'nodue-a', 'nodue-b'])
    expect(result.cycles).toEqual([])
  })

  test('a before/after chain orders correctly whatever the input order', () => {
    const items = [task('c', { sequence: { after: 'b' } }), task('a', { sequence: { before: 'b' } }), task('b'), task('d', { sequence: { after: ['c', 'a'] } })]
    expect(ids(order(items).items)).toEqual(['a', 'b', 'c', 'd'])
  })

  test('"with" keeps tasks together, and links to tasks outside the set are ignored', () => {
    const items = [task('x', { due: '2026-10-01' }), task('y', { due: '2026-12-01', sequence: { with: 'z' } }), task('z', { due: '2026-10-05', sequence: { after: 'gone' } })]
    expect(ids(order(items).items)).toEqual(['x', 'z', 'y'])
  })

  test('a sequence cycle is broken and reported, never looped', () => {
    const items = [task('a', { sequence: { after: 'c' } }), task('b', { sequence: { after: 'a' } }), task('c', { sequence: { after: 'b' } }), task('free')]
    const result = order(items)
    expect(ids(result.items).sort()).toEqual(['a', 'b', 'c', 'free'])
    expect(ids(result.items).indexOf('b')).toBeGreaterThan(ids(result.items).indexOf('a'))
    expect(result.cycles).toEqual([{ kind: 'sequence', ids: ['a', 'b', 'c'] }])
  })
})

describe('nest', () => {
  test('children nest under their parent by id or href, and a parent missing from the set leaves the item top-level', () => {
    const parent = task('p')
    const items = [parent, task('c1', { parent: 'p' }), task('c2', { parent: parent.href }), task('g', { parent: 'c1' }), task('orphan', { parent: 'absent' })]
    const tree = nest(items)
    expect(shape(tree.roots)).toEqual(['orphan', { p: [{ c1: ['g'] }, 'c2'] }])
    expect(tree.roots[1]?.childCount).toBe(2)
    expect(tree.cycles).toEqual([])
  })

  test('a cycle in parent links is broken and reported, never looped', () => {
    const items = [task('a', { parent: 'c' }), task('b', { parent: 'a' }), task('c', { parent: 'b' }), task('d', { parent: 'b' })]
    const tree = nest(items)
    expect(shape(tree.roots)).toEqual([{ a: [{ b: ['c', 'd'] }] }])
    expect(tree.cycles).toEqual([{ kind: 'parent', ids: ['a', 'b', 'c'] }])
  })
})

describe('split', () => {
  test('splitting by a prop no item has yields one "none" section', () => {
    const items = [task('a'), task('b')]
    expect(split(items, 'repo').map(one => [one.key, ids(one.items)])).toEqual([['none', ['a', 'b']]])
  })

  test('declared values order first, then other values, then "none"', () => {
    const items = [task('a', { status: 'weird' }), task('b', { status: 'done' }), task('c', { status: null }), task('d', { status: 'todo' })]
    expect(split(items, 'status', ['todo', 'doing', 'done']).map(one => one.key)).toEqual(['todo', 'done', 'weird', 'none'])
  })

  test('a done child of a todo parent appears in the done section with its parent\'s name, and the parent\'s child count includes it', () => {
    const items = [task('p', { name: 'Ship views' }), task('c1', { parent: 'p' }), task('c2', { parent: 'p', status: 'done' }), task('d', { status: 'done' })]
    const result = sectioned(items, { split: 'status', values: ['todo', 'doing', 'done'] })
    const [todo, done] = result.sections
    expect(todo?.key).toBe('todo')
    expect(shape(todo?.roots ?? [])).toEqual([{ p: ['c1'] }])
    expect(todo?.roots[0]?.childCount).toBe(2)
    expect(done?.key).toBe('done')
    expect(ids((done?.roots ?? []).map(one => one.item))).toEqual(['c2', 'd'])
    expect(done?.roots[0]?.parentName).toBe('Ship views')
    expect('parentName' in (done?.roots[1] ?? {})).toBe(false)
  })
})

test('within a section a child that sorts before its parent still nests, and a crossed child draws above plain roots', () => {
  const items = [task('zeta'), task('alpha', { parent: 'zeta' }), task('aaa', { status: 'done' }), task('zz', { parent: 'zeta', status: 'done' })]
  const [todo, done] = sectioned(items, { split: 'status', values: ['todo', 'done'] }).sections
  expect(shape(todo?.roots ?? [])).toEqual([{ zeta: ['alpha'] }])
  expect(ids((done?.roots ?? []).map(one => one.item))).toEqual(['zz', 'aaa'])
})

describe('focus', () => {
  test('Now is doing, Next is up to five todo by sequence then due, Later is the rest, and done or cancelled are left out', () => {
    const items = [
      task('doing1', { status: 'doing' }),
      task('t6', { due: '2026-10-26' }),
      task('t1', { due: '2026-10-21' }),
      task('t2', { due: '2026-10-22' }),
      task('t3', { due: '2026-10-23' }),
      task('t4', { due: '2026-10-24' }),
      task('t5', { due: '2026-10-25' }),
      task('fin', { status: 'done' }),
      task('gone', { status: 'cancelled' }),
    ]
    const buckets = focus(items)
    expect(ids(buckets.now)).toEqual(['doing1'])
    expect(ids(buckets.next)).toEqual(['t1', 't2', 't3', 't4', 't5'])
    expect(ids(buckets.later)).toEqual(['t6'])
  })

  test('a todo waiting on an unfinished task goes to Later; one after a done task is ready', () => {
    const items = [
      task('blocker', { status: 'doing' }),
      task('waits', { due: '2026-10-01', sequence: { after: 'blocker' } }),
      task('waits-too', { due: '2026-10-01' }),
      task('blocker2', { sequence: { before: 'waits-too' } }),
      task('old', { status: 'done' }),
      task('ready', { sequence: { after: 'old' } }),
    ]
    const buckets = focus(items)
    expect(ids(buckets.now)).toEqual(['blocker'])
    expect(ids(buckets.next)).toEqual(['blocker2', 'ready'])
    expect(ids(buckets.later)).toEqual(['waits', 'waits-too'])
  })
})
