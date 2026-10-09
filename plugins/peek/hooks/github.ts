import type { Captured } from './capture'
import type { Ref } from './refs'
import { runGh } from './sources'
import type { Failed, SourceIo } from './sources'
import type { Loaded, RemoteComment, RemoteKind, RemoteList, RemoteListItem, RemoteRecord, Tier } from '../types'

const COMMENTS_SHOWN = 50
const LIST_LIMIT = '30'
const PR_FIELDS =
  'number,title,state,isDraft,author,assignees,labels,milestone,createdAt,updatedAt,mergedAt,closedAt,body,additions,deletions,changedFiles,reviewDecision,mergeable,mergeStateStatus,statusCheckRollup,comments,reviews,headRefName,baseRefName,url'
const ISSUE_FIELDS = 'number,title,state,stateReason,author,assignees,labels,milestone,createdAt,updatedAt,closedAt,body,comments,url'
const REPO_FIELDS = 'nameWithOwner,description,defaultBranchRef,primaryLanguage,stargazerCount,updatedAt,url,issues,pullRequests'
const BUCKETS = ['passed', 'failed', 'pending', 'cancelled', 'skipped'] as const

type Bucket = (typeof BUCKETS)[number]
type Json = Record<string, unknown>
type ItemRef = Ref & { kind: 'gh-pr' | 'gh-issue'; owner: string; repo: string; number: number }

const resolved = new Map<string, boolean>()

function obj(value: unknown): Json {
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as Json) : {}
}

function arr(value: unknown): unknown[] {
  return Array.isArray(value) ? value : []
}

function str(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

function num(value: unknown): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : 0
}

function parse(text: string): unknown {
  try {
    return JSON.parse(text)
  } catch {
    return undefined
  }
}

function pick(source: Json, ...keys: string[]): unknown {
  for (const key of keys) if (source[key] !== undefined && source[key] !== null) return source[key]
  return undefined
}

function login(value: unknown): string {
  const person = obj(value)
  return str(person.login) || str(person.name)
}

function day(value: unknown): string {
  return str(value).slice(0, 10)
}

function itemRef(owner: string, repo: string, number: number, isPull: boolean): ItemRef {
  return {
    kind: isPull ? 'gh-pr' : 'gh-issue',
    address: `https://github.com/${owner}/${repo}/${isPull ? 'pull' : 'issues'}/${number}`,
    owner,
    repo,
    number,
  }
}

export async function resolveNumber(io: SourceIo, ref: Ref): Promise<{ ok: true; ref: ItemRef } | Failed> {
  const { owner, repo, number } = ref
  if (!owner || !repo || !number) return { ok: false, failure: 'query-bug' }
  if (ref.kind === 'gh-pr') return { ok: true, ref: itemRef(owner, repo, number, true) }
  const key = `${await io.sessionId()}\n${owner}/${repo}#${number}`
  const known = resolved.get(key)
  if (known !== undefined) return { ok: true, ref: itemRef(owner, repo, number, known) }
  // `gh issue view` answers for a PR number too, so only the issues API's pull_request key tells them apart.
  const ran = await runGh(io, ['api', `repos/${owner}/${repo}/issues/${number}`])
  if (!ran.ok) return ran
  const answer = parse(ran.stdout)
  if (!answer || typeof answer !== 'object') return { ok: false, failure: 'query-bug' }
  const isPull = obj(answer).pull_request !== undefined && obj(answer).pull_request !== null
  resolved.set(key, isPull)
  return { ok: true, ref: itemRef(owner, repo, number, isPull) }
}

function bucketOf(check: Json): Bucket {
  const state = str(check.state).toUpperCase()
  const status = str(check.status).toUpperCase()
  const isStatusContext = check.__typename === 'StatusContext' || (state !== '' && status === '')
  if (!isStatusContext && status !== 'COMPLETED') return 'pending'
  const outcome = isStatusContext ? state : str(check.conclusion).toUpperCase()
  switch (outcome) {
    case 'SUCCESS':
      return 'passed'
    case 'FAILURE':
    case 'TIMED_OUT':
    case 'ACTION_REQUIRED':
    case 'STARTUP_FAILURE':
    case 'ERROR':
      return 'failed'
    case 'CANCELLED':
      return 'cancelled'
    case 'NEUTRAL':
    case 'SKIPPED':
    case 'STALE':
      return 'skipped'
    default:
      return 'pending'
  }
}

