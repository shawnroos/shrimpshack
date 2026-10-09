import type { Captured } from './capture'
import { parseRef } from './refs'
import type { Ref } from './refs'
import { linearPaged, linearQuery } from './sources'
import type { Connection, Failed, SourceIo } from './sources'
import type { Loaded, RemoteComment, RemoteListItem, RemoteRecord } from '../types'

const SHOWN_COMMENTS = 50
const FROZEN_TYPES = new Set(['completed', 'canceled'])

const ISSUE_QUERY = `query($id: String!) { issue(id: $id) {
  identifier title description url priority priorityLabel
  state { name type } assignee { name } labels(first: 50) { nodes { name } }
  parent { identifier title } project { name url } projectMilestone { name } team { key name }
  createdAt updatedAt completedAt canceledAt
  comments(last: 50) { nodes { id body createdAt user { name } parent { id } } pageInfo { hasPreviousPage } }
} }`

const COMMENT_COUNT_QUERY = `query($id: String!, $first: Int, $after: String) { issue(id: $id) {
  comments(first: $first, after: $after) { nodes { id } pageInfo { hasNextPage endCursor } }
} }`

const PROJECT_QUERY = `query($id: String!) { project(id: $id) {
  name url description content status { name type } lead { name } startDate targetDate progress
  teams(first: 5) { nodes { key name } }
} }`

const PROJECT_ISSUES_QUERY = `query($id: String!, $first: Int, $after: String) { project(id: $id) {
  issues(first: $first, after: $after, filter: { state: { type: { nin: ["completed", "canceled"] } } }) {
    nodes { identifier title url state { name type } assignee { name } }
    pageInfo { hasNextPage endCursor }
  }
} }`

const VIEWER_QUERY = 'query { viewer { organization { urlKey } } }'
const TEAMS_QUERY = 'query($first: Int, $after: String) { teams(first: $first, after: $after) { nodes { key } pageInfo { hasNextPage endCursor } } }'

type Obj = Record<string, unknown>

export type LinearBootstrap = { ok: true; workspace: string; teamKeys: string[]; fetchedAt: number }

function obj(value: unknown): Obj | null {
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as Obj) : null
}

function str(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() ? value.trim() : undefined
}

function named(value: unknown): string | undefined {
  const found = obj(value)
  return found ? str(found.name) ?? str(found.displayName) : str(value)
}

function nodes(value: unknown): unknown[] {
  if (Array.isArray(value)) return value
  const found = obj(value)?.nodes
  return Array.isArray(found) ? found : []
}

function day(value: unknown): string | undefined {
  const text = str(value)
  return text ? text.slice(0, 10) : undefined
}

function priority(issue: Obj): string | undefined {
  const raw = issue.priority
  const value = typeof raw === 'number' ? raw : typeof obj(raw)?.value === 'number' ? (obj(raw)?.value as number) : undefined
  if (value === 0) return undefined
  const label = str(issue.priorityLabel) ?? named(raw)
  if (label && /^no priority$/i.test(label)) return undefined
  return label
}

function stateOf(item: Obj): { name?: string; type?: string } {
  const state = obj(item.state)
  const status = obj(item.status)
  return {
    name: named(item.state) ?? named(item.status),
    type: str(state?.type) ?? str(status?.type) ?? str(item.statusType) ?? str(item.stateType),
  }
}

function team(item: Obj): string | undefined {
  const found = obj(item.team)
  return found ? str(found.name) ?? str(found.key) : str(item.team)
}

function push(meta: RemoteRecord['meta'], label: string, value: string | undefined) {
  if (value) meta.push({ label, value })
}

function threaded(raw: unknown[]): RemoteComment[] {
  type Note = { id?: string; parent?: string; at: string; comment: RemoteComment }
  const notes: Note[] = []
  for (const entry of raw) {
    const item = obj(entry)
    const body = str(item?.body)
    if (!item || !body) continue
    const at = str(item.createdAt) ?? ''
    const author = named(item.user) ?? named(item.author) ?? 'Unknown'
    notes.push({ id: str(item.id), parent: str(obj(item.parent)?.id) ?? str(item.parentId), at, comment: { author, at, body } })
  }
  const kept = notes.sort((a, b) => a.at.localeCompare(b.at)).slice(-SHOWN_COMMENTS)
  const ids = new Set(kept.map(note => note.id).filter(Boolean))
  const replies = new Map<string, Note[]>()
  for (const note of kept) {
    if (note.parent && ids.has(note.parent)) replies.set(note.parent, [...(replies.get(note.parent) ?? []), note])
  }
  const shown: RemoteComment[] = []
  for (const note of kept) {
    if (note.parent && ids.has(note.parent)) continue
    shown.push(note.comment)
    for (const reply of (note.id && replies.get(note.id)) || []) shown.push({ ...reply.comment, depth: 1 })
  }
  return shown
}

