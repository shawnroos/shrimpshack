import type { EngineInterface } from 'claude-code'

import type { Contract, Reread } from './contract'
import { viewedKey } from './selection'

const VIEW_FORMAT = 3
// Older files carry no editor kinds: their rows and work still show, and the contract view waits for the next write.
const ROWS_ONLY_FORMATS = new Set<unknown>([1, 2])
const DEFAULT_DATA_DIR = '/.claude/plugins/data/auto-shrimpshack'
const ROW_CAP = 2000
const STEP_KINDS = new Set<string>(['done', 'current', 'waiting', 'planned'])

export type Step = {
  kind: 'done' | 'current' | 'waiting' | 'planned'
  title: string
  clause: string | null
  clause_label: string
  no_clause: boolean
}

export type Watch = {
  state: 'watcher_live' | 'reporter_only' | 'retry_never_started' | 'nothing_watching'
  interval_seconds?: number | null
  beat_age_seconds?: number | null
  reporter?: string
}

export type WorkItem = {
  id: string
  title: string
  location: string | null
  no_plan: boolean
  steps: Step[]
  finish: string | null
  age_seconds: number | null
  faded: boolean
  change_hash: string | null
  changed: boolean
  watch: Watch | null
}

export type Row = { style: string; text: string }

export type SetupItem = { item: string; title: string; adopted: boolean }

export type SetupStep = {
  key: string
  label: string
  group: string
  state: 'done' | 'current' | 'upcoming'
  values: string
  recommendation: string | null
  recommendation_source: string | null
  needs_typed: boolean
  reply: string | null
  items: SetupItem[]
}

export type Scope = { in: Record<string, string[]>; out: Record<string, string[]>; probed: boolean }

export type Setup = { current: string | null; steps: SetupStep[]; scope: Scope }

export type Decision = { kind: string; question: string; reply: string | null }

export type Found =
  | { kind: 'none' }
  | { kind: 'several'; homes: string[] }
  | { kind: 'missing'; path: string }
  | { kind: 'unreadable'; path: string; why: string }
  | {
      kind: 'view'
      path: string
      rows: Row[]
      generatedAt: string
      work: WorkItem[]
      parts?: { contract: Contract; reread: Reread; spaces: string[] }
      setup?: Setup
      decisions: Decision[]
    }

type Raw = Record<string, unknown>

function isRaw(value: unknown): value is Raw {
  return typeof value === 'object' && value !== null
}

function text(value: unknown): string | null {
  return typeof value === 'string' && value !== '' ? value : null
}

function age(entry: Raw, nowMs: number): { age_seconds: number | null; faded: boolean } {
  const stored = { age_seconds: typeof entry.age_seconds === 'number' ? entry.age_seconds : null, faded: entry.faded === true }
  const at = typeof entry.recorded_at === 'string' ? Date.parse(entry.recorded_at) : Number.NaN
  if (Number.isNaN(at)) return stored
  const seconds = Math.max(0, Math.floor((nowMs - at) / 1000))
  const after = typeof entry.fade_after_seconds === 'number' ? entry.fade_after_seconds : undefined
  return { age_seconds: seconds, faded: after === undefined ? stored.faded : seconds > after }
}

function step(raw: Raw): Step {
  const clause = text(raw.clause)
  return {
    kind: raw.kind as Step['kind'],
    title: String(raw.title ?? ''),
    clause,
    clause_label: String(raw.clause_label ?? 'no clause'),
    no_clause: raw.no_clause === true || clause === null,
  }
}