export function ciSummary(rollup: unknown, mergeable: unknown, state: unknown): string {
  const checks = arr(rollup)
  if (checks.length === 0) {
    if (str(state).toUpperCase() === 'OPEN') {
      const merge = str(mergeable).toUpperCase()
      if (merge === 'CONFLICTING') return 'checks not running: merge conflict'
      if (merge === 'UNKNOWN') return 'computing'
    }
    return 'no checks reported'
  }
  const counts: Record<Bucket, number> = { passed: 0, failed: 0, pending: 0, cancelled: 0, skipped: 0 }
  for (const check of checks) counts[bucketOf(obj(check))]++
  return BUCKETS.filter(bucket => counts[bucket] > 0)
    .map(bucket => `${counts[bucket]} ${bucket}`)
    .join(' · ')
}

function names(value: unknown, key: 'name' | 'login'): string {
  return arr(value)
    .map(entry => (typeof entry === 'string' ? entry : str(obj(entry)[key])))
    .filter(Boolean)
    .join(', ')
}

function words(value: unknown): string {
  const text = str(value).toLowerCase().replace(/_/g, ' ')
  return text ? text[0]?.toUpperCase() + text.slice(1) : ''
}

function addMeta(meta: RemoteRecord['meta'], label: string, value: string): void {
  if (value) meta.push({ label, value })
}

function comment(raw: unknown, isReview: boolean): RemoteComment & { time: string } {
  const entry = obj(raw)
  const at = str(pick(entry, 'submittedAt', 'createdAt', 'submitted_at', 'created_at'))
  const shaped: RemoteComment & { time: string } = { author: login(pick(entry, 'author', 'user')) || 'ghost', at, body: str(entry.body), time: at }
  if (isReview) shaped.isReview = true
  return shaped
}

function conversation(comments: unknown, reviews: unknown, inline?: number): RemoteRecord['comments'] {
  const all = [
    ...arr(comments).map(raw => comment(raw, false)),
    ...arr(reviews)
      .filter(raw => str(obj(raw).body).trim() !== '')
      .map(raw => comment(raw, true)),
  ].sort((a, b) => (a.time < b.time ? -1 : a.time > b.time ? 1 : 0))
  if (all.length === 0 && inline === undefined) return undefined
  const shown = all.slice(-COMMENTS_SHOWN).map(({ time: _time, ...rest }) => rest)
  const out: NonNullable<RemoteRecord['comments']> = { shown, total: all.length }
  if (inline !== undefined) out.inline = inline
  return out
}

type ItemShape = {
  view: Json
  ref: ItemRef
  inline?: number
}

function prState(view: Json): 'open' | 'draft' | 'merged' | 'closed' {
  const state = str(view.state).toUpperCase()
  if (state === 'MERGED' || pick(view, 'mergedAt', 'merged_at') !== undefined || view.merged === true) return 'merged'
  if (state === 'CLOSED') return 'closed'
  return view.isDraft === true || view.draft === true ? 'draft' : 'open'
}

function pullRecord({ view, ref, inline }: ItemShape): RemoteRecord | null {
  const title = str(view.title)
  if (!title) return null
  const status = prState(view)
  const meta: RemoteRecord['meta'] = []
  addMeta(meta, 'State', words(status))
  addMeta(meta, 'Author', login(pick(view, 'author', 'user')))
  const head = str(view.headRefName) || str(obj(view.head).ref)
  const base = str(view.baseRefName) || str(obj(view.base).ref)
  if (head && base) addMeta(meta, 'Branch', `${head} → ${base}`)
  addMeta(meta, 'Review', words(view.reviewDecision))
  if (status === 'open' || status === 'draft') addMeta(meta, 'Merge state', words(pick(view, 'mergeStateStatus', 'mergeable_state')))
  addMeta(meta, 'Assignees', names(view.assignees, 'login'))
  addMeta(meta, 'Labels', names(view.labels, 'name'))
  addMeta(meta, 'Milestone', str(obj(view.milestone).title))
  addMeta(meta, 'Created', day(pick(view, 'createdAt', 'created_at')))
  addMeta(meta, 'Updated', day(pick(view, 'updatedAt', 'updated_at')))
  if (status === 'merged') addMeta(meta, 'Merged', day(pick(view, 'mergedAt', 'merged_at')))
  if (status === 'closed') addMeta(meta, 'Closed', day(pick(view, 'closedAt', 'closed_at')))
  const rollupState = status === 'merged' ? 'MERGED' : status === 'closed' ? 'CLOSED' : 'OPEN'
  const record: RemoteRecord = {
    address: ref.address,
    kind: 'gh-pr',
    title: `#${ref.number} ${title}`,
    trail: [ref.owner, ref.repo],
    status,
    isFrozen: status === 'merged' || status === 'closed',
    meta,
    browserUrl: ref.address,
  }
  if (typeof view.additions === 'number') {
    record.stats = {
      additions: num(view.additions),
      deletions: num(view.deletions),
      changedFiles: num(pick(view, 'changedFiles', 'changed_files')),
      ci: ciSummary(view.statusCheckRollup, view.mergeable, rollupState),
    }
  }
  const body = str(view.body)
  if (body) record.body = body
  const comments = conversation(view.comments, view.reviews, inline)
  if (comments) record.comments = comments
  return record
}

