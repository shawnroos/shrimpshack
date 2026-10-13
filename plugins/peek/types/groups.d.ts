export type GroupActor = 'agent' | 'person'

export type SectionLayout = 'cards' | 'list'

export type GroupSection = { id: string; title: string; layout?: SectionLayout }

export type GroupItem = { ref: string; section?: string; addedBy: GroupActor; addedAt: number; label?: string }

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

export type GroupContext = { now: number; newId: () => string; actor: GroupActor; others: readonly Group[] }