function workspaceOf(url: string | undefined): string | undefined {
  return url ? parseRef(url)?.workspace : undefined
}

function issueRecord(issue: Obj, ref: Ref, commentTotal?: number): RemoteRecord | null {
  const title = str(issue.title)
  if (!title) return null
  const idField = str(issue.id)
  const identifier = str(issue.identifier) ?? (idField && /^[A-Z][A-Z0-9]*-\d+$/i.test(idField) ? idField.toUpperCase() : undefined) ?? ref.key
  const state = stateOf(issue)
  const project = named(issue.project)
  const trail = [team(issue), project].filter((piece): piece is string => Boolean(piece))
  const parent = obj(issue.parent)
  const parentText = parent
    ? [str(parent.identifier), str(parent.title)].filter(Boolean).join(' ') || undefined
    : str(issue.parentId)
  const labels = nodes(issue.labels).map(named).filter((label): label is string => Boolean(label))
  const meta: RemoteRecord['meta'] = []
  push(meta, 'State', state.name)
  push(meta, 'Assignee', named(issue.assignee) ?? 'Unassigned')
  push(meta, 'Labels', labels.length ? labels.join(', ') : undefined)
  push(meta, 'Priority', priority(issue))
  push(meta, 'Project', project)
  push(meta, 'Milestone', named(issue.projectMilestone))
  push(meta, 'Parent', parentText)
  push(meta, 'Created', day(issue.createdAt))
  push(meta, 'Updated', day(issue.updatedAt))
  push(meta, 'Completed', day(issue.completedAt))
  push(meta, 'Canceled', day(issue.canceledAt))
  const rawComments = issue.comments === undefined || issue.comments === null ? null : nodes(issue.comments)
  const shown = rawComments ? threaded(rawComments) : null
  return {
    address: ref.address,
    kind: 'linear-issue',
    title: identifier ? `${identifier} ${title}` : title,
    trail,
    status: state.name,
    isFrozen: state.type ? FROZEN_TYPES.has(state.type.toLowerCase()) : false,
    meta,
    body: str(issue.description),
    comments: shown ? { shown, total: Math.max(commentTotal ?? 0, rawComments?.length ?? 0) } : undefined,
    browserUrl: str(issue.url) ?? ref.address,
  }
}

function percent(value: unknown): string | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? `${Math.round(value * 100)}%` : undefined
}

function projectRecord(project: Obj, ref: Ref, issues?: { nodes: unknown[]; isPartial: boolean }): RemoteRecord | null {
  const title = str(project.name)
  if (!title) return null
  const state = stateOf(project)
  const firstTeam = obj(nodes(project.teams)[0]) ?? obj(project.leadTeam)
  const teamName = firstTeam ? str(firstTeam.name) ?? str(firstTeam.key) : undefined
  const meta: RemoteRecord['meta'] = []
  push(meta, 'Status', state.name)
  push(meta, 'Lead', named(project.lead))
  push(meta, 'Start', day(project.startDate))
  push(meta, 'Target', day(project.targetDate))
  push(meta, 'Progress', percent(project.progress))
  const record: RemoteRecord = {
    address: ref.address,
    kind: 'linear-project',
    title,
    trail: teamName ? [teamName] : [],
    status: state.name,
    isFrozen: state.type ? FROZEN_TYPES.has(state.type.toLowerCase()) : false,
    meta,
    body: str(project.content) ?? str(project.description),
    browserUrl: str(project.url) ?? ref.address,
  }
  if (issues) {
    const items = issues.nodes.map(node => issueItem(node, ref)).filter((item): item is RemoteListItem => item !== null)
    record.lists = [{ heading: 'Issues', items, total: items.length, isPartial: issues.isPartial }]
  }
  return record
}

function issueItem(node: unknown, ref: Ref): RemoteListItem | null {
  const issue = obj(node)
  const identifier = str(issue?.identifier)
  if (!issue || !identifier) return null
  const workspace = ref.workspace ?? workspaceOf(str(issue.url))
  const href = workspace ? `https://linear.app/${workspace}/issue/${identifier}` : str(issue.url)
  if (!href) return null
  const item: RemoteListItem = { href, title: [identifier, str(issue.title)].filter(Boolean).join(' ') }
  const status = stateOf(issue).name
  if (status) item.status = status
  const assignee = named(issue.assignee)
  if (assignee) item.meta = assignee
  return item
}

