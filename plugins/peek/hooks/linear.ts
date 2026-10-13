import type { Captured } from './capture'
import { parseRef } from './refs'
import type { LinearIssueRef, LinearProjectRef, Ref } from './refs'
import { linearPaged, linearQuery } from './sources'
import { ok } from './sources/result'
import type { Connection, Failed, SourceIo } from './sources'
import { asDay, asObj, asStr, tryJson } from './wire'
import type { Json } from './wire'
import type { Loaded, RemoteComment, RemoteList, RemoteListItem, RemoteRecord } from '../types'

const SHOWN_COMMENTS = 50
const FROZEN_TYPES = new Set(['completed', 'canceled'])

const ISSUE_QUERY = `query($id: String!) { issue(id: $id) {
  identifier title description url priority priorityLabel
  state { name type } assignee { name } labels(first: 50) { nodes { name } }
  parent { identifier title } project { name url } projectMilestone { name } team { key name }
  children(first: 50) { nodes { identifier title url state { name type } assignee { name } } }
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


export type LinearBootstrap = { ok: true; workspace: string; teamKeys: string[]; fetchedAt: number }


function named(value: unknown): string | undefined {
  const found = asObj(value)
  return found ? asStr(found.name) ?? asStr(found.displayName) : asStr(value)
}

function nodes(value: unknown): unknown[] {
  if (Array.isArray(value)) return value
  const found = asObj(value)?.nodes
  return Array.isArray(found) ? found : []
}

function priority(issue: Json): string | undefined {
  const raw = issue.priority
  const value = typeof raw === 'number' ? raw : typeof asObj(raw)?.value === 'number' ? (asObj(raw)?.value as number) : undefined
  if (value === 0) return undefined
  const label = asStr(issue.priorityLabel) ?? named(raw)
  if (label && /^no priority$/i.test(label)) return undefined
  return label
}

function stateOf(item: Json): { name?: string; type?: string } {
  const state = asObj(item.state)
  const status = asObj(item.status)
  return {
    name: named(item.state) ?? named(item.status),
    type: asStr(state?.type) ?? asStr(status?.type) ?? asStr(item.statusType) ?? asStr(item.stateType),
  }
}

function isFrozenState(state: { type?: string }): boolean {
  return state.type ? FROZEN_TYPES.has(state.type.toLowerCase()) : false
}

function team(item: Json): string | undefined {
  const found = asObj(item.team)
  return found ? asStr(found.name) ?? asStr(found.key) : asStr(item.team)
}

function push(meta: RemoteRecord['meta'], label: string, value: string | undefined) {
  if (value) meta.push({ label, value })
}

function threaded(raw: unknown[]): RemoteComment[] {
  type Note = { id?: string; parent?: string; at: string; comment: RemoteComment }
  const notes: Note[] = []
  for (const entry of raw) {
    const item = asObj(entry)
    const body = asStr(item?.body)
    if (!item || !body) continue
    const at = asStr(item.createdAt) ?? ''
    const author = named(item.user) ?? named(item.author) ?? 'Unknown'
    notes.push({ id: asStr(item.id), parent: asStr(asObj(item.parent)?.id) ?? asStr(item.parentId), at, comment: { author, at, body } })
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
  const ref = url ? parseRef(url) : null
  return ref && 'workspace' in ref ? ref.workspace : undefined
}

function issueRecord(issue: Json, ref: LinearIssueRef, commentTotal?: number): RemoteRecord | null {
  const title = asStr(issue.title)
  if (!title) return null
  const idField = asStr(issue.id)
  const identifier = asStr(issue.identifier) ?? (idField && /^[A-Z][A-Z0-9]*-\d+$/i.test(idField) ? idField.toUpperCase() : undefined) ?? ref.key
  const state = stateOf(issue)
  const project = named(issue.project)
  const trail = [team(issue), project].filter((piece): piece is string => Boolean(piece))
  const parent = asObj(issue.parent)
  const parentText = parent
    ? [asStr(parent.identifier), asStr(parent.title)].filter(Boolean).join(' ') || undefined
    : asStr(issue.parentId)
  const labels = nodes(issue.labels).map(named).filter((label): label is string => Boolean(label))
  const meta: RemoteRecord['meta'] = []
  push(meta, 'State', state.name)
  push(meta, 'Assignee', named(issue.assignee) ?? 'Unassigned')
  push(meta, 'Labels', labels.length ? labels.join(', ') : undefined)
  push(meta, 'Priority', priority(issue))
  const projectUrl = asStr(asObj(issue.project)?.url)
  const projectHref = projectUrl ? parseRef(projectUrl)?.address : undefined
  if (!projectHref) push(meta, 'Project', project)
  push(meta, 'Milestone', named(issue.projectMilestone))
  push(meta, 'Parent', parentText)
  push(meta, 'Created', asDay(issue.createdAt))
  push(meta, 'Updated', asDay(issue.updatedAt))
  push(meta, 'Completed', asDay(issue.completedAt))
  push(meta, 'Canceled', asDay(issue.canceledAt))
  const rawComments = issue.comments === undefined || issue.comments === null ? null : nodes(issue.comments)
  const shown = rawComments ? threaded(rawComments) : null
  const lists: RemoteList[] = []
  if (project && projectHref) lists.push({ heading: 'Project', items: [{ href: projectHref, title: project }], total: 1 })
  const children = nodes(issue.children)
    .map(node => issueItem(node, ref))
    .filter((item): item is RemoteListItem => item !== null)
  if (children.length) lists.push({ heading: 'Sub-issues', items: children, total: children.length })
  return {
    ...(lists.length ? { lists } : {}),
    address: ref.address,
    kind: 'linear-issue',
    title: identifier ? `${identifier} ${title}` : title,
    trail,
    status: state.name,
    isFrozen: isFrozenState(state),
    meta,
    body: asStr(issue.description),
    comments: shown ? { shown, total: Math.max(commentTotal ?? 0, rawComments?.length ?? 0) } : undefined,
    browserUrl: asStr(issue.url) ?? ref.address,
  }
}

function percent(value: unknown): string | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? `${Math.round(value * 100)}%` : undefined
}

function projectRecord(project: Json, ref: LinearIssueRef | LinearProjectRef, issues?: { nodes: unknown[]; isPartial: boolean }): RemoteRecord | null {
  const title = asStr(project.name)
  if (!title) return null
  const state = stateOf(project)
  const firstTeam = asObj(nodes(project.teams)[0]) ?? asObj(project.leadTeam)
  const teamName = firstTeam ? asStr(firstTeam.name) ?? asStr(firstTeam.key) : undefined
  const meta: RemoteRecord['meta'] = []
  push(meta, 'Status', state.name)
  push(meta, 'Lead', named(project.lead))
  push(meta, 'Start', asDay(project.startDate))
  push(meta, 'Target', asDay(project.targetDate))
  push(meta, 'Progress', percent(project.progress))
  const record: RemoteRecord = {
    address: ref.address,
    kind: 'linear-project',
    title,
    trail: teamName ? [teamName] : [],
    status: state.name,
    isFrozen: isFrozenState(state),
    meta,
    body: asStr(project.content) ?? asStr(project.description),
    browserUrl: asStr(project.url) ?? ref.address,
  }
  if (issues) {
    const items = issues.nodes.map(node => issueItem(node, ref)).filter((item): item is RemoteListItem => item !== null)
    record.lists = [{ heading: 'Issues', items, total: items.length, isPartial: issues.isPartial }]
  }
  return record
}

function issueItem(node: unknown, ref: LinearIssueRef | LinearProjectRef): RemoteListItem | null {
  const issue = asObj(node)
  const identifier = asStr(issue?.identifier)
  if (!issue || !identifier) return null
  const workspace = ref.workspace ?? workspaceOf(asStr(issue.url))
  const href = workspace ? `https://linear.app/${workspace}/issue/${identifier}` : asStr(issue.url)
  if (!href) return null
  const item: RemoteListItem = { href, title: [identifier, asStr(issue.title)].filter(Boolean).join(' ') }
  const status = stateOf(issue).name
  if (status) item.status = status
  const assignee = named(issue.assignee)
  if (assignee) item.meta = assignee
  return item
}

