import type { FailureKind, Loaded, RemoteKind, RemoteRecord, Tier } from '../types'
import { itemKey, parseRef } from './refs'

export const ON_SCREEN_MS = 60_000
export const BACKGROUND_MS = 5 * 60_000
export const BACKGROUND_CAP = 20
export const IDLE_MS = 10 * 60_000
export const BACKOFF_START_MS = 60_000
export const BACKOFF_MAX_MS = 30 * 60_000
export const TITLE_CAP = 500

export type CacheState = 'loading' | 'fresh' | 'refreshing' | 'stale-since' | 'frozen' | 'failed'

export type CacheEntry = {
  address: string
  record?: RemoteRecord
  tier?: Tier
  fetchedAt?: number
  attemptedAt: number
  state: CacheState
  staleSince?: number
  failure?: FailureKind
  failureDetail?: string
}

export type Source = 'github' | 'linear' | 'web'

export type TitleEntry = { title: string; kind: RemoteKind; status?: string; favicon?: string; trail?: string[]; updatedAt: number }

type Load = (address: string) => Promise<Loaded>

type ScheduleInput = { onScreen?: string; background: readonly string[]; now: number; lastActivity: number }

const entries = new Map<string, CacheEntry>()
const inFlight = new Map<string, Promise<CacheEntry>>()
const backoff = new Map<Source, { waitMs: number; until: number }>()
let backgroundLoads: number[] = []

export function resetRefresh(): void {
  entries.clear()
  inFlight.clear()
  backoff.clear()
  backgroundLoads = []
}

export function cached(address: string): CacheEntry | undefined {
  return entries.get(itemKey(address))
}

export function sourceOf(address: string): Source {
  let host = ''
  try {
    host = new URL(address).hostname.toLowerCase().replace(/^www\./, '')
  } catch {
    return 'web'
  }
  if (host === 'github.com') return 'github'
  if (host === 'linear.app') return 'linear'
  return 'web'
}

export function isTimed(address: string): boolean {
  const kind = parseRef(address)?.kind
  return kind === 'gh-pr' || kind === 'gh-issue' || kind === 'gh-number' || kind === 'linear-issue'
}

export function isCurrent(currentHref: string | undefined, address: string): boolean {
  return currentHref !== undefined && itemKey(currentHref) === itemKey(address)
}

export function freshness(entry: CacheEntry, now: number): CacheState | 'stale' {
  if (entry.state === 'fresh' && entry.fetchedAt !== undefined && now - entry.fetchedAt >= ON_SCREEN_MS) return 'stale'
  return entry.state
}

function extendBackoff(source: Source, now: number): void {
  const waitMs = Math.min((backoff.get(source)?.waitMs ?? BACKOFF_START_MS / 2) * 2, BACKOFF_MAX_MS)
  backoff.set(source, { waitMs, until: now + waitMs })
}

function settle(previous: CacheEntry | undefined, address: string, result: Loaded, now: number): CacheEntry {
  const source = sourceOf(address)
  if (result.ok) {
    // A capture served after a failed live call proves nothing about the service, so only a live answer ends a back-off.
    if (result.liveFailure === 'rate-limited') extendBackoff(source, now)
    else if (result.liveFailure === undefined) backoff.delete(source)
    return {
      address,
      record: result.record,
      tier: result.tier,
      fetchedAt: result.fetchedAt,
      attemptedAt: now,
      state: result.record.isFrozen ? 'frozen' : 'fresh',
    }
  }
  if (result.failure === 'rate-limited') extendBackoff(source, now)
  if (!previous?.record) return { address, attemptedAt: now, state: 'failed', failure: result.failure, failureDetail: result.detail }
  return {
    ...previous,
    attemptedAt: now,
    state: 'stale-since',
    staleSince: previous.staleSince ?? now,
    failure: result.failure,
  }
}

