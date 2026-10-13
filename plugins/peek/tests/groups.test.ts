import { describe, expect, test } from 'claude-code/testing'

import { applyGroupOps, createGroup, deleteGroup, GROUP_CAPS, shortId, starGroup } from '../hooks/groups'
import type { Group, GroupActor, GroupContext, GroupOp } from '../types/groups'

const NOW = 1_000
const LATER = 2_000

function counter(prefix = 'id'): () => string {
  let n = 0
  return () => `${prefix}${++n}`
}

function ctx(over: Partial<GroupContext> = {}): GroupContext {
  return { now: LATER, newId: counter('n'), actor: 'agent', others: [], ...over }
}

function make(ops: GroupOp[] = [], over: Partial<GroupContext> = {}, title = 'Auth work'): Group {
  const { group } = createGroup({ projectKey: '/repo/.git', title }, ops, { ...ctx(over), now: NOW })
  if (!group) throw new Error('create refused')
  return group
}

const PR = 'https://github.com/o/r/pull/42'
const ISSUE = 'https://github.com/o/r/issues/42'
const PLAN = 'docs/plan.md'
const WEB = 'https://example.com/page'
const LINEAR = 'https://linear.app/acme/issue/WEB-1'
const DIAGRAM = 'docs/flow.svg'

const as = (actor: GroupActor, over: Partial<GroupContext> = {}) => ctx({ actor, ...over })

describe('createGroup', () => {
  test('two sections and five items get stable ids and land in the right sections', () => {
    const { group, outcomes } = createGroup(
      { projectKey: '/repo/.git', title: 'Auth work', description: 'Everything for the login change' },
      [
        { op: 'addSection', title: 'Design' },
        { op: 'addSection', title: 'Code' },
        { op: 'addItem', ref: PLAN, section: 'design' },
        { op: 'addItem', ref: DIAGRAM, section: 'Design', label: 'Flow' },
        { op: 'addItem', ref: PR, section: 'Code' },
        { op: 'addItem', ref: LINEAR, section: 'code' },
        { op: 'addItem', ref: WEB },
      ],
      ctx({ now: NOW, newId: counter('x') }),
    )
    expect(outcomes.every(one => one.status === 'applied')).toBe(true)
    expect(group).toEqual({
      projectKey: '/repo/.git',
      id: 'x1',
      title: 'Auth work',
      description: 'Everything for the login change',
      starred: false,
      updatedAt: NOW,
      sections: [
        { id: 'x2', title: 'Design' },
        { id: 'x3', title: 'Code' },
      ],
      items: [
        { ref: PLAN, section: 'x2', addedBy: 'agent', addedAt: NOW },
        { ref: DIAGRAM, section: 'x2', addedBy: 'agent', addedAt: NOW, label: 'Flow' },
        { ref: PR, section: 'x3', addedBy: 'agent', addedAt: NOW },
        { ref: LINEAR, section: 'x3', addedBy: 'agent', addedAt: NOW },
        { ref: WEB, addedBy: 'agent', addedAt: NOW },
      ],
      removed: [],
    })
    expect(outcomes[0]).toEqual({ op: 'create', status: 'applied', reason: 'Created "Auth work"', groupId: 'x1' })
  })

  test('a title matching another group, in any case or spacing, is refused and returns that group', () => {
    const other = make()
    const { group, outcomes } = createGroup({ projectKey: '/repo/.git', title: '  auth WORK ' }, [], ctx({ others: [other] }))
    expect(group).toBeNull()
    expect(outcomes).toEqual([
      { op: 'create', status: 'refused', reason: 'A group named "Auth work" already exists', groupId: other.id },
    ])
  })

  test('an empty title is refused', () => {
    const { group, outcomes } = createGroup({ projectKey: 'p', title: '   ' }, [], ctx())
    expect(group).toBeNull()
    expect(outcomes[0]?.status).toBe('refused')
  })

  test('the 51st group in a project is refused; the 50th is allowed', () => {
    const others = Array.from({ length: GROUP_CAPS.groups - 1 }, (_, i) => ({ ...make(), id: `g${i}`, title: `G${i}` }))
    expect(createGroup({ projectKey: 'p', title: 'Fiftieth' }, [], ctx({ others })).group).not.toBeNull()
    const full = [...others, { ...make(), id: 'last', title: 'Last' }]
    const { group, outcomes } = createGroup({ projectKey: 'p', title: 'Too many' }, [], ctx({ others: full }))
    expect(group).toBeNull()
    expect(outcomes[0]?.reason).toContain('50')
  })

  test('a description over the cap at create still creates the group, with no description and a refused outcome', () => {
    const { group, outcomes } = createGroup({ projectKey: 'p', title: 'T', description: 'd'.repeat(501) }, [], ctx())
    expect(group?.description).toBe('')
    expect(outcomes.map(one => [one.op, one.status])).toEqual([
      ['create', 'applied'],
      ['setDescription', 'refused'],
    ])
  })

  test('a caller-given id is kept', () => {
    expect(createGroup({ projectKey: 'p', id: 'fixed', title: 'T' }, [], ctx()).group?.id).toBe('fixed')
  })

  test('the clock and the id generator are the only sources of time and ids', () => {
    const first = make([{ op: 'addSection', title: 'A' }], { newId: counter('k') })
    const second = make([{ op: 'addSection', title: 'A' }], { newId: counter('k') })
    expect(first).toEqual(second)
  })
})

