import type { Group, GroupOp, GroupOutcome, GroupRule, SectionLayout } from '../types/groups'
import { toHref } from './entries'
import { plural } from './format'
import { createGroup, deleteGroup, isGroupId, layoutOf, listGroups, membersOf, readGroup, refused, shortId, splitMembers, applyGroupOps } from './groups'
import type { GroupWrite } from './groups'
import { type GroupTarget, groupHome, groupTarget, itemState, ruleCandidates, setStar } from './groups-session'
import { titlesByKey } from './refresh'
import type { NavIo } from './navigation'
import { parseHref } from './paths'
import { itemKey } from './refs'
import { TASK_TOOLS } from './task-tools'
import type { TaskToolName } from './task-tools'
import { parseRule } from './views/select'
import { checkRecipeTool, checkToolSpec, openTool, openToolSpec } from './recipes/tools'

type ToolName = 'star' | 'list_groups' | 'read_group' | 'save_group' | 'delete_group' | 'open' | 'check_recipe' | TaskToolName
type ToolSpec = { name: ToolName; description: string; inputSchema: Record<string, unknown>; isDeferred?: boolean }
type PeekTool = { spec: ToolSpec | ((pluginRoot: string) => ToolSpec); run: (io: NavIo, input: unknown) => Promise<{ result: string }> }

// A rule group's members are computed on every read, so the item list, its count and the split all come from here.
async function withMembers(io: NavIo, group: Group, worktreeRoot?: string) {
  const candidates = await ruleCandidates(io, [group], worktreeRoot)
  const members = membersOf(group, candidates, worktreeRoot)
  return { members, splitSections: splitMembers(group, members, candidates, worktreeRoot) }
}

async function groupJson(io: NavIo, group: Group, worktreeRoot?: string) {
  const known = titlesByKey()
  const { members, splitSections } = await withMembers(io, group, worktreeRoot)
  const items = await Promise.all(
    members.map(async one => ({
      ref: one.ref,
      title: known.get(itemKey(one.ref))?.title ?? null,
      label: one.label ?? null,
      section: one.section ?? null,
      addedBy: one.addedBy,
      state: await itemState(io, one.ref, worktreeRoot),
    })),
  )
  return {
    id: group.id,
    title: group.title,
    description: group.description,
    starred: group.starred,
    ...(group.rule ? { rule: group.rule } : {}),
    ...(group.split ? { split: group.split } : {}),
    sections: group.sections.map(one => ({ ...one, layout: layoutOf(one) })),
    items,
    ...(splitSections ? { splitSections: splitSections.map(one => ({ key: one.key, items: one.items.map(item => item.ref) })) } : {}),
    removed: group.removed,
  }
}

function tally(outcomes: readonly GroupOutcome[]): string {
  const count = (status: GroupOutcome['status']) => outcomes.filter(one => one.status === status).length
  return `${count('applied')} applied, ${count('unchanged')} unchanged, ${count('refused')} refused`
}

const failedWrite = (verb: string, write: Extract<GroupWrite, { ok: false }>) => ({ result: `Could not ${verb}: ${write.error}. Nothing was changed.` })

type SaveInput = {
  id?: unknown
  title?: unknown
  description?: unknown
  sections?: unknown
  order?: unknown
  add?: unknown
  move?: unknown
  remove?: unknown
  rule?: unknown
  split?: unknown
}

const isText = (value: unknown): value is string => typeof value === 'string'

const isGroupRef = (id: unknown): id is string => isText(id) && isGroupId(id)

const badId = (id: unknown) => ({ result: `${String(id)} is not a group id. Use an id from list_groups.` })

const listOf = (value: unknown): Record<string, unknown>[] | null =>
  value === undefined ? [] : Array.isArray(value) && value.every(one => one && typeof one === 'object') ? (value as Record<string, unknown>[]) : null