function projectId(ref: LinearProjectRef): string {
  const slug = ref.slug
  const tail = slug.split('-').pop() ?? ''
  return /^[0-9a-f]{8,}$/i.test(tail) ? tail : slug
}

async function countComments(io: SourceIo, id: string): Promise<number | undefined> {
  const counted = await linearPaged(io, COMMENT_COUNT_QUERY, { id }, data => asObj(asObj(asObj(data)?.issue)?.comments) as Connection | null)
  return counted.ok ? counted.nodes.length : undefined
}

async function loadIssue(io: SourceIo, ref: LinearIssueRef, now: number): Promise<Loaded> {
  if (!ref.key) return { ok: false, failure: 'query-bug' }
  const answered = await linearQuery(io, ISSUE_QUERY, { id: ref.key })
  if (!answered.ok) return answered
  const issue = asObj(asObj(answered.data)?.issue)
  if (!issue) return { ok: false, failure: 'not-found-or-no-access' }
  const found = workspaceOf(asStr(issue.url))
  if (ref.workspace && found && found !== ref.workspace) return { ok: false, failure: 'not-found-or-no-access' }
  const hasOlder = asObj(asObj(issue.comments)?.pageInfo)?.hasPreviousPage === true
  const total = hasOlder ? await countComments(io, ref.key) : undefined
  const record = issueRecord(issue, ref, total)
  return record ? ok(record, 'api', now) : { ok: false, failure: 'query-bug' }
}