describe('title and description', () => {
  test('renaming a group or a section keeps every id', () => {
    const group = make([{ op: 'addSection', title: 'Design' }, { op: 'addItem', ref: PLAN, section: 'Design' }])
    const { group: after, outcomes } = applyGroupOps(
      group,
      [
        { op: 'setTitle', title: 'Login rework' },
        { op: 'renameSection', section: 'Design', title: 'Shape' },
      ],
      ctx(),
    )
    expect(outcomes.map(one => one.status)).toEqual(['applied', 'applied'])
    expect(after.id).toBe(group.id)
    expect(after.title).toBe('Login rework')
    expect(after.sections).toEqual([{ id: group.sections[0]?.id ?? '', title: 'Shape' }])
    expect(after.items[0]?.section).toBe(group.sections[0]?.id)
  })

  test('a rename to another group\'s title is refused with that group\'s id; a recase of its own title is allowed', () => {
    const other = { ...make(), id: 'other', title: 'Release notes' }
    const group = make()
    const refused = applyGroupOps(group, [{ op: 'setTitle', title: 'release NOTES' }], ctx({ others: [other, group] }))
    expect(refused.group).toEqual(group)
    expect(refused.outcomes[0]).toMatchObject({ status: 'refused', groupId: 'other' })
    const recased = applyGroupOps(group, [{ op: 'setTitle', title: 'AUTH work' }], ctx({ others: [other, group] }))
    expect(recased.group.title).toBe('AUTH work')
  })

  test('a description of exactly 500 characters is kept; 501 is refused and the group unchanged', () => {
    const group = make()
    expect(applyGroupOps(group, [{ op: 'setDescription', description: 'a'.repeat(500) }], ctx()).group.description).toHaveLength(500)
    const { group: after, outcomes } = applyGroupOps(group, [{ op: 'setDescription', description: 'a'.repeat(501) }], ctx())
    expect(after).toEqual(group)
    expect(outcomes[0]?.status).toBe('refused')
    expect(outcomes[0]?.reason).toContain('500')
  })

  test('setting the same title is unchanged and leaves updatedAt alone', () => {
    const group = make()
    const { group: after, outcomes } = applyGroupOps(group, [{ op: 'setTitle', title: 'Auth work' }], ctx())
    expect(outcomes[0]?.status).toBe('unchanged')
    expect(after.updatedAt).toBe(NOW)
  })

  test('an applied change moves updatedAt to now', () => {
    expect(applyGroupOps(make(), [{ op: 'setDescription', description: 'why' }], ctx()).group.updatedAt).toBe(LATER)
  })

  test('the input group is never mutated', () => {
    const group = make([{ op: 'addSection', title: 'S' }, { op: 'addItem', ref: PLAN, section: 'S' }])
    const copy = JSON.parse(JSON.stringify(group))
    applyGroupOps(group, [{ op: 'removeSection', section: 'S' }, { op: 'addItem', ref: WEB }, { op: 'setTitle', title: 'X' }], ctx())
    applyGroupOps(group, [{ op: 'removeItem', ref: PLAN }], as('person'))
    expect(group).toEqual(copy)
  })
})

