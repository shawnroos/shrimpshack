export const ISSUE_WITH_PROJECT = {
  identifier: 'WEB-2757',
  title: 'Remove Logo',
  description: 'The logo should go.',
  url: 'https://linear.app/acme/issue/WEB-2757/remove-logo',
  priority: 2,
  priorityLabel: 'High',
  state: { name: 'In Progress', type: 'started' },
  assignee: { name: 'Ada Lovelace' },
  labels: { nodes: [{ name: 'Bug' }, { name: 'Editor' }] },
  parent: { identifier: 'WEB-2700', title: 'Logo cleanup' },
  project: { name: 'Brand refresh', url: 'https://linear.app/acme/project/brand-refresh-1a2b3c4d5e6f' },
  projectMilestone: { name: 'Beta' },
  team: { key: 'WEB', name: 'Web' },
  createdAt: '2026-10-01T09:00:00.000Z',
  updatedAt: '2026-10-05T12:30:00.000Z',
  completedAt: null,
  canceledAt: null,
  comments: {
    nodes: [
      { id: 'c3', body: 'A reply', createdAt: '2026-10-03T10:00:00.000Z', user: { name: 'Grace' }, parent: { id: 'c1' } },
      { id: 'c1', body: 'First thought', createdAt: '2026-10-02T10:00:00.000Z', user: { name: 'Ada Lovelace' }, parent: null },
      { id: 'c2', body: 'Second thread', createdAt: '2026-10-02T11:00:00.000Z', user: { name: 'Linus' }, parent: null },
    ],
    pageInfo: { hasPreviousPage: false },
  },
}

export const ISSUE_NO_PROJECT = {
  identifier: 'WEB-12',
  title: 'Loose issue',
  description: null,
  url: 'https://linear.app/acme/issue/WEB-12/loose-issue',
  priority: 0,
  priorityLabel: 'No priority',
  state: { name: 'Done', type: 'completed' },
  assignee: null,
  labels: { nodes: [] },
  parent: null,
  project: null,
  projectMilestone: null,
  team: { key: 'WEB', name: 'Web' },
  createdAt: '2026-09-01T09:00:00.000Z',
  updatedAt: '2026-09-02T09:00:00.000Z',
  completedAt: '2026-09-02T09:00:00.000Z',
  canceledAt: null,
  comments: { nodes: [], pageInfo: { hasPreviousPage: false } },
}

export const PROJECT = {
  name: 'Brand refresh',
  url: 'https://linear.app/acme/project/brand-refresh-1a2b3c4d5e6f',
  description: 'Short summary',
  content: '# Brand refresh\n\nThe long description.',
  status: { name: 'In Progress', type: 'started' },
  lead: { name: 'Ada Lovelace' },
  startDate: '2026-09-01',
  targetDate: '2026-12-01',
  progress: 0.426,
  teams: { nodes: [{ key: 'WEB', name: 'Web' }] },
}

export function openIssue(n: number) {
  return {
    identifier: `WEB-${n}`,
    title: `Open issue ${n}`,
    url: `https://linear.app/acme/issue/WEB-${n}/open-issue-${n}`,
    state: { name: 'Todo', type: 'unstarted' },
    assignee: n % 2 ? { name: 'Ada Lovelace' } : null,
  }
}