async function loadProject(io: SourceIo, ref: LinearProjectRef, now: number): Promise<Loaded> {
  const id = projectId(ref)
  if (!id) return { ok: false, failure: 'query-bug' }
  const answered = await linearQuery(io, PROJECT_QUERY, { id })
  if (!answered.ok) return answered
  const project = asObj(asObj(answered.data)?.project)
  if (!project) return { ok: false, failure: 'not-found-or-no-access' }
  const found = workspaceOf(asStr(project.url))
  if (ref.workspace && found && found !== ref.workspace) return { ok: false, failure: 'not-found-or-no-access' }
  const issues = await linearPaged(io, PROJECT_ISSUES_QUERY, { id }, data => asObj(asObj(asObj(data)?.project)?.issues) as Connection | null)
  if (!issues.ok) return issues
  const record = projectRecord(project, ref, issues)
  return record ? ok(record, 'api', now) : { ok: false, failure: 'query-bug' }
}

export async function loadLinear(io: SourceIo, ref: Ref, now: number): Promise<Loaded> {
  if (ref.kind === 'linear-issue') return loadIssue(io, ref, now)
  if (ref.kind === 'linear-project') return loadProject(io, ref, now)
  return { ok: false, failure: 'query-bug' }
}

export async function bootstrapLinear(io: SourceIo, now: number): Promise<LinearBootstrap | Failed> {
  const viewer = await linearQuery(io, VIEWER_QUERY)
  if (!viewer.ok) return viewer
  const workspace = asStr(asObj(asObj(asObj(viewer.data)?.viewer)?.organization)?.urlKey)
  if (!workspace) return { ok: false, failure: 'query-bug' }
  const teams = await linearPaged(io, TEAMS_QUERY, {}, data => asObj(asObj(data)?.teams) as Connection | null)
  if (!teams.ok) return teams
  const teamKeys = [...new Set(teams.nodes.map(node => asStr(asObj(node)?.key)).filter((key): key is string => Boolean(key)))]
  return { ok: true, workspace, teamKeys, fetchedAt: now }
}

export function fromCapture(captured: Captured, ref: Ref): Loaded | null {
  const item = asObj(tryJson(captured.result))
  if (!item || (ref.kind !== 'linear-issue' && ref.kind !== 'linear-project')) return null
  const issues = item.issues !== undefined ? { nodes: nodes(item.issues), isPartial: false } : undefined
  const record = captured.kind === 'linear-project' || ref.kind === 'linear-project' ? projectRecord(item, ref, issues) : issueRecord(item, ref)
  return record ? ok(record, 'session', captured.at) : null
}
