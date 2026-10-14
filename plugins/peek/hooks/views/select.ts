import type { PropScalar, PropValue } from '../../types'
import { CLOSED_STATUSES } from '../tasks/status-words'
import type { Item } from './items'

export type Rule = Record<string, PropScalar>
export type CycleReport = { kind: 'sequence' | 'parent'; ids: string[] }
export type Ordered = { items: Item[]; cycles: CycleReport[] }
export type TreeNode = { item: Item; children: TreeNode[]; childCount: number; parentName?: string }
export type Tree = { roots: TreeNode[]; cycles: CycleReport[] }
export type Section = { key: string; items: Item[] }
export type TreeSection = { key: string; roots: TreeNode[] }
export type Sectioned = { sections: TreeSection[]; cycles: CycleReport[] }
export type FocusBuckets = { now: Item[]; next: Item[]; later: Item[]; cycles: CycleReport[] }

export const NONE_SECTION = 'none'
export const FOCUS_NEXT_CAP = 5
const ITEM_FIELDS = ['id', 'href', 'type', 'name'] as const

export function parseRule(text: string): Rule {
  const rule: Rule = {}
  for (const pair of text.split(/\s+and\s+/)) {
    const at = pair.indexOf('=')
    if (at > 0) rule[pair.slice(0, at).trim()] = pair.slice(at + 1).trim()
  }
  return rule
}

function lookup(item: Item, key: string): PropValue | undefined {
  if (Object.prototype.hasOwnProperty.call(item.props, key)) return item.props[key]
  return (ITEM_FIELDS as readonly string[]).includes(key) ? item[key as (typeof ITEM_FIELDS)[number]] : undefined
}

// Unlike definition.ts matches(), text compares to a boolean or number prop by its printed form, because block info
// options arrive as text: `isTask=true` must select `isTask: true`.
function scalarMatches(value: PropValue | undefined, expected: PropScalar): boolean {
  if (value === expected) return true
  return typeof expected === 'string' && (typeof value === 'boolean' || typeof value === 'number') && String(value) === expected
}

export function matchesRule(item: Item, rule: Rule): boolean {
  return Object.entries(rule).every(([key, expected]) => {
    const value = lookup(item, key)
    return Array.isArray(value) ? value.some(one => scalarMatches(one, expected)) : scalarMatches(value, expected)
  })
}

export function select(items: readonly Item[], how: { rule?: Rule; cap?: number }): Item[] {
  const rule = how.rule
  const matching = rule === undefined ? [...items] : items.filter(item => matchesRule(item, rule))
  return how.cap === undefined ? matching : matching.slice(0, Math.max(0, how.cap))
}

function compareItems(a: Item, b: Item): number {
  const dueA = typeof a.props.due === 'string' ? a.props.due : undefined
  const dueB = typeof b.props.due === 'string' ? b.props.due : undefined
  if (dueA !== dueB) {
    if (dueA === undefined) return 1
    if (dueB === undefined) return -1
    return dueA < dueB ? -1 : 1
  }
  return a.name.localeCompare(b.name) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)
}

function resolver(items: readonly Item[]): (ref: unknown) => number | undefined {
  const at = new Map<string, number>()
  items.forEach((item, index) => {
    if (!at.has(item.id)) at.set(item.id, index)
  })
  items.forEach((item, index) => {
    if (!at.has(item.href)) at.set(item.href, index)
  })
  return ref => (typeof ref === 'string' ? at.get(ref) : undefined)
}

function refs(value: PropValue | undefined): unknown[] {
  return Array.isArray(value) ? value : [value]
}

type SequenceLinks = { preds: Set<number>[]; together: [number, number][] }