// A refresh-key press bypasses timers and back-off, but a load already in
// flight is still shared, so a double press sends one request.
export function refreshItem(address: string, load: Load, now: number): Promise<CacheEntry> {
  const key = itemKey(address)
  const running = inFlight.get(key)
  if (running) return running
  const previous = entries.get(key)
  entries.set(
    key,
    previous?.record ? { ...previous, attemptedAt: now, state: 'refreshing' } : { address, attemptedAt: now, state: 'loading' },
  )
  const promise = (async () => {
    let result: Loaded
    try {
      result = await load(address)
    } catch {
      result = { ok: false, failure: 'offline' }
    }
    const entry = settle(previous, address, result, now)
    entries.set(key, entry)
    inFlight.delete(key)
    return entry
  })()
  inFlight.set(key, promise)
  return promise
}

function eligible(address: string, now: number, intervalMs: number): CacheEntry | undefined {
  if (!isTimed(address)) return undefined
  const key = itemKey(address)
  if (inFlight.has(key)) return undefined
  const entry = entries.get(key)
  if (!entry?.record || entry.record.isFrozen) return undefined
  if ((backoff.get(sourceOf(address))?.until ?? 0) > now) return undefined
  return now - entry.attemptedAt >= intervalMs ? entry : undefined
}

function plan(input: ScheduleInput): { due: string[]; background: string[] } {
  const { now } = input
  if (now - input.lastActivity >= IDLE_MS) return { due: [], background: [] }
  const onScreen = input.onScreen && eligible(input.onScreen, now, ON_SCREEN_MS) ? input.onScreen : undefined
  const budget = BACKGROUND_CAP - backgroundLoads.filter(at => at > now - BACKGROUND_MS).length
  const seen = new Set(input.onScreen ? [itemKey(input.onScreen)] : [])
  const candidates: { address: string; attemptedAt: number; order: number }[] = []
  for (const address of input.background) {
    const key = itemKey(address)
    if (seen.has(key)) continue
    seen.add(key)
    const entry = eligible(address, now, BACKGROUND_MS)
    if (entry) candidates.push({ address, attemptedAt: entry.attemptedAt, order: candidates.length })
  }
  candidates.sort((a, b) => a.attemptedAt - b.attemptedAt || a.order - b.order)
  const background = candidates.slice(0, Math.max(0, budget)).map(c => c.address)
  return { due: onScreen ? [onScreen, ...background] : background, background }
}

export function dueAddresses(input: ScheduleInput): string[] {
  return plan(input).due
}

function signature(entry: CacheEntry | undefined): string {
  return JSON.stringify([entry?.state, entry?.record, entry?.staleSince, entry?.failure])
}

export async function tick(input: ScheduleInput & { load: Load }): Promise<string[]> {
  const { now } = input
  backgroundLoads = backgroundLoads.filter(at => at > now - BACKGROUND_MS)
  const { due, background } = plan(input)
  backgroundLoads.push(...background.map(() => now))
  const changed = await Promise.all(
    due.map(async address => {
      const before = signature(cached(address))
      const after = await refreshItem(address, input.load, now)
      return before === signature(after) ? undefined : address
    }),
  )
  return changed.filter((a): a is string => a !== undefined)
}

export function titleOf(record: RemoteRecord): Omit<TitleEntry, 'updatedAt'> {
  return {
    title: record.title,
    kind: record.kind,
    ...(record.status ? { status: record.status } : {}),
    ...(record.favicon ? { favicon: record.favicon } : {}),
    ...(record.trail.length ? { trail: record.trail } : {}),
  }
}

export function withTitle(
  map: Readonly<Record<string, TitleEntry>>,
  address: string,
  entry: Omit<TitleEntry, 'updatedAt'>,
  now: number,
  cap = TITLE_CAP,
): Record<string, TitleEntry> {
  const next: Record<string, TitleEntry> = { ...map, [address]: { ...entry, updatedAt: now } }
  const keys = Object.keys(next)
  if (keys.length <= cap) return next
  const oldest = keys.sort((a, b) => (next[a]?.updatedAt ?? 0) - (next[b]?.updatedAt ?? 0)).slice(0, keys.length - cap)
  for (const key of oldest) delete next[key]
  return next
}