function sectionOps(value: unknown): GroupOp[] | string {
  const list = listOf(value)
  if (!list) return 'sections must be a list of { action, section, title }'
  const ops: GroupOp[] = []
  for (const one of list) {
    const isLaid = one.action === 'layout' || (one.action === 'add' && one.layout !== undefined)
    if (isLaid && one.layout !== 'cards' && one.layout !== 'list') return `A section layout is cards or list, not "${String(one.layout)}"`
    const layout = one.layout as SectionLayout
    if (one.action === 'add' && isText(one.title)) ops.push({ op: 'addSection', title: one.title, ...(isLaid ? { layout } : {}) })
    else if (one.action === 'layout' && isText(one.section)) ops.push({ op: 'setSectionLayout', section: one.section, layout })
    else if (one.action === 'rename' && isText(one.section) && isText(one.title)) ops.push({ op: 'renameSection', section: one.section, title: one.title })
    else if (one.action === 'remove' && isText(one.section)) ops.push({ op: 'removeSection', section: one.section })
    else return `Unreadable section change ${JSON.stringify(one)}`
  }
  return ops
}

const RULE_HELP = 'rule is text like "creator=shawn and status=todo", or an object of prop values.'

// undefined leaves the rule alone; null, empty text or an empty object clears it.
function ruleOp(value: unknown): GroupOp[] | string {
  if (value === undefined) return []
  if (value === null || value === '') return [{ op: 'setRule', rule: null }]
  if (isText(value)) {
    const rule = parseRule(value)
    return Object.keys(rule).length ? [{ op: 'setRule', rule }] : RULE_HELP
  }
  if (typeof value === 'object' && !Array.isArray(value)) return [{ op: 'setRule', rule: value as GroupRule }]
  return RULE_HELP
}

function splitOp(value: unknown): GroupOp[] | string {
  if (value === undefined) return []
  if (value === null || isText(value)) return [{ op: 'setSplit', split: value || null }]
  return 'split is a prop name.'
}