function sequenceLinks(items: readonly Item[]): SequenceLinks {
  const resolve = resolver(items)
  const preds = items.map(() => new Set<number>())
  const together: [number, number][] = []
  items.forEach((item, index) => {
    const sequence = item.props.sequence
    if (typeof sequence !== 'object' || sequence === null || Array.isArray(sequence)) return
    const each = (key: string, use: (other: number) => void) => {
      for (const ref of refs(sequence[key])) {
        const other = resolve(ref)
        if (other !== undefined && other !== index) use(other)
      }
    }
    each('after', other => preds[index]?.add(other))
    each('before', other => preds[other]?.add(index))
    each('with', other => together.push([index, other]))
  })
  return { preds, together }
}

// Kahn's sort over "with" groups, always taking the earliest-due ready group, so sequence wins and due only breaks ties.
export function order(items: readonly Item[]): Ordered {
  const { preds, together } = sequenceLinks(items)
  const root = items.map((_, index) => index)
  const find = (index: number): number => {
    while (root[index] !== index) index = root[index] ?? index
    return index
  }
  for (const [a, b] of together) root[find(a)] = find(b)
  const members = new Map<number, number[]>()
  items.forEach((_, index) => members.set(find(index), [...(members.get(find(index)) ?? []), index]))
  const byKey = (a: number, b: number) => compareItems(items[a] as Item, items[b] as Item)
  for (const list of members.values()) list.sort(byKey)
  const groupPreds = new Map<number, Set<number>>()
  for (const group of members.keys()) groupPreds.set(group, new Set())
  preds.forEach((set, index) => {
    for (const pred of set) if (find(pred) !== find(index)) groupPreds.get(find(index))?.add(find(pred))
  })
  const head = (group: number) => members.get(group)?.[0] ?? group
  const byGroupKey = (a: number, b: number) => byKey(head(a), head(b))
  const remaining = new Set(members.keys())
  const out: Item[] = []
  const cycles: CycleReport[] = []
  while (remaining.size) {
    const ready = [...remaining].filter(group => !groupPreds.get(group)?.size).sort(byGroupKey)
    let next = ready[0]
    if (next === undefined) {
      const cycle = findCycle([...remaining].sort(byGroupKey)[0] as number, group => [...(groupPreds.get(group) ?? [])].sort(byGroupKey))
      next = [...cycle].sort(byGroupKey)[0] as number
      cycles.push({ kind: 'sequence', ids: cycle.flatMap(group => members.get(group) ?? []).sort(byKey).map(index => (items[index] as Item).id) })
    }
    remaining.delete(next)
    for (const index of members.get(next) ?? []) out.push(items[index] as Item)
    for (const group of remaining) groupPreds.get(group)?.delete(next)
  }
  return { items: out, cycles }
}

// Every node walked has an unfinished predecessor, so the walk must revisit one; the loop from there is the cycle.
function findCycle(start: number, stepsFrom: (node: number) => number[]): number[] {
  const path: number[] = []
  let node: number | undefined = start
  while (node !== undefined && !path.includes(node)) {
    path.push(node)
    node = stepsFrom(node)[0]
  }
  return node === undefined ? path : path.slice(path.indexOf(node))
}

function linkParents(ordered: readonly Item[], parentProp: string): { parentOf: (number | undefined)[]; cycles: CycleReport[] } {
  const resolve = resolver(ordered)
  const parentOf = ordered.map((item, index) => {
    const parent = resolve(item.props[parentProp])
    return parent === index ? undefined : parent
  })
  const cycles: CycleReport[] = []
  const settled = new Set<number>()
  ordered.forEach((_, start) => {
    const walk: number[] = []
    let node: number | undefined = start
    while (node !== undefined && !settled.has(node) && !walk.includes(node)) {
      walk.push(node)
      node = parentOf[node]
    }
    if (node !== undefined && walk.includes(node)) {
      const cycle = walk.slice(walk.indexOf(node)).sort((a, b) => a - b)
      parentOf[cycle[0] as number] = undefined
      cycles.push({ kind: 'parent', ids: cycle.map(index => (ordered[index] as Item).id) })
    }
    for (const one of walk) settled.add(one)
  })
  return { parentOf, cycles }
}