// The PM writes age at build time; it is measured again here so a PM that stops writing shows as stale.
export function readWork(raw: unknown, nowMs: number): WorkItem[] {
  if (!Array.isArray(raw)) return []
  return raw.filter(isRaw).flatMap(entry => {
    const id = text(entry.id)
    if (id === null) return []
    const changeHash = text(entry.change_hash)
    return [
      {
        id,
        title: String(entry.title ?? ''),
        location: text(entry.location),
        no_plan: entry.no_plan === true,
        steps: (Array.isArray(entry.steps) ? entry.steps : []).filter(isRaw).filter(s => STEP_KINDS.has(String(s.kind))).map(s => step(s)),
        finish: text(entry.finish),
        ...age(entry, nowMs),
        change_hash: changeHash,
        changed: changeHash !== null && entry.changed_since_first === true,
        watch: isRaw(entry.watch) ? (entry.watch as Watch) : null,
      },
    ]
  })
}

function spacesOf(model: unknown): string[] {
  const spaces = isRaw(model) && isRaw(model.remit) ? model.remit.spaces : undefined
  if (!Array.isArray(spaces)) return []
  return spaces
    .filter(isRaw)
    .filter(space => typeof space.server === 'string' && typeof space.workspace === 'string')
    .map(space =>
      typeof space.host === 'string' && space.host !== 'herdr'
        ? `${space.host}--${String(space.server)}--${String(space.workspace)}`
        : `${String(space.server)}.${String(space.workspace)}`,
    )
}

function partsOf(view: Raw): { contract: Contract; reread: Reread; spaces: string[] } | undefined {
  const { work, contract, reread, model } = view
  if (!Array.isArray(work) || !isRaw(contract) || !isRaw(reread)) return
  return {
    spaces: spacesOf(model),
    contract: {
      terms: Array.isArray(contract.terms) ? contract.terms : [],
      instructions: Array.isArray(contract.instructions) ? contract.instructions : [],
    },
    reread: {
      last_at: typeof reread.last_at === 'string' ? reread.last_at : null,
      changed_since: Array.isArray(reread.changed_since) ? reread.changed_since : [],
      requested: reread.requested === true,
    },
  }
}

const SETUP_STATES = new Set<string>(['done', 'current', 'upcoming'])

function shown(value: unknown): string | null {
  if (typeof value === 'string') return text(value)
  if (typeof value === 'number' || typeof value === 'boolean') return String(value)
  if (Array.isArray(value)) return value.map(String).join(', ') || null
  return null
}

function strings(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((entry): entry is string => typeof entry === 'string' && entry !== '') : []
}

function lists(value: unknown): Record<string, string[]> {
  if (!isRaw(value)) return {}
  return Object.fromEntries(Object.entries(value).map(([key, entry]) => [key, strings(entry)]))
}

function setupStep(raw: Raw): SetupStep[] {
  const key = text(raw.key)
  if (key === null) return []
  const items = (Array.isArray(raw.items) ? raw.items : []).filter(isRaw).flatMap(entry => {
    const item = text(entry.item)
    return item === null ? [] : [{ item, title: String(entry.title ?? ''), adopted: entry.adopted === true }]
  })
  return [
    {
      key,
      label: text(raw.label) ?? key.replaceAll('_', ' '),
      group: text(raw.group) ?? key,
      state: SETUP_STATES.has(String(raw.state)) ? (raw.state as SetupStep['state']) : 'upcoming',
      values: shown(raw.values) ?? '',
      recommendation: shown(raw.recommendation),
      recommendation_source: text(raw.recommendation_source),
      needs_typed: raw.needs_typed === true,
      reply: text(raw.reply),
      items,
    },
  ]
}

export function readSetup(raw: unknown): Setup | undefined {
  if (!isRaw(raw)) return undefined
  const scope = isRaw(raw.scope) ? raw.scope : {}
  return {
    current: text(raw.current),
    steps: (Array.isArray(raw.steps) ? raw.steps : []).filter(isRaw).flatMap(entry => setupStep(entry)),
    scope: { in: lists(scope.in), out: lists(scope.out), probed: scope.probed === true },
  }
}