function issueRecord({ view, ref }: ItemShape): RemoteRecord | null {
  const title = str(view.title)
  if (!title) return null
  const isClosed = str(view.state).toUpperCase() === 'CLOSED'
  const reason = words(pick(view, 'stateReason', 'state_reason'))
  const meta: RemoteRecord['meta'] = []
  addMeta(meta, 'State', isClosed ? (reason ? `Closed (${reason.toLowerCase()})` : 'Closed') : 'Open')
  addMeta(meta, 'Author', login(pick(view, 'author', 'user')))
  addMeta(meta, 'Assignees', names(view.assignees, 'login'))
  addMeta(meta, 'Labels', names(view.labels, 'name'))
  addMeta(meta, 'Milestone', str(obj(view.milestone).title))
  addMeta(meta, 'Created', day(pick(view, 'createdAt', 'created_at')))
  addMeta(meta, 'Updated', day(pick(view, 'updatedAt', 'updated_at')))
  if (isClosed) addMeta(meta, 'Closed', day(pick(view, 'closedAt', 'closed_at')))
  const record: RemoteRecord = {
    address: ref.address,
    kind: 'gh-issue',
    title: `#${ref.number} ${title}`,
    trail: [ref.owner, ref.repo],
    status: isClosed ? 'closed' : 'open',
    isFrozen: isClosed,
    meta,
    browserUrl: ref.address,
  }
  const body = str(view.body)
  if (body) record.body = body
  const comments = conversation(view.comments, [])
  if (comments) record.comments = comments
  return record
}

function listItems(raw: unknown, owner: string, repo: string, isPull: boolean): RemoteListItem[] {
  return arr(raw)
    .map(obj)
    .filter(entry => num(entry.number) > 0)
    .sort((a, b) => (str(a.updatedAt) < str(b.updatedAt) ? 1 : str(a.updatedAt) > str(b.updatedAt) ? -1 : 0))
    .map(entry => {
      const item: RemoteListItem = {
        href: itemRef(owner, repo, num(entry.number), isPull).address,
        title: `#${num(entry.number)} ${str(entry.title)}`,
      }
      const meta = [login(entry.author), day(entry.updatedAt)].filter(Boolean).join(' · ')
      if (meta) item.meta = meta
      if (isPull) item.status = entry.isDraft === true ? 'draft' : 'open'
      return item
    })
}

function repoRecord(view: Json, owner: string, repo: string, readme?: string, lists: RemoteList[] = []): RemoteRecord | null {
  const fullName = str(pick(view, 'nameWithOwner', 'full_name'))
  if (!fullName && !str(view.name)) return null
  const [ownerName = owner, repoName = repo] = fullName ? fullName.split('/') : [owner, str(view.name)]
  const address = `https://github.com/${ownerName}/${repoName}`
  const meta: RemoteRecord['meta'] = []
  addMeta(meta, 'Description', str(view.description))
  addMeta(meta, 'Default branch', str(obj(view.defaultBranchRef).name) || str(view.default_branch))
  addMeta(meta, 'Language', str(obj(view.primaryLanguage).name) || str(view.language))
  const stars = pick(view, 'stargazerCount', 'stargazers_count')
  if (typeof stars === 'number') addMeta(meta, 'Stars', String(stars))
  addMeta(meta, 'Updated', day(pick(view, 'updatedAt', 'updated_at')))
  const record: RemoteRecord = { address, kind: 'gh-repo', title: repoName, trail: [ownerName], meta, browserUrl: address }
  if (readme) record.body = readme
  if (lists.length > 0) record.lists = lists
  return record
}

function loaded(record: RemoteRecord | null, tier: Tier, now: number): Loaded | null {
  return record ? { ok: true, record, tier, fetchedAt: now } : null
}