describe('sections', () => {
  test('removing a section moves its items to the unsectioned block', () => {
    const group = make([
      { op: 'addSection', title: 'Design' },
      { op: 'addSection', title: 'Code' },
      { op: 'addItem', ref: PLAN, section: 'Design' },
      { op: 'addItem', ref: PR, section: 'Code' },
    ])
    const { group: after } = applyGroupOps(group, [{ op: 'removeSection', section: 'Design' }], ctx())
    expect(after.sections.map(one => one.title)).toEqual(['Code'])
    expect(after.items.map(one => [one.ref, one.section])).toEqual([
      [PLAN, undefined],
      [PR, group.sections[1]?.id],
    ])
    expect('section' in (after.items[0] ?? {})).toBe(false)
  })

  test('removing a section keeps a person-added item that was moved into it', () => {
    const group = make([{ op: 'addSection', title: 'Design' }])
    const withPerson = applyGroupOps(group, [{ op: 'addItem', ref: WEB }], as('person')).group
    const moved = applyGroupOps(withPerson, [{ op: 'moveItem', ref: WEB, section: 'Design' }], ctx()).group
    const { group: after, outcomes } = applyGroupOps(moved, [{ op: 'removeSection', section: 'Design' }], ctx())
    expect(outcomes[0]?.status).toBe('applied')
    expect(after.items).toEqual([{ ref: WEB, addedBy: 'person', addedAt: LATER }])
  })

  test('a section is found by id as well as by title', () => {
    const group = make([{ op: 'addSection', title: 'Design' }])
    const id = group.sections[0]?.id ?? ''
    const { group: after } = applyGroupOps(group, [{ op: 'addItem', ref: PLAN, section: id }], ctx())
    expect(after.items[0]?.section).toBe(id)
  })

  test('a second section with the same title in any case is refused and names the first', () => {
    const group = make([{ op: 'addSection', title: 'Design' }])
    const { group: after, outcomes } = applyGroupOps(group, [{ op: 'addSection', title: 'DESIGN' }], ctx())
    expect(after).toEqual(group)
    expect(outcomes[0]).toMatchObject({ status: 'refused', sectionId: group.sections[0]?.id })
    const renamed = applyGroupOps(
      make([{ op: 'addSection', title: 'A' }, { op: 'addSection', title: 'B' }]),
      [{ op: 'renameSection', section: 'B', title: 'a' }],
      ctx(),
    )
    expect(renamed.outcomes[0]?.status).toBe('refused')
  })

  test('the 21st section is refused and the group unchanged', () => {
    const ops: GroupOp[] = Array.from({ length: GROUP_CAPS.sections }, (_, i) => ({ op: 'addSection', title: `S${i}` }))
    const group = make(ops)
    expect(group.sections).toHaveLength(20)
    const { group: after, outcomes } = applyGroupOps(group, [{ op: 'addSection', title: 'One more' }], ctx())
    expect(after).toEqual(group)
    expect(outcomes[0]?.status).toBe('refused')
    expect(outcomes[0]?.reason).toContain('20')
  })

  test('a section is added with a layout, and setSectionLayout switches it; the same layout again is unchanged', () => {
    const group = make([{ op: 'addSection', title: 'Links', layout: 'list' }, { op: 'addSection', title: 'Docs' }])
    expect(group.sections.map(one => one.layout ?? 'cards')).toEqual(['list', 'cards'])
    const { group: after, outcomes } = applyGroupOps(group, [{ op: 'setSectionLayout', section: 'docs', layout: 'list' }], ctx())
    expect(outcomes[0]).toMatchObject({ status: 'applied', sectionId: group.sections[1]?.id })
    expect(after.sections.map(one => one.layout)).toEqual(['list', 'list'])
    expect(applyGroupOps(after, [{ op: 'setSectionLayout', section: 'Links', layout: 'list' }], ctx()).outcomes[0]?.status).toBe('unchanged')
    expect(applyGroupOps(after, [{ op: 'setSectionLayout', section: 'Nope', layout: 'cards' }], ctx()).outcomes[0]?.status).toBe('refused')
  })

  test('reorder takes every section once, by id or title', () => {
    const group = make([{ op: 'addSection', title: 'A' }, { op: 'addSection', title: 'B' }, { op: 'addSection', title: 'C' }])
    const [a, b, c] = group.sections
    const { group: after } = applyGroupOps(group, [{ op: 'reorderSections', order: ['c', b?.id ?? '', 'A'] }], ctx())
    expect(after.sections).toEqual([c, b, a])
  })

  test('a reorder that misses, repeats or invents a section is refused', () => {
    const group = make([{ op: 'addSection', title: 'A' }, { op: 'addSection', title: 'B' }])
    for (const order of [['A'], ['A', 'A'], ['A', 'B', 'Z'], ['A', 'Z']]) {
      const { group: after, outcomes } = applyGroupOps(group, [{ op: 'reorderSections', order }], ctx())
      expect(after).toEqual(group)
      expect(outcomes[0]?.status).toBe('refused')
    }
  })

  test('an unknown section is refused for rename, remove, add and move', () => {
    const group = make([{ op: 'addItem', ref: PLAN }])
    const { group: after, outcomes } = applyGroupOps(
      group,
      [
        { op: 'renameSection', section: 'nope', title: 'X' },
        { op: 'removeSection', section: 'nope' },
        { op: 'addItem', ref: WEB, section: 'nope' },
        { op: 'moveItem', ref: PLAN, section: 'nope' },
      ],
      ctx(),
    )
    expect(after).toEqual(group)
    expect(outcomes.map(one => one.status)).toEqual(['refused', 'refused', 'refused', 'refused'])
  })
})

