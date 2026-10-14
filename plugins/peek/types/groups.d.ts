import type { PropScalar } from './index'

export type GroupActor = 'agent' | 'person'

export type GroupRule = Record<string, PropScalar>

export type SectionLayout = 'cards' | 'list'

export type GroupSection = { id: string; title: string; layout?: SectionLayout }

// 'rule' marks a member computed from the group's rule when it is read; it is never stored.
export type GroupItem = { ref: string; section?: string; addedBy: GroupActor | 'rule'; addedAt: number; label?: string }

export type Group = {
  projectKey: string
  id: string
  title: string
  description: string
  starred: boolean
  updatedAt: number
  sections: GroupSection[]
  items: GroupItem[]
  removed: string[]
  rule?: GroupRule
  split?: string
}

// A section is named by its id or, case-insensitively, by its title, so one call can add a section and fill it.
export type GroupOp =
  | { op: 'setTitle'; title: string }
  | { op: 'setDescription'; description: string }
  | { op: 'addSection'; title: string; layout?: SectionLayout }
  | { op: 'renameSection'; section: string; title: string }
  | { op: 'removeSection'; section: string }
  | { op: 'setSectionLayout'; section: string; layout: SectionLayout }
  | { op: 'reorderSections'; order: string[] }
  | { op: 'addItem'; ref: string; section?: string; label?: string; force?: boolean }
  | { op: 'moveItem'; ref: string; section?: string }
  | { op: 'removeItem'; ref: string; force?: boolean }
  | { op: 'setRule'; rule: GroupRule | null }
  | { op: 'setSplit'; split: string | null }

export type GroupOutcome = {
  op: GroupOp['op'] | 'create' | 'delete' | 'star'
  status: 'applied' | 'unchanged' | 'refused'
  reason: string
  ref?: string
  groupId?: string
  sectionId?: string
  needsForce?: boolean
}

export type GroupResult = { group: Group | null; outcomes: GroupOutcome[] }

// ruleMembers lists the refs the group's rule matched when the caller last read it, so a removal can name them.
export type GroupContext = { now: number; newId: () => string; actor: GroupActor; others: readonly Group[]; ruleMembers?: readonly string[] }