async function loadRepo(io: SourceIo, owner: string, repo: string, now: number): Promise<Loaded> {
  const slug = `${owner}/${repo}`
  const [view, readme, pulls, issues] = await Promise.all([
    runGh(io, ['repo', 'view', slug, '--json', REPO_FIELDS]),
    runGh(io, ['api', `repos/${slug}/readme`, '-H', 'Accept: application/vnd.github.raw']),
    runGh(io, ['pr', 'list', '--repo', slug, '--state', 'open', '--limit', LIST_LIMIT, '--search', 'sort:updated-desc', '--json', 'number,title,updatedAt,author,isDraft,url']),
    runGh(io, ['issue', 'list', '--repo', slug, '--state', 'open', '--limit', LIST_LIMIT, '--search', 'sort:updated-desc', '--json', 'number,title,updatedAt,author,url']),
  ])
  if (!view.ok) return view
  const json = obj(parse(view.stdout))
  const lists: RemoteList[] = []
  if (pulls.ok) {
    const items = listItems(parse(pulls.stdout), owner, repo, true)
    lists.push({ heading: 'Pull requests', items, total: Math.max(num(obj(json.pullRequests).totalCount), items.length) })
  }
  if (issues.ok) {
    const items = listItems(parse(issues.stdout), owner, repo, false)
    lists.push({ heading: 'Issues', items, total: Math.max(num(obj(json.issues).totalCount), items.length) })
  }
  const body = readme.ok && readme.stdout.trim() ? readme.stdout : undefined
  return loaded(repoRecord(json, owner, repo, body, lists), 'cli', now) ?? { ok: false, failure: 'query-bug' }
}

async function loadPull(io: SourceIo, ref: ItemRef, now: number): Promise<Loaded> {
  const slug = `${ref.owner}/${ref.repo}`
  const [view, inline] = await Promise.all([
    runGh(io, ['pr', 'view', String(ref.number), '--repo', slug, '--json', PR_FIELDS]),
    runGh(io, ['api', `repos/${slug}/pulls/${ref.number}`, '--jq', '.review_comments']),
  ])
  if (!view.ok) return view
  const count = inline.ok ? Number.parseInt(inline.stdout.trim(), 10) : NaN
  const record = pullRecord({ view: obj(parse(view.stdout)), ref, inline: Number.isFinite(count) ? count : undefined })
  return loaded(record, 'cli', now) ?? { ok: false, failure: 'query-bug' }
}

async function loadIssue(io: SourceIo, ref: ItemRef, now: number): Promise<Loaded> {
  const view = await runGh(io, ['issue', 'view', String(ref.number), '--repo', `${ref.owner}/${ref.repo}`, '--json', ISSUE_FIELDS])
  if (!view.ok) return view
  return loaded(issueRecord({ view: obj(parse(view.stdout)), ref }), 'cli', now) ?? { ok: false, failure: 'query-bug' }
}

export async function loadGithub(io: SourceIo, ref: Ref, now: number): Promise<Loaded> {
  if (ref.kind === 'gh-repo') {
    if (!ref.owner || !ref.repo) return { ok: false, failure: 'query-bug' }
    return loadRepo(io, ref.owner, ref.repo, now)
  }
  if (ref.kind !== 'gh-pr' && ref.kind !== 'gh-issue' && ref.kind !== 'gh-number') return { ok: false, failure: 'query-bug' }
  const settled = await resolveNumber(io, ref)
  if (!settled.ok) return settled
  return settled.ref.kind === 'gh-pr' ? loadPull(io, settled.ref, now) : loadIssue(io, settled.ref, now)
}

const PULL_ONLY = ['pull_request', 'mergedAt', 'merged_at', 'isDraft', 'draft', 'headRefName', 'head', 'additions', 'changedFiles', 'changed_files', 'mergeable', 'statusCheckRollup']

function capturedKind(captured: Captured, ref: Ref, view: Json): RemoteKind | null {
  const kinds = [captured.kind, ref.kind]
  if (kinds.includes('gh-repo')) return 'gh-repo'
  if (kinds.includes('gh-pr')) return 'gh-pr'
  const isPull = PULL_ONLY.some(key => view[key] !== undefined) || str(view.state).toUpperCase() === 'MERGED' || /\/pull\/\d+/.test(str(pick(view, 'html_url', 'url')))
  if (isPull) return 'gh-pr'
  if (kinds.includes('gh-issue') || kinds.includes('gh-number')) return 'gh-issue'
  return null
}

export function fromCapture(captured: Captured, ref: Ref, now: number): Loaded | null {
  const parsed = parse(captured.result)
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return null
  const view = obj(parsed)
  const kind = capturedKind(captured, ref, view)
  const { owner, repo } = ref
  if (!kind || !owner || !repo) return null
  if (kind === 'gh-repo') return loaded(repoRecord(view, owner, repo, undefined), 'session', now)
  const number = ref.number ?? num(view.number)
  if (!number) return null
  const target = itemRef(owner, repo, number, kind === 'gh-pr')
  return loaded(kind === 'gh-pr' ? pullRecord({ view, ref: target }) : issueRecord({ view, ref: target }), 'session', now)
}