async function saveGroup(io: NavIo, input: SaveInput) {
  const home = await groupHome(io)
  if (!home) return { result: 'Could not save the group: HOME is not set.' }
  const { place, worktreeRoot } = home
  const id = input.id
  if (id !== undefined && !isGroupRef(id)) return badId(id)
  if (input.title !== undefined && !isText(input.title)) return { result: 'title must be text.' }
  if (input.description !== undefined && !isText(input.description)) return { result: 'description must be text.' }
  if (id === undefined && !isText(input.title)) return { result: 'Give a title to create a group, or an id to change one.' }
  const sections = sectionOps(input.sections)
  if (typeof sections === 'string') return { result: sections }
  const rule = ruleOp(input.rule)
  if (typeof rule === 'string') return { result: rule }
  const split = splitOp(input.split)
  if (typeof split === 'string') return { result: split }
  const order = input.order
  if (order !== undefined && !(Array.isArray(order) && order.every(isText))) return { result: 'order must be a list of section ids or titles.' }
  const adds = listOf(input.add)
  const moves = listOf(input.move)
  const removes = listOf(input.remove)
  if (!adds || !moves || !removes || [...adds, ...moves, ...removes].some(one => !isText(one.target))) {
    return { result: 'add, move and remove are lists of objects, each with a target.' }
  }

  const resolveAll = (list: Record<string, unknown>[], isAdd: boolean) => Promise.all(list.map(one => groupTarget(io, String(one.target), worktreeRoot, isAdd)))
  const [added, moved, removed] = await Promise.all([resolveAll(adds, true), resolveAll(moves, false), resolveAll(removes, false)])
  const rejected: GroupOutcome[] = added.flatMap(one => ('error' in one ? [refused('addItem', one.error, { ref: one.raw })] : []))
  const optional = <T,>(value: unknown, wrap: (v: string) => T) => (isText(value) ? wrap(value) : {})
  const opsFor = (group: Group | null): GroupOp[] => {
    const pick = (target: Extract<GroupTarget, { ref: string }>) => {
      const exact = group?.items.find(one => itemKey(one.ref) === itemKey(target.raw))
      return exact ? exact.ref : target.ref
    }
    return [
      ...rule,
      ...split,
      ...sections,
      ...(order ? [{ op: 'reorderSections' as const, order: order as string[] }] : []),
      ...added.flatMap((one, i) =>
        'error' in one
          ? []
          : [{ op: 'addItem' as const, ref: one.ref, ...optional(adds[i]?.section, section => ({ section })), ...optional(adds[i]?.label, label => ({ label })), ...(adds[i]?.force === true ? { force: true } : {}) }],
      ),
      ...moved.flatMap((one, i) => ('error' in one ? [] : [{ op: 'moveItem' as const, ref: pick(one), ...optional(moves[i]?.section, section => ({ section })) }])),
      ...removed.flatMap((one, i) => ('error' in one ? [] : [{ op: 'removeItem' as const, ref: pick(one), ...(removes[i]?.force === true ? { force: true } : {}) }])),
    ]
  }

  const isCreate = id === undefined
  const others = isCreate || isText(input.title) ? await listGroups(io.groupsIo(), place) : []
  const existing = !isCreate && removes.length ? await readGroup(io.groupsIo(), place, id) : null
  const candidates = existing ? await ruleCandidates(io, [existing], worktreeRoot) : []
  // Read before the write, as the person's remove does, so removing a rule member tells the agent to change the rule.
  const ruleMembers = (current: Group) => membersOf(current, candidates, worktreeRoot).flatMap(one => (one.addedBy === 'rule' ? [one.ref] : []))
  const ctx = { now: await io.now(), newId: () => shortId(Math.random), actor: 'agent' as const }
  const target = isCreate ? freshId(others) : id
  const write = await io.writeGroup(place, target, current => {
    if (isCreate) {
      if (current) return { group: current, outcomes: [refused('create', 'That id is taken; try again')] }
      return createGroup(
        { projectKey: place.projectKey, id: target, title: String(input.title), ...optional(input.description, description => ({ description })) },
        opsFor(null),
        { ...ctx, others },
      )
    }
    if (!current) return { group: null, outcomes: [refused('setTitle', `No group ${target} in this project; it may have been deleted`)] }
    const head: GroupOp[] = [
      ...(isText(input.title) ? [{ op: 'setTitle' as const, title: input.title }] : []),
      ...(isText(input.description) ? [{ op: 'setDescription' as const, description: input.description }] : []),
    ]
    return applyGroupOps(current, [...head, ...opsFor(current)], { ...ctx, others: others.filter(one => one.id !== target), ruleMembers: ruleMembers(current) })
  })
  if (!write.ok) return failedWrite(isCreate ? 'create the group' : 'save the group', write)
  if (write.isChanged) io.invalidate()
  const outcomes = [...write.outcomes, ...rejected]
  const group = write.group
  if (isCreate && !write.isChanged) return { result: `Not created: ${outcomes[0]?.reason ?? 'refused'}.\n${JSON.stringify({ outcomes })}` }
  if (!group) return { result: `Not saved: ${outcomes[0]?.reason ?? 'unknown group'}.\n${JSON.stringify({ outcomes })}` }
  const line = `${isCreate ? 'Created' : 'Saved'} group "${group.title}" (${group.id}): ${tally(isCreate ? outcomes.slice(1) : outcomes)}.`
  return { result: `${line}\n${JSON.stringify({ ...(await groupJson(io, group, worktreeRoot)), outcomes })}` }
}

const TARGET_HELP = 'A file path (absolute, or relative to the session folder), a URL, a GitHub owner/repo#N, or a Linear key'