describe('items', () => {
  test('adding an item already present is unchanged and says so', () => {
    const group = make([{ op: 'addItem', ref: PLAN }])
    const { group: after, outcomes } = applyGroupOps(group, [{ op: 'addItem', ref: PLAN }], ctx())
    expect(after).toEqual(group)
    expect(outcomes[0]).toMatchObject({ status: 'unchanged', ref: PLAN })
    expect(outcomes[0]?.reason).toContain('already')
  })

  test('adding an item that sits in another section reports that section and leaves it there', () => {
    const group = make([
      { op: 'addSection', title: 'Design' },
      { op: 'addSection', title: 'Code' },
      { op: 'addItem', ref: PLAN, section: 'Design' },
    ])
    const { group: after, outcomes } = applyGroupOps(group, [{ op: 'addItem', ref: PLAN, section: 'Code' }], ctx())
    expect(after).toEqual(group)
    expect(outcomes[0]).toMatchObject({ status: 'unchanged', sectionId: group.sections[0]?.id })
    expect(outcomes[0]?.reason).toContain('Design')
  })

  test('an explicit move moves it, and a move with no section sends it to the unsectioned block', () => {
    const group = make([
      { op: 'addSection', title: 'Design' },
      { op: 'addSection', title: 'Code' },
      { op: 'addItem', ref: PLAN, section: 'Design' },
    ])
    const moved = applyGroupOps(group, [{ op: 'moveItem', ref: PLAN, section: 'Code' }], ctx())
    expect(moved.outcomes[0]?.status).toBe('applied')
    expect(moved.group.items[0]?.section).toBe(group.sections[1]?.id)
    const out = applyGroupOps(moved.group, [{ op: 'moveItem', ref: PLAN }], ctx())
    expect(out.group.items[0]?.section).toBeUndefined()
    expect(applyGroupOps(out.group, [{ op: 'moveItem', ref: PLAN }], ctx()).outcomes[0]?.status).toBe('unchanged')
  })

  test('moving an item the group does not hold is refused', () => {
    const group = make([{ op: 'addSection', title: 'Design' }])
    expect(applyGroupOps(group, [{ op: 'moveItem', ref: PLAN, section: 'Design' }], ctx()).outcomes[0]?.status).toBe('refused')
  })

  test('a pull request URL then its issue URL leave one item, the first', () => {
    const { group, outcomes } = applyGroupOps(make(), [{ op: 'addItem', ref: PR }, { op: 'addItem', ref: ISSUE }], ctx())
    expect(group.items.map(one => one.ref)).toEqual([PR])
    expect(outcomes[1]?.status).toBe('unchanged')
  })

  test('a Slack thread then a reply link inside it leave one item; removing by the reply removes the thread', () => {
    const thread = 'https://acme.slack.com/archives/C0123ABCD/p1791759796763609'
    const reply = 'https://acme.slack.com/archives/C0123ABCD/p1791761128357239?thread_ts=1791759796.763609&cid=C0123ABCD'
    const { group, outcomes } = applyGroupOps(make(), [{ op: 'addItem', ref: thread }, { op: 'addItem', ref: reply }], ctx())
    expect(group.items.map(one => one.ref)).toEqual([thread])
    expect(outcomes[1]?.status).toBe('unchanged')
    expect(applyGroupOps(group, [{ op: 'removeItem', ref: reply }], ctx()).group.items).toEqual([])
  })

  test('removing by the issue URL removes the pull request item', () => {
    const group = make([{ op: 'addItem', ref: PR }])
    expect(applyGroupOps(group, [{ op: 'removeItem', ref: ISSUE }], ctx()).group.items).toEqual([])
  })

  test('an item added by the person goes to the unsectioned block and is marked as theirs', () => {
    const group = make([{ op: 'addSection', title: 'Design' }])
    const { group: after } = applyGroupOps(group, [{ op: 'addItem', ref: PLAN, section: 'Design' }], as('person'))
    expect(after.items).toEqual([{ ref: PLAN, addedBy: 'person', addedAt: LATER }])
  })

  test('a label of exactly 200 characters is kept; 201 is refused and the group unchanged', () => {
    const group = make()
    expect(applyGroupOps(group, [{ op: 'addItem', ref: PLAN, label: 'l'.repeat(200) }], ctx()).group.items).toHaveLength(1)
    const { group: after, outcomes } = applyGroupOps(group, [{ op: 'addItem', ref: PLAN, label: 'l'.repeat(201) }], ctx())
    expect(after).toEqual(group)
    expect(outcomes[0]?.status).toBe('refused')
    expect(outcomes[0]?.reason).toContain('200')
  })

  test('the 201st item is refused and the group unchanged', () => {
    const ops: GroupOp[] = Array.from({ length: GROUP_CAPS.items }, (_, i) => ({ op: 'addItem', ref: `f${i}.md` }))
    const group = make(ops)
    expect(group.items).toHaveLength(200)
    const { group: after, outcomes } = applyGroupOps(group, [{ op: 'addItem', ref: 'last.md' }], ctx())
    expect(after).toEqual(group)
    expect(outcomes[0]?.status).toBe('refused')
    expect(outcomes[0]?.reason).toContain('200')
  })

  test('an empty ref is refused', () => {
    expect(applyGroupOps(make(), [{ op: 'addItem', ref: ' ' }], ctx()).outcomes[0]?.status).toBe('refused')
  })

  test('one refused op does not stop the ones after it', () => {
    const { group, outcomes } = applyGroupOps(
      make(),
      [{ op: 'addItem', ref: PLAN, section: 'nope' }, { op: 'addItem', ref: WEB }],
      ctx(),
    )
    expect(outcomes.map(one => one.status)).toEqual(['refused', 'applied'])
    expect(group.items.map(one => one.ref)).toEqual([WEB])
  })
})