function projectId(ref: Ref): string {
  const slug = ref.slug ?? ref.address.split('/').pop() ?? ''
  const tail = slug.split('-').pop() ?? ''
  return /^[0-9a-f]{8,}$/i.test(tail) ? tail : slug
}

async function countComments(io: SourceIo, id: string): Promise<number | undefined> {
  const counted = await linearPaged(io, COMMENT_COUNT_QUERY, { id }, data => obj(obj(obj(data)?.issue)?.comments) as Connection | null)
  return counted.ok ? counted.nodes.length : undefined
}

async function loadIssue(io: SourceIo, ref: Ref, now: number): Promise<Loaded> {
  if (!ref.key) return { ok: false, failure: 'query-bug' }
  const answered = await linearQuery(io, ISSUE_QUERY, { id: ref.key })
  if (!answered.ok) return answered
  const issue = obj(obj(answered.data)?.issue)
  if (!issue) return { ok: false, failure: 'not-found-or-no-access' }
  const found = workspaceOf(str(issue.url))
  if (ref.workspace && found && found !== ref.workspace) return { ok: false, failure: 'not-found-or-no-access' }
  const hasOlder = obj(obj(issue.comments)?.pageInfo)?.hasPreviousPage === true
  const total = hasOlder ? await countComments(io, ref.key) : undefined
  const record = issueRecord(issue, ref, total)
  return record ? { ok: true, record, tier: 'api', fetchedAt: now } : { ok: false, failure: 'query-bug' }
}

async function loadProject(io: SourceIo, ref: Ref, now: number): Promise<Loaded> {
  const id = projectId(ref)
  if (!id) return { ok: false, failure: 'query-bug' }
  const answered = await linearQuery(io, PROJECT_QUERY, { id })
  if (!answered.ok) return answered
  const project = obj(obj(answered.data)?.project)
  if (!project) return { ok: false, failure: 'not-found-or-no-access' }
  const found = workspaceOf(str(project.url))
  if (ref.workspace && found && found !== ref.workspace) return { ok: false, failure: 'not-found-or-no-access' }
  const issues = await linearPaged(io, PROJECT_ISSUES_QUERY, { id }, data => obj(obj(obj(data)?.project)?.issues) as Connection | null)
  if (!issues.ok) return issues
  const record = projectRecord(project, ref, issues)
  return record ? { ok: true, record, tier: 'api', fetchedAt: now } : { ok: false, failure: 'query-bug' }
}

export async function loadLinear(io: SourceIo, ref: Ref, now: number): Promise<Loaded> {
  if (ref.kind === 'linear-issue') return loadIssue(io, ref, now)
  if (ref.kind === 'linear-project') return loadProject(io, ref, now)
  return { ok: false, failure: 'query-bug' }
}

export async function bootstrapLinear(io: SourceIo, now: number): Promise<LinearBootstrap | Failed> {
  const viewer = await linearQuery(io, VIEWER_QUERY)
  if (!viewer.ok) return viewer
  const workspace = str(obj(obj(obj(viewer.data)?.viewer)?.organization)?.urlKey)
  if (!workspace) return { ok: false, failure: 'query-bug' }
  const teams = await linearPaged(io, TEAMS_QUERY, {}, data => obj(obj(data)?.teams) as Connection | null)
  if (!teams.ok) return teams
  const teamKeys = [...new Set(teams.nodes.map(node => str(obj(node)?.key)).filter((key): key is string => Boolean(key)))]
  return { ok: true, workspace, teamKeys, fetchedAt: now }
}

export function fromCapture(captured: Captured, ref: Ref, _now: number): Loaded | null {
  let parsed: unknown
  try {
    parsed = JSON.parse(captured.result)
  } catch {
    return null
  }
  const item = obj(parsed)
  if (!item) return null
  const kind = captured.kind === 'linear-project' || ref.kind === 'linear-project' ? 'linear-project' : 'linear-issue'
  const issues = kind === 'linear-project' && item.issues !== undefined ? { nodes: nodes(item.issues), isPartial: false } : undefined
  const record = kind === 'linear-project' ? projectRecord(item, ref, issues) : issueRecord(item, ref)
  return record ? { ok: true, record, tier: 'session', fetchedAt: captured.at } : null
}