export const TOOLS: Record<ToolName, PeekTool> = {
  star: {
    spec: {
      name: 'star',
      description:
        'Star or unstar a file path or URL in the peek side pane, so it sorts first in Recent and Gallery. Star the things the user should look at: a plan, a report, a diagram you made. Use sparingly. For several related files and links, make a peek group instead (save_group).',
      inputSchema: {
        type: 'object',
        properties: {
          target: { type: 'string', description: 'An absolute or relative file path, or an http(s) URL' },
          starred: { type: 'boolean', description: 'true to star (the default), false to unstar' },
        },
        required: ['target'],
      },
    },
    run: starTool,
  },
  list_groups: {
    spec: {
      name: 'list_groups',
      description:
        'List the peek groups in this project: titled bundles of related files and links (a collection) shown in the peek side pane. Returns each group id, title, description, star, rule, split and counts; a rule group counts the items its rule matches now. Call before save_group to reuse a group rather than make a near-duplicate.',
      inputSchema: { type: 'object', properties: {} },
    },
    run: io => listGroupsTool(io),
  },
  read_group: {
    spec: {
      name: 'read_group',
      description:
        'Read one peek group (a collection or bundle of files and links) in full: title, description, rule, split, sections, and every item (file or link) with its title (null until peek has fetched it), label, section id, who added it (agent, person, or rule for an item the rule matched) and state (ok, missing, unavailable). With a split, splitSections lists the items under each value of that prop. Read before you change a group: the person may have added or removed items.',
      inputSchema: { type: 'object', properties: { id: { type: 'string', description: 'The group id from list_groups' } }, required: ['id'] },
    },
    run: (io, input) => readGroupTool(io, (input as { id?: unknown }).id),
  },
  save_group: {
    spec: {
      name: 'save_group',
      description:
        'Create or change a peek group: a titled, described bundle of files and links with sections, kept per project in the peek side pane so the person can come back to it. Without id it creates a group (title required); with id it applies the given changes. Changes are edits, never a replace: items the person added stay unless you remove one by name with force, and an item the person removed is only re-added with force. Sections are named by id or title, so one call can add a section and fill it. A section shows its items as cards (the default) or as a list of lines; set it with layout on add, or with the layout action. A rule makes the group fill and empty itself: every task whose props match it is a member, read fresh each time (for example creator=shawn, or list=<session>#1). A split sections the members by one prop, such as status.',
      inputSchema: {
        type: 'object',
        properties: {
          id: { type: 'string', description: 'The group to change; leave out to create one' },
          title: { type: 'string' },
          description: { type: 'string', description: 'Up to 500 characters' },
          sections: {
            type: 'array',
            description: 'Section changes, applied in order before item changes',
            items: {
              type: 'object',
              properties: {
                action: { type: 'string', enum: ['add', 'rename', 'remove', 'layout'] },
                section: { type: 'string', description: 'Section id or title, for rename, remove and layout' },
                title: { type: 'string', description: 'New title, for add and rename' },
                layout: { type: 'string', enum: ['cards', 'list'], description: 'How the section shows its items, for add and layout: cards (the default) or list' },
              },
              required: ['action'],
            },
          },
          rule: {
            description: 'Props every member matches, as text like "creator=shawn and status=todo" or an object { prop: value }; null or empty text clears it',
          },
          split: { type: 'string', description: 'A prop name to section the members by, such as status; empty text clears it' },
          order: { type: 'array', items: { type: 'string' }, description: 'Every section, by id or title, in the new order' },
          add: {
            type: 'array',
            items: {
              type: 'object',
              properties: {
                target: { type: 'string', description: TARGET_HELP },
                section: { type: 'string', description: 'Section id or title; leave out for the top block' },
                label: { type: 'string', description: 'A short note shown with the item, up to 200 characters' },
                force: { type: 'boolean', description: 'Re-add an item the person removed' },
              },
              required: ['target'],
            },
          },
          move: {
            type: 'array',
            items: {
              type: 'object',
              properties: { target: { type: 'string' }, section: { type: 'string', description: 'Leave out to move to the top block' } },
              required: ['target'],
            },
          },
          remove: {
            type: 'array',
            items: {
              type: 'object',
              properties: { target: { type: 'string' }, force: { type: 'boolean', description: 'Remove an item the person added' } },
              required: ['target'],
            },
          },
        },
      },
    },
    run: (io, input) => saveGroup(io, input as SaveInput),
  },
  delete_group: {
    spec: {
      name: 'delete_group',
      description:
        'Delete a peek group: a collection or bundle of files and links. A group the person starred, or one holding items the person added, needs force; without it you are told what would be lost.',
      inputSchema: {
        type: 'object',
        properties: { id: { type: 'string' }, force: { type: 'boolean', description: 'Delete even a starred group or one with items the person added' } },
        required: ['id'],
      },
    },
    run: (io, input) => {
      const one = input as { id?: unknown; force?: unknown }
      return deleteGroupTool(io, one.id, one.force === true)
    },
  },
  open: { spec: openToolSpec, run: (io, input) => openTool(io, (input as { link?: unknown }).link) },
  check_recipe: { spec: checkToolSpec, run: (io, input) => checkRecipeTool(io, input as { recipe?: unknown; link?: unknown }) },
  ...TASK_TOOLS,
}