describe('the person\'s items and removals', () => {
  test('a person\'s removal leaves a tombstone; an agent removal does not', () => {
    const group = make([{ op: 'addItem', ref: PLAN }, { op: 'addItem', ref: PR }])
    const byPerson = applyGroupOps(group, [{ op: 'removeItem', ref: PR }], as('person')).group
    expect(byPerson.items.map(one => one.ref)).toEqual([PLAN])
    expect(byPerson.removed).toEqual(['https://github.com/o/r#42'])
    const byAgent = applyGroupOps(group, [{ op: 'removeItem', ref: PR }], ctx()).group
    expect(byAgent.removed).toEqual([])
  })

  test('an agent add of a tombstoned item is refused and reported; with force it is added and the tombstone cleared', () => {
    const group = applyGroupOps(make([{ op: 'addItem', ref: PR }]), [{ op: 'removeItem', ref: PR }], as('person')).group
    const skipped = applyGroupOps(group, [{ op: 'addItem', ref: ISSUE }], ctx())
    expect(skipped.group).toEqual(group)
    expect(skipped.outcomes[0]).toMatchObject({ status: 'refused', ref: ISSUE, needsForce: true })
    expect(skipped.outcomes[0]?.reason).toContain('removed')
    const forced = applyGroupOps(group, [{ op: 'addItem', ref: ISSUE, force: true }], ctx())
    expect(forced.group.items.map(one => one.ref)).toEqual([ISSUE])
    expect(forced.group.removed).toEqual([])
  })

  test('the person adding back an item they removed clears the tombstone', () => {
    const group = applyGroupOps(make([{ op: 'addItem', ref: PLAN }]), [{ op: 'removeItem', ref: PLAN }], as('person')).group
    const after = applyGroupOps(group, [{ op: 'addItem', ref: PLAN }], as('person')).group
    expect(after.items.map(one => one.ref)).toEqual([PLAN])
    expect(after.removed).toEqual([])
  })

  test('an agent remove of a person-added item is refused without force and names the item', () => {
    const group = applyGroupOps(make(), [{ op: 'addItem', ref: WEB }], as('person')).group
    const refused = applyGroupOps(group, [{ op: 'removeItem', ref: WEB }], ctx())
    expect(refused.group).toEqual(group)
    expect(refused.outcomes[0]).toMatchObject({ status: 'refused', ref: WEB, needsForce: true })
    expect(refused.outcomes[0]?.reason).toContain(WEB)
    const forced = applyGroupOps(group, [{ op: 'removeItem', ref: WEB, force: true }], ctx())
    expect(forced.group.items).toEqual([])
  })

  test('removing an item the group does not hold is unchanged and leaves no tombstone', () => {
    const group = make()
    const { group: after, outcomes } = applyGroupOps(group, [{ op: 'removeItem', ref: PLAN }], as('person'))
    expect(after).toEqual(group)
    expect(outcomes[0]?.status).toBe('unchanged')
  })

  test('past 100 tombstones the oldest is dropped, and a key is never listed twice', () => {
    let group = make()
    for (let i = 0; i <= GROUP_CAPS.removed; i++) {
      group = applyGroupOps(group, [{ op: 'addItem', ref: `f${i}.md` }], ctx()).group
      group = applyGroupOps(group, [{ op: 'removeItem', ref: `f${i}.md` }], as('person')).group
    }
    expect(group.removed).toHaveLength(100)
    expect(group.removed[0]).toBe('f1.md')
    expect(group.removed[99]).toBe('f100.md')
    group = applyGroupOps(group, [{ op: 'addItem', ref: 'f5.md' }], as('person')).group
    group = applyGroupOps(group, [{ op: 'removeItem', ref: 'f5.md' }], as('person')).group
    expect(group.removed.filter(one => one === 'f5.md')).toHaveLength(1)
    expect(group.removed.at(-1)).toBe('f5.md')
  })
})