function countChildren(parentOf: readonly (number | undefined)[]): number[] {
  const counts = parentOf.map(() => 0)
  for (const parent of parentOf) if (parent !== undefined) counts[parent] = (counts[parent] ?? 0) + 1
  return counts
}

export function nest(items: readonly Item[], parentProp = 'parent'): Tree {
  const ordered = order(items)
  const { parentOf, cycles } = linkParents(ordered.items, parentProp)
  const counts = countChildren(parentOf)
  const nodes: TreeNode[] = ordered.items.map((item, index) => ({ item, children: [], childCount: counts[index] ?? 0 }))
  const roots: TreeNode[] = []
  nodes.forEach((node, index) => {
    const parent = parentOf[index]
    const holder = parent === undefined ? roots : (nodes[parent] as TreeNode).children
    holder.push(node)
  })
  return { roots, cycles: [...ordered.cycles, ...cycles] }
}

function sectionKey(item: Item, prop: string): string {
  const value = lookup(item, prop)
  if (Array.isArray(value)) return value.length ? value.map(String).join(', ') : NONE_SECTION
  if (value === undefined || value === null || typeof value === 'object') return NONE_SECTION
  const text = String(value).trim()
  return text || NONE_SECTION
}

function sectionOrder(keys: readonly string[], values: readonly string[]): string[] {
  const present = new Set(keys)
  const declared = values.filter(value => present.has(value) && value !== NONE_SECTION)
  const others = [...present].filter(key => key !== NONE_SECTION && !declared.includes(key)).sort((a, b) => a.localeCompare(b))
  return [...declared, ...others, ...(present.has(NONE_SECTION) ? [NONE_SECTION] : [])]
}

export function split(items: readonly Item[], prop: string, values: readonly string[] = []): Section[] {
  const keys = items.map(item => sectionKey(item, prop))
  return sectionOrder(keys, values).map(key => ({ key, items: items.filter((_, index) => keys[index] === key) }))
}

export function sectioned(items: readonly Item[], how: { split: string; values?: readonly string[]; parentProp?: string }): Sectioned {
  const ordered = order(items)
  const list = ordered.items
  const { parentOf, cycles } = linkParents(list, how.parentProp ?? 'parent')
  const counts = countChildren(parentOf)
  const keys = list.map(item => sectionKey(item, how.split))
  const sections = sectionOrder(keys, how.values ?? []).map(key => {
    const nodes = new Map<number, TreeNode>()
    list.forEach((item, index) => {
      const parent = parentOf[index]
      const isCrossed = parent !== undefined && keys[parent] !== key
      if (keys[index] === key) nodes.set(index, { item, children: [], childCount: counts[index] ?? 0, ...(isCrossed ? { parentName: (list[parent] as Item).name } : {}) })
    })
    const crossed: TreeNode[] = []
    const roots: TreeNode[] = []
    for (const [index, node] of nodes) {
      const parent = parentOf[index]
      const holder = parent === undefined ? roots : nodes.get(parent)?.children ?? crossed
      holder.push(node)
    }
    return { key, roots: [...crossed, ...roots] }
  })
  return { sections, cycles: [...ordered.cycles, ...cycles] }
}

export function focus(items: readonly Item[]): FocusBuckets {
  const ordered = order(items)
  const list = ordered.items
  const status = (item: Item) => (typeof item.props.status === 'string' ? item.props.status : '')
  const { preds } = sequenceLinks(list)
  const isWaiting = (index: number) => [...(preds[index] ?? [])].some(pred => !CLOSED_STATUSES.has(status(list[pred] as Item)))
  const now = list.filter(item => status(item) === 'doing')
  const next = list.filter((item, index) => status(item) === 'todo' && !isWaiting(index)).slice(0, FOCUS_NEXT_CAP)
  const later = list.filter(item => !CLOSED_STATUSES.has(status(item)) && status(item) !== 'doing' && !next.includes(item))
  return { now, next, later, cycles: ordered.cycles }
}
