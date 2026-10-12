import type { Group, GroupContext, GroupItem, GroupOp, GroupOutcome, GroupResult, GroupSection } from '../types'
import { itemKey } from './refs'

// A group file at these caps stays far under the 4 MiB fs.read limit.
export const GROUP_CAPS = { groups: 50, items: 200, sections: 20, removed: 100, description: 500, label: 200 }

type Step = { group: Group; outcome: GroupOutcome }

export function shortId(random: () => number): string {
  let id = ''
  for (let i = 0; i < 8; i++) id += Math.min(35, Math.floor(random() * 36)).toString(36)
  return id
}

const fold = (text: string) => text.trim().toLowerCase()

function titleTaken(title: string, others: readonly Group[], selfId?: string): Group | undefined {
  return others.find(one => one.id !== selfId && fold(one.title) === fold(title))
}

function findSection(group: Group, name: string): GroupSection | undefined {
  return group.sections.find(one => one.id === name) ?? group.sections.find(one => fold(one.title) === fold(name))
}

function sectionTitle(group: Group, id: string | undefined): string {
  return id ? `"${group.sections.find(one => one.id === id)?.title ?? id}"` : 'the unsectioned block'
}

function findItem(group: Group, ref: string): GroupItem | undefined {
  const key = itemKey(ref)
  return group.items.find(one => itemKey(one.ref) === key)
}

function placed(item: GroupItem, section: string | undefined): GroupItem {
  const { section: _old, ...rest } = item
  return section ? { ...rest, section } : rest
}

function tombstone(removed: readonly string[], key: string): string[] {
  return [...removed.filter(one => one !== key), key].slice(-GROUP_CAPS.removed)
}

function applyOne(group: Group, op: GroupOp, ctx: GroupContext): Step {
  const done = (next: Group, reason: string, extra: Partial<GroupOutcome> = {}): Step => ({
    group: { ...next, updatedAt: ctx.now },
    outcome: { op: op.op, status: 'applied', reason, ...extra },
  })
  const keep = (status: 'unchanged' | 'refused', reason: string, extra: Partial<GroupOutcome> = {}): Step => ({
    group,
    outcome: { op: op.op, status, reason, ...extra },
  })
  const noSection = (name: string) => keep('refused', `No section "${name}" in this group`)

  switch (op.op) {
    case 'setTitle': {
      const title = op.title.trim()
      if (!title) return keep('refused', 'A group needs a title')
      const clash = titleTaken(title, ctx.others, group.id)
      if (clash) return keep('refused', `A group named "${clash.title}" already exists`, { groupId: clash.id })
      if (title === group.title) return keep('unchanged', 'The title is already that')
      return done({ ...group, title }, `Renamed to "${title}"`)
    }
    case 'setDescription': {
      if (op.description.length > GROUP_CAPS.description) {
        return keep('refused', `A description holds at most ${GROUP_CAPS.description} characters`)
      }
      if (op.description === group.description) return keep('unchanged', 'The description is already that')
      return done({ ...group, description: op.description }, 'Description set')
    }
    case 'addSection': {
      const title = op.title.trim()
      if (!title) return keep('refused', 'A section needs a title')
      const clash = findSection(group, title)
      if (clash && fold(clash.title) === fold(title)) {
        return keep('refused', `A section named "${clash.title}" already exists`, { sectionId: clash.id })
      }
      if (group.sections.length >= GROUP_CAPS.sections) {
        return keep('refused', `A group holds at most ${GROUP_CAPS.sections} sections`)
      }
      const section = { id: ctx.newId(), title }
      return done({ ...group, sections: [...group.sections, section] }, `Added section "${title}"`, { sectionId: section.id })
    }
    case 'renameSection': {
      const section = findSection(group, op.section)
      if (!section) return noSection(op.section)
      const title = op.title.trim()
      if (!title) return keep('refused', 'A section needs a title')
      const clash = group.sections.find(one => one.id !== section.id && fold(one.title) === fold(title))
      if (clash) return keep('refused', `A section named "${clash.title}" already exists`, { sectionId: clash.id })
      if (title === section.title) return keep('unchanged', 'The section is already called that', { sectionId: section.id })
      const sections = group.sections.map(one => (one.id === section.id ? { ...one, title } : one))
      return done({ ...group, sections }, `Renamed section to "${title}"`, { sectionId: section.id })
    }
    case 'removeSection': {
      const section = findSection(group, op.section)
      if (!section) return noSection(op.section)
      return done(
        {
          ...group,
          sections: group.sections.filter(one => one.id !== section.id),
          items: group.items.map(one => (one.section === section.id ? placed(one, undefined) : one)),
        },
        `Removed section "${section.title}"; its items moved to the unsectioned block`,
        { sectionId: section.id },
      )
    }
    case 'reorderSections': {
      const sections = op.order.map(name => findSection(group, name))
      const ids = new Set(sections.map(one => one?.id))
      if (sections.some(one => !one) || ids.size !== sections.length || ids.size !== group.sections.length) {
        return keep('refused', 'A reorder names every section exactly once')
      }
      if (sections.every((one, i) => one?.id === group.sections[i]?.id)) return keep('unchanged', 'The sections are already in that order')
      return done({ ...group, sections: sections.filter((one): one is GroupSection => Boolean(one)) }, 'Sections reordered')
    }
    case 'addItem': {
      const ref = op.ref.trim()
      if (!ref) return keep('refused', 'An item needs a file or link')
      if (op.label !== undefined && op.label.length > GROUP_CAPS.label) {
        return keep('refused', `A label holds at most ${GROUP_CAPS.label} characters`, { ref })
      }
      const wanted = ctx.actor === 'person' || op.section === undefined ? undefined : findSection(group, op.section)
      if (ctx.actor === 'agent' && op.section !== undefined && !wanted) return noSection(op.section)
      const present = findItem(group, ref)
      if (present) {
        if (present.section === wanted?.id) return keep('unchanged', `${ref} is already in this group`, { ref })
        return keep('unchanged', `${ref} is already in ${sectionTitle(group, present.section)}; move it to change its place`, {
          ref,
          ...(present.section ? { sectionId: present.section } : {}),
        })
      }
      const key = itemKey(ref)
      const isTombstoned = group.removed.includes(key)
      if (isTombstoned && ctx.actor === 'agent' && !op.force) {
        return keep('refused', `The person removed ${ref} from this group; pass force to add it back`, { ref, needsForce: true })
      }
      if (group.items.length >= GROUP_CAPS.items) return keep('refused', `A group holds at most ${GROUP_CAPS.items} items`, { ref })
      const item: GroupItem = {
        ref,
        ...(wanted ? { section: wanted.id } : {}),
        addedBy: ctx.actor,
        addedAt: ctx.now,
        ...(op.label !== undefined ? { label: op.label } : {}),
      }
      return done(
        { ...group, items: [...group.items, item], removed: isTombstoned ? group.removed.filter(one => one !== key) : group.removed },
        `Added ${ref} to ${sectionTitle(group, wanted?.id)}`,
        { ref },
      )
    }
    case 'moveItem': {
      const present = findItem(group, op.ref)
      if (!present) return keep('refused', `${op.ref} is not in this group`, { ref: op.ref })
      const target = op.section === undefined ? undefined : findSection(group, op.section)
      if (op.section !== undefined && !target) return noSection(op.section)
      if (present.section === target?.id) return keep('unchanged', `${op.ref} is already there`, { ref: op.ref })
      return done(
        { ...group, items: group.items.map(one => (one === present ? placed(one, target?.id) : one)) },
        `Moved ${op.ref} to ${sectionTitle(group, target?.id)}`,
        { ref: op.ref },
      )
    }
    case 'removeItem': {
      const present = findItem(group, op.ref)
      if (!present) return keep('unchanged', `${op.ref} is not in this group`, { ref: op.ref })
      if (ctx.actor === 'agent' && present.addedBy === 'person' && !op.force) {
        return keep('refused', `The person added ${present.ref}; pass force to remove it`, { ref: present.ref, needsForce: true })
      }
      return done(
        {
          ...group,
          items: group.items.filter(one => one !== present),
          removed: ctx.actor === 'person' ? tombstone(group.removed, itemKey(present.ref)) : group.removed,
        },
        `Removed ${present.ref}`,
        { ref: present.ref },
      )
    }
  }
}