describe('star and delete', () => {
  test('starring sets the flag and leaves updatedAt alone, since a star is not a content change; starring again is unchanged', () => {
    const before = make()
    const { group, outcomes } = starGroup(before, true)
    expect(group.starred).toBe(true)
    expect(group.updatedAt).toBe(before.updatedAt)
    expect(outcomes[0]?.status).toBe('applied')
    const again = starGroup(group, true)
    expect(again.outcomes[0]?.status).toBe('unchanged')
    expect(again.group).toBe(group)
    const unstarred = starGroup(group, false).group
    expect(unstarred.starred).toBe(false)
    expect(unstarred.updatedAt).toBe(before.updatedAt)
  })

  test('an unstarred group with only agent items deletes without force', () => {
    const { group, outcomes } = deleteGroup(make([{ op: 'addItem', ref: PLAN }]))
    expect(group).toBeNull()
    expect(outcomes[0]?.status).toBe('applied')
  })

  test('deleting a starred group or one with person items is refused without force and names what would be lost', () => {
    const starred = starGroup(make(), true).group
    const refusedStar = deleteGroup(starred)
    expect(refusedStar.group).toEqual(starred)
    expect(refusedStar.outcomes[0]).toMatchObject({ op: 'delete', status: 'refused', needsForce: true })
    expect(refusedStar.outcomes[0]?.reason).toContain('starred')

    const withPerson = applyGroupOps(make(), [{ op: 'addItem', ref: WEB }, { op: 'addItem', ref: PLAN }], as('person')).group
    const refusedItems = deleteGroup(withPerson)
    expect(refusedItems.group).toEqual(withPerson)
    expect(refusedItems.outcomes[0]?.reason).toContain(WEB)
    expect(refusedItems.outcomes[0]?.reason).toContain(PLAN)
    expect(refusedItems.outcomes[0]?.reason).not.toContain('starred')

    expect(deleteGroup(starred, true).group).toBeNull()
    expect(deleteGroup(withPerson, true).group).toBeNull()
  })
})

test('shortId gives eight base-36 characters from the random source', () => {
  expect(shortId(() => 0.5)).toMatch(/^[0-9a-z]{8}$/)
  expect(shortId(() => 0.5)).toBe(shortId(() => 0.5))
  expect(shortId(() => 0.1)).not.toBe(shortId(() => 0.9))
})