export function readDecisions(model: unknown): Decision[] {
  const raw = isRaw(model) ? model.decisions_for_shawn : undefined
  if (!Array.isArray(raw)) return []
  return raw.filter(isRaw).flatMap(entry => {
    const question = text(entry.question)
    return question === null ? [] : [{ kind: String(entry.kind ?? ''), question, reply: text(entry.reply) }]
  })
}

async function dataDir($: EngineInterface): Promise<string> {
  const override = await $.env.get('CLAUDE_AUTO_DATA_DIR')
  if (override) return override
  return `${(await $.env.get('HOME')) ?? ''}${DEFAULT_DATA_DIR}`
}

export async function leaseHomes($: EngineInterface): Promise<string[]> {
  const sessionId = await $.session.id()
  const folder = `${await dataDir($)}/programmes/leases`
  const entries = await $.fs.list(folder).catch(() => [])
  const homes = new Set<string>()
  for (const entry of entries) {
    if (entry.kind !== 'file' || entry.name.startsWith('.') || !entry.name.endsWith('.json')) continue
    const body = await $.fs.read(`${folder}/${entry.name}`).catch(() => '')
    let lease: { session_id?: unknown; run?: unknown; home?: unknown } = {}
    try {
      lease = JSON.parse(body)
    } catch {
      continue
    }
    const { session_id, run, home } = lease
    if (session_id !== sessionId || typeof run !== 'string' || typeof home !== 'string') continue
    if (home.endsWith(`/programmes/${run}`)) homes.add(home)
  }
  return [...homes].sort()
}

export async function stamp($: EngineInterface): Promise<string> {
  const homes = await leaseHomes($)
  const parts = await Promise.all(
    homes.map(async home => {
      const stat = await $.fs.stat(`${home}/views/view.json`).catch(() => undefined)
      return `${home}:${stat?.mtimeMs ?? 'missing'}`
    }),
  )
  return parts.join('|')
}

async function unviewed($: EngineInterface, work: WorkItem[]): Promise<WorkItem[]> {
  return Promise.all(
    work.map(async item => {
      if (!item.changed) return item
      const viewed = await $.store.get(viewedKey(item.id)).catch(() => undefined)
      return { ...item, changed: viewed !== item.change_hash }
    }),
  )
}

export async function loadView($: EngineInterface): Promise<Found> {
  const homes = await leaseHomes($)
  if (homes.length === 0) return { kind: 'none' }
  if (homes.length > 1) return { kind: 'several', homes }
  const path = `${homes[0]}/views/view.json`
  const body = await $.fs.read(path).catch(() => undefined)
  if (body === undefined) return { kind: 'missing', path }
  let view: unknown
  try {
    view = JSON.parse(body)
  } catch (error) {
    return { kind: 'unreadable', path, why: String(error) }
  }
  const known = isRaw(view) && (view.view_format === VIEW_FORMAT || ROWS_ONLY_FORMATS.has(view.view_format))
  if (!isRaw(view) || !known || !Array.isArray(view.rows)) {
    const format = isRaw(view) ? view.view_format : undefined
    return { kind: 'unreadable', path, why: `view format ${String(format)}, expected ${VIEW_FORMAT}` }
  }
  const rows: Row[] = view.rows.map((row: unknown) => {
    const one = isRaw(row) ? row : {}
    return { style: String(one.style ?? 'text'), text: String(one.text ?? '').slice(0, ROW_CAP) }
  })
  const work = await unviewed($, readWork(view.work, await $.clock.now()))
  const current = view.view_format === VIEW_FORMAT
  const parts = current ? partsOf(view) : undefined
  const setup = current ? readSetup(view.setup) : undefined
  const decisions = current ? readDecisions(view.model) : []
  return { kind: 'view', path, rows, generatedAt: String(view.generated_at ?? ''), work, parts, setup, decisions }
}

export async function markViewed($: EngineInterface, item: WorkItem | undefined): Promise<void> {
  if (item?.change_hash) await $.store.set(viewedKey(item.id), item.change_hash)
}
