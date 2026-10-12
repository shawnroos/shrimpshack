type Check = Record<string, unknown>

function checkRun(status: string, conclusion: string | null, i: number): Check {
  return { __typename: 'CheckRun', name: `job-${i}`, status, conclusion, workflowName: 'CI' }
}

export function checks(spec: { passed?: number; failed?: number; running?: number; cancelled?: number }): Check[] {
  const out: Check[] = []
  for (let i = 0; i < (spec.passed ?? 0); i++) out.push(checkRun('COMPLETED', 'SUCCESS', out.length))
  for (let i = 0; i < (spec.failed ?? 0); i++) out.push(checkRun('COMPLETED', 'FAILURE', out.length))
  for (let i = 0; i < (spec.running ?? 0); i++) out.push(checkRun('IN_PROGRESS', null, out.length))
  for (let i = 0; i < (spec.cancelled ?? 0); i++) out.push(checkRun('COMPLETED', 'CANCELLED', out.length))
  return out
}

export function conversation(count: number): Record<string, unknown>[] {
  return Array.from({ length: count }, (_, i) => ({
    author: { login: `user${i + 1}` },
    body: `comment ${i + 1}`,
    createdAt: new Date(Date.UTC(2026, 0, 1, 0, i)).toISOString(),
  }))
}

export function pullView(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    number: 42,
    title: 'Teach the parser trailing commas',
    state: 'OPEN',
    isDraft: false,
    author: { login: 'octo' },
    assignees: [{ login: 'hubot' }],
    labels: [{ name: 'bug' }, { name: 'parser' }],
    milestone: { title: 'v2.0' },
    createdAt: '2026-09-01T10:00:00Z',
    updatedAt: '2026-09-03T12:00:00Z',
    mergedAt: null,
    closedAt: null,
    body: 'Fixes the trailing comma.',
    additions: 120,
    deletions: 8,
    changedFiles: 4,
    reviewDecision: 'REVIEW_REQUIRED',
    mergeable: 'MERGEABLE',
    mergeStateStatus: 'BLOCKED',
    statusCheckRollup: checks({ passed: 3 }),
    comments: [
      { author: { login: 'a' }, body: 'first', createdAt: '2026-09-01T11:00:00Z' },
      { author: { login: 'c' }, body: 'third', createdAt: '2026-09-02T11:00:00Z' },
    ],
    reviews: [
      { author: { login: 'b' }, body: 'looks fine', state: 'COMMENTED', submittedAt: '2026-09-01T12:00:00Z' },
      { author: { login: 'd' }, body: '', state: 'APPROVED', submittedAt: '2026-09-02T12:00:00Z' },
    ],
    headRefName: 'fix/commas',
    baseRefName: 'main',
    url: 'https://github.com/acme/widgets/pull/42',
    ...overrides,
  }
}

export function issueView(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    number: 7,
    title: 'Parser drops trailing comma',
    state: 'OPEN',
    stateReason: '',
    author: { login: 'reporter' },
    assignees: [{ login: 'hubot' }],
    labels: [{ name: 'bug' }],
    milestone: { title: 'v2.0' },
    createdAt: '2026-08-01T10:00:00Z',
    updatedAt: '2026-08-05T10:00:00Z',
    closedAt: null,
    body: 'Steps to reproduce.',
    comments: conversation(3),
    url: 'https://github.com/acme/widgets/issues/7',
    ...overrides,
  }
}

export const issuesApiPull = {
  number: 42,
  title: 'Teach the parser trailing commas',
  pull_request: { url: 'https://api.github.com/repos/acme/widgets/pulls/42', merged_at: null },
}

export const issuesApiIssue = { number: 7, title: 'Parser drops trailing comma' }

export const repoView = {
  nameWithOwner: 'acme/widgets',
  description: 'Widgets for everyone',
  defaultBranchRef: { name: 'main' },
  primaryLanguage: { name: 'TypeScript' },
  stargazerCount: 1234,
  updatedAt: '2026-09-30T00:00:00Z',
  url: 'https://github.com/acme/widgets',
  issues: { totalCount: 57 },
  pullRequests: { totalCount: 41 },
}

export const pullList = [
  { number: 40, title: 'Older PR', updatedAt: '2026-09-01T00:00:00Z', author: { login: 'x' }, isDraft: false, url: 'https://github.com/acme/widgets/pull/40' },
  { number: 41, title: 'Newer draft PR', updatedAt: '2026-09-05T00:00:00Z', author: { login: 'y' }, isDraft: true, url: 'https://github.com/acme/widgets/pull/41' },
]

export const issueList = [
  { number: 7, title: 'Parser drops trailing comma', updatedAt: '2026-08-05T10:00:00Z', author: { login: 'reporter' }, url: 'https://github.com/acme/widgets/issues/7' },
]

export const mcpPullRead = {
  number: 42,
  title: 'Teach the parser trailing commas',
  state: 'open',
  draft: false,
  user: { login: 'octo' },
  body: 'Fixes the trailing comma.',
  created_at: '2026-09-01T10:00:00Z',
  updated_at: '2026-09-03T12:00:00Z',
  merged_at: null,
  additions: 120,
  deletions: 8,
  changed_files: 4,
  html_url: 'https://github.com/acme/widgets/pull/42',
}