export function applyGroupOps(group: Group, ops: readonly GroupOp[], ctx: GroupContext): { group: Group; outcomes: GroupOutcome[] } {
  const outcomes: GroupOutcome[] = []
  let current = group
  for (const op of ops) {
    const step = applyOne(current, op, ctx)
    current = step.group
    outcomes.push(step.outcome)
  }
  return { group: current, outcomes }
}

export function createGroup(
  input: { projectKey: string; id?: string; title: string; description?: string },
  ops: readonly GroupOp[],
  ctx: GroupContext,
): GroupResult {
  const refuse = (reason: string, groupId?: string): GroupResult => ({
    group: null,
    outcomes: [{ op: 'create', status: 'refused', reason, ...(groupId ? { groupId } : {}) }],
  })
  const title = input.title.trim()
  if (!title) return refuse('A group needs a title')
  const clash = titleTaken(title, ctx.others)
  if (clash) return refuse(`A group named "${clash.title}" already exists`, clash.id)
  if (ctx.others.length >= GROUP_CAPS.groups) return refuse(`A project holds at most ${GROUP_CAPS.groups} groups`)
  const empty: Group = {
    projectKey: input.projectKey,
    id: input.id ?? ctx.newId(),
    title,
    description: '',
    starred: false,
    updatedAt: ctx.now,
    sections: [],
    items: [],
    removed: [],
  }
  const setup: GroupOp[] = input.description ? [{ op: 'setDescription', description: input.description }] : []
  const applied = applyGroupOps(empty, [...setup, ...ops], ctx)
  return {
    group: applied.group,
    outcomes: [{ op: 'create', status: 'applied', reason: `Created "${title}"`, groupId: empty.id }, ...applied.outcomes],
  }
}

export function starGroup(group: Group, starred: boolean, now: number): { group: Group; outcomes: GroupOutcome[] } {
  if (group.starred === starred) {
    return { group, outcomes: [{ op: 'star', status: 'unchanged', reason: starred ? 'Already starred' : 'Not starred' }] }
  }
  return {
    group: { ...group, starred, updatedAt: now },
    outcomes: [{ op: 'star', status: 'applied', reason: starred ? 'Starred' : 'Unstarred' }],
  }
}

export function deleteGroup(group: Group, force = false): GroupResult {
  const theirs = group.items.filter(one => one.addedBy === 'person').map(one => one.ref)
  const losses = [...(group.starred ? ['the person starred it'] : []), ...(theirs.length ? [`the person added ${theirs.join(', ')}`] : [])]
  if (losses.length && !force) {
    return {
      group,
      outcomes: [{ op: 'delete', status: 'refused', reason: `Not deleted: ${losses.join('; ')}. Pass force to delete it anyway`, groupId: group.id, needsForce: true }],
    }
  }
  return { group: null, outcomes: [{ op: 'delete', status: 'applied', reason: `Deleted "${group.title}"`, groupId: group.id }] }
}