async function starTool(io: NavIo, e: unknown) {
  const input = e as { target?: unknown; starred?: unknown }
  if (typeof input.target !== 'string') return { result: 'Give a target: a file path or URL.' }
  const target = input.target
  const href = await toHref(io, target).catch(() => null)
  if (!href) return { result: `No file or URL at ${target}.` }
  const isOn = await setStar(io, href, input.starred !== false).catch(() => null)
  if (isOn === null) return { result: 'Could not save the star.' }
  return { result: `${isOn ? 'Starred' : 'Unstarred'} ${parseHref(href)?.path ?? href} in peek.` }
}

async function listGroupsTool(io: NavIo) {
  const home = await groupHome(io)
  if (!home) return { result: 'Could not list groups: HOME is not set.' }
  const groups = await listGroups(io.groupsIo(), home.place)
  const candidates = await ruleCandidates(io, groups, home.worktreeRoot)
  const summaries = groups.map(one => ({
    id: one.id,
    title: one.title,
    description: one.description,
    starred: one.starred,
    sections: one.sections.length,
    items: membersOf(one, candidates, home.worktreeRoot).length,
    ...(one.rule ? { rule: one.rule } : {}),
    ...(one.split ? { split: one.split } : {}),
    updatedAt: one.updatedAt,
  }))
  const line = groups.length ? `${plural(groups.length, 'group')} in this project.` : 'No groups in this project yet.'
  return { result: `${line}\n${JSON.stringify(summaries)}` }
}

async function readGroupTool(io: NavIo, id: unknown) {
  if (!isGroupRef(id)) return badId(id)
  const home = await groupHome(io)
  if (!home) return { result: 'Could not read the group: HOME is not set.' }
  const group = await readGroup(io.groupsIo(), home.place, id)
  if (!group) return { result: `No group ${id} in this project.` }
  const json = await groupJson(io, group, home.worktreeRoot)
  const line = `Group "${group.title}" (${group.id}): ${plural(json.items.length, 'item')} in ${plural(group.sections.length, 'section')}.`
  return { result: `${line}\n${JSON.stringify(json)}` }
}

async function deleteGroupTool(io: NavIo, id: unknown, force: boolean) {
  if (!isGroupRef(id)) return badId(id)
  const home = await groupHome(io)
  if (!home) return { result: 'Could not delete the group: HOME is not set.' }
  let title = ''
  const write = await io.writeGroup(home.place, id, current => {
    if (!current) return { group: null, outcomes: [refused('delete', `No group ${id} in this project`)] }
    title = current.title
    return deleteGroup(current, force)
  })
  if (!write.ok) return failedWrite('delete the group', write)
  const [outcome] = write.outcomes
  if (!write.isChanged) return { result: outcome?.reason.startsWith('Not deleted') ? outcome.reason : `Not deleted: ${outcome?.reason ?? 'refused'}.` }
  io.invalidate()
  return { result: `Deleted group "${title}" (${id}).` }
}

function freshId(others: readonly Group[]): string {
  const taken = new Set(others.map(one => one.id))
  let id = shortId(Math.random)
  while (taken.has(id)) id = shortId(Math.random)
  return id
}
