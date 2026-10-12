import { describe, expect, test } from 'claude-code/testing'

import type { FailureKind, Loaded, RemoteKind, RemoteRecord } from '../types'
import {
  BACKGROUND_CAP,
  cached,
  dueAddresses,
  freshness,
  isCurrent,
  refreshItem,
  resetRefresh,
  tick,
  titleOf,
  withTitle,
} from '../hooks/refresh'

const SEC = 1000
const MIN = 60 * SEC

function record(address: string, kind: RemoteKind, extra: Partial<RemoteRecord> = {}): RemoteRecord {
  return { address, kind, title: `title of ${address}`, trail: [], meta: [], browserUrl: address, ...extra }
}

type Answer = (address: string, now: number) => Loaded

function loader(answer: Answer) {
  const calls: { address: string; at: number }[] = []
  let clock = 0
  const load = async (address: string): Promise<Loaded> => {
    calls.push({ address, at: clock })
    return answer(address, clock)
  }
  return { calls, load, at: (now: number) => (clock = now) }
}

const pr = (n: number) => `https://github.com/o/r/pull/${n}`
const issue = (n: number) => `https://github.com/o/r/issues/${n}`

function ok(kind: RemoteKind, extra: Partial<RemoteRecord> = {}): Answer {
  return (address, now) => ({ ok: true, record: record(address, kind, extra), tier: 'cli', fetchedAt: now })
}

function failing(failure: FailureKind): Answer {
  return () => ({ ok: false, failure })
}

async function run(
  l: ReturnType<typeof loader>,
  from: number,
  to: number,
  input: { onScreen?: string; background?: readonly string[]; lastActivity?: (now: number) => number },
) {
  for (let now = from; now <= to; now += 15 * SEC) {
    l.at(now)
    await tick({
      onScreen: input.onScreen,
      background: input.background ?? [],
      now,
      lastActivity: input.lastActivity ? input.lastActivity(now) : now,
      load: l.load,
    })
  }
}

describe('on-screen refresh', () => {
  test('AE5: an open issue on screen loads again after 60 s, not before', async () => {
    resetRefresh()
    const l = loader(ok('gh-issue'))
    await refreshItem(issue(1), l.load, 0)
    expect(l.calls).toHaveLength(1)
    await run(l, 15 * SEC, 45 * SEC, { onScreen: issue(1) })
    expect(l.calls).toHaveLength(1)
    await run(l, 60 * SEC, 60 * SEC, { onScreen: issue(1) })
    expect(l.calls.map(c => c.at)).toEqual([0, 60 * SEC])
  })

  test('10 simulated minutes of 15 s ticks with one open PR on screen make exactly 10 loads', async () => {
    resetRefresh()
    const l = loader(ok('gh-pr'))
    await refreshItem(pr(2), l.load, 0)
    await run(l, 15 * SEC, 10 * MIN, { onScreen: pr(2) })
    expect(l.calls).toHaveLength(11)
    expect(l.calls.slice(1).map(c => c.at / MIN)).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
  })

  test('a merged PR does not reload after its first load', async () => {
    resetRefresh()
    const l = loader(ok('gh-pr', { isFrozen: true, status: 'merged' }))
    const entry = await refreshItem(pr(3), l.load, 0)
    expect(entry.state).toBe('frozen')
    await run(l, 15 * SEC, 30 * MIN, { onScreen: pr(3), background: [pr(3)] })
    expect(l.calls).toHaveLength(1)
  })

  test('a web page, a repo and a project never appear in dueAddresses', async () => {
    resetRefresh()
    const addresses = ['https://example.com/a', 'https://github.com/o/r', 'https://linear.app/acme/project/p-1']
    const kinds: RemoteKind[] = ['web', 'gh-repo', 'linear-project']
    for (const [i, address] of addresses.entries()) {
      const kind = kinds[i] ?? 'web'
      await refreshItem(address, async () => ({ ok: true, record: record(address, kind), tier: 'api', fetchedAt: 0 }), 0)
    }
    for (const now of [MIN, 10 * MIN, 60 * MIN]) {
      for (const address of addresses) {
        expect(dueAddresses({ onScreen: address, background: addresses, now, lastActivity: now })).toEqual([])
      }
    }
  })
})

describe('background refresh', () => {
  test('30 open items in Recent load at most 20 per 5-minute cycle; the other 10 load next cycle', async () => {
    resetRefresh()
    const l = loader(ok('gh-issue'))
    const recent = Array.from({ length: 30 }, (_, i) => issue(100 + i))
    for (const address of recent) await refreshItem(address, l.load, 0)
    l.calls.length = 0

    await run(l, 15 * SEC, 5 * MIN, { background: recent })
    expect(l.calls).toHaveLength(BACKGROUND_CAP)
    const first = new Set(l.calls.map(c => c.address))

    await run(l, 5 * MIN + 15 * SEC, 10 * MIN - 15 * SEC, { background: recent })
    expect(l.calls).toHaveLength(BACKGROUND_CAP)

    await run(l, 10 * MIN, 10 * MIN, { background: recent })
    const second = l.calls.slice(BACKGROUND_CAP).map(c => c.address)
    expect(second).toHaveLength(BACKGROUND_CAP)
    const left = recent.filter(a => !first.has(a))
    expect(left).toHaveLength(10)
    for (const address of left) expect(second).toContain(address)
  })

  test('no background load happens before 5 minutes', async () => {
    resetRefresh()
    const l = loader(ok('linear-issue'))
    const address = 'https://linear.app/acme/issue/WEB-1'
    await refreshItem(address, l.load, 0)
    await run(l, 15 * SEC, 5 * MIN - 15 * SEC, { background: [address] })
    expect(l.calls).toHaveLength(1)
    await run(l, 5 * MIN, 5 * MIN, { background: [address] })
    expect(l.calls).toHaveLength(2)
  })

  test('items with no cached record are not background-eligible', () => {
    resetRefresh()
    expect(dueAddresses({ background: [issue(999)], now: 10 * MIN, lastActivity: 10 * MIN })).toEqual([])
  })
})

describe('idle pause', () => {
  test('no loads after 10 minutes with no activity; newer activity resumes them', async () => {
    resetRefresh()
    const l = loader(ok('gh-pr'))
    await refreshItem(pr(10), l.load, 0)
    await refreshItem(pr(11), l.load, 0)
    l.calls.length = 0
    const input = { onScreen: pr(10), background: [pr(11)], lastActivity: () => 0 }
    await run(l, 15 * SEC, 10 * MIN - 15 * SEC, input)
    const beforeIdle = l.calls.length
    expect(beforeIdle).toBeGreaterThan(0)
    await run(l, 10 * MIN, 20 * MIN, input)
    expect(l.calls).toHaveLength(beforeIdle)

    await run(l, 20 * MIN + 15 * SEC, 20 * MIN + 15 * SEC, { ...input, lastActivity: () => 20 * MIN })
    expect(l.calls.length).toBeGreaterThan(beforeIdle)
    expect(l.calls.map(c => c.address)).toContain(pr(10))
    expect(l.calls.slice(beforeIdle).map(c => c.address)).toContain(pr(11))
  })
})

describe('rate limits', () => {
  test('a rate-limited source waits twice as long each time, capped at 30 min, keeping the old record', async () => {
    resetRefresh()
    let isLimited = false
    const l = loader((address, now) =>
      isLimited ? { ok: false, failure: 'rate-limited' } : { ok: true, record: record(address, 'gh-pr'), tier: 'cli', fetchedAt: now },
    )
    const first = await refreshItem(pr(20), l.load, 0)
    isLimited = true
    await run(l, 15 * SEC, 120 * MIN, { onScreen: pr(20) })
    const at = l.calls.map(c => c.at / MIN)
    const gaps = at.slice(2).map((t, i) => t - (at[i + 1] ?? 0))
    expect(at.slice(0, 2)).toEqual([0, 1])
    expect(gaps.slice(0, 6)).toEqual([1, 2, 4, 8, 16, 30])
    expect(gaps.slice(6).every(g => g === 30)).toBe(true)

    const entry = cached(pr(20))
    expect(entry?.state).toBe('stale-since')
    expect(entry?.staleSince).toBe(MIN)
    expect(entry?.failure).toBe('rate-limited')
    expect(entry?.record).toEqual(first.record)
  })

  test('back-off is per source: a rate-limited GitHub does not hold Linear back', async () => {
    resetRefresh()
    const lin = 'https://linear.app/acme/issue/WEB-7'
    const l = loader((address, now) =>
      now > 0 && address.includes('github.com')
        ? { ok: false, failure: 'rate-limited' }
        : { ok: true, record: record(address, address.includes('github') ? 'gh-pr' : 'linear-issue'), tier: 'api', fetchedAt: now },
    )
    await refreshItem(pr(21), l.load, 0)
    await refreshItem(lin, l.load, 0)
    l.at(MIN)
    await refreshItem(pr(21), l.load, MIN)
    l.at(2 * MIN)
    await refreshItem(pr(21), l.load, 2 * MIN)
    const now = 3.5 * MIN
    expect(dueAddresses({ onScreen: pr(21), background: [], now, lastActivity: now })).toEqual([])
    expect(dueAddresses({ onScreen: lin, background: [], now, lastActivity: now })).toEqual([lin])
  })

  test('a captured page served because live was rate-limited stores its record but keeps backing off', async () => {
    resetRefresh()
    let answer: Answer = ok('gh-pr')
    const load = async (a: string) => answer(a, 0)
    await refreshItem(pr(22), load, 0)
    answer = failing('rate-limited')
    await refreshItem(pr(22), load, MIN)
    const fallback = record(pr(22), 'gh-pr', { title: 'from this session' })
    answer = () => ({ ok: true, record: fallback, tier: 'session', fetchedAt: 30 * SEC, liveFailure: 'rate-limited' })
    const served = await refreshItem(pr(22), load, 2 * MIN)
    expect(served.record).toEqual(fallback)
    expect(served.tier).toBe('session')
    const due = (now: number) => dueAddresses({ onScreen: pr(22), background: [], now, lastActivity: now })
    expect(due(3.5 * MIN)).toEqual([])
    expect(due(4 * MIN)).toEqual([pr(22)])
    answer = ok('gh-pr')
    await refreshItem(pr(22), load, 4 * MIN)
    expect(due(5 * MIN)).toEqual([pr(22)])
  })

  test('a captured page served after some other live failure neither clears nor starts a back-off', async () => {
    resetRefresh()
    let answer: Answer = ok('gh-pr')
    const load = async (a: string) => answer(a, 0)
    await refreshItem(pr(23), load, 0)
    answer = failing('rate-limited')
    await refreshItem(pr(23), load, MIN)
    await refreshItem(pr(23), load, 2 * MIN)
    answer = (a, now) => ({ ok: true, record: record(a, 'gh-pr'), tier: 'session', fetchedAt: now, liveFailure: 'offline' })
    await refreshItem(pr(23), load, 2.1 * MIN)
    const due = (now: number) => dueAddresses({ onScreen: pr(23), background: [], now, lastActivity: now })
    expect(due(3.5 * MIN)).toEqual([])
    expect(due(4 * MIN)).toEqual([pr(23)])
  })
})

describe('in-place replacement', () => {
  test('a failed refresh keeps the previous record and never clears it', async () => {
    resetRefresh()
    let answer: Answer = ok('gh-issue')
    const load = async (a: string) => answer(a, 0)
    const first = await refreshItem(issue(30), load, 0)
    answer = failing('offline')
    const second = await refreshItem(issue(30), load, MIN)
    expect(second.state).toBe('stale-since')
    expect(second.record).toEqual(first.record)
    expect(second.staleSince).toBe(MIN)
    const third = await refreshItem(issue(30), load, 2 * MIN)
    expect(third.staleSince).toBe(MIN)
    answer = ok('gh-issue')
    const fourth = await refreshItem(issue(30), load, 3 * MIN)
    expect(fourth.state).toBe('fresh')
    expect(fourth.staleSince).toBeUndefined()
  })

  test('a first load that fails has no record and state failed', async () => {
    resetRefresh()
    const entry = await refreshItem(issue(31), async () => ({ ok: false, failure: 'not-found-or-no-access' }), 0)
    expect(entry.state).toBe('failed')
    expect(entry.record).toBeUndefined()
    expect(entry.failure).toBe('not-found-or-no-access')
  })

  test('readers see the last good record while a refresh is in flight', async () => {
    resetRefresh()
    await refreshItem(issue(32), async a => ({ ok: true, record: record(a, 'gh-issue'), tier: 'cli', fetchedAt: 0 }), 0)
    let release: (l: Loaded) => void = () => {}
    const pending = refreshItem(issue(32), () => new Promise<Loaded>(r => (release = r)), MIN)
    expect(cached(issue(32))?.state).toBe('refreshing')
    expect(cached(issue(32))?.record?.title).toBe(`title of ${issue(32)}`)
    release({ ok: true, record: record(issue(32), 'gh-issue', { title: 'new' }), tier: 'cli', fetchedAt: MIN })
    expect((await pending).record?.title).toBe('new')
  })

  test('pressing refresh twice quickly sends one request', async () => {
    resetRefresh()
    let calls = 0
    let release: (l: Loaded) => void = () => {}
    const load = () => {
      calls++
      return new Promise<Loaded>(r => (release = r))
    }
    const a = refreshItem(pr(33), load, 0)
    const b = refreshItem(pr(33), load, 100)
    const c = refreshItem(issue(33), load, 200)
    release({ ok: true, record: record(pr(33), 'gh-pr'), tier: 'cli', fetchedAt: 0 })
    expect(calls).toBe(1)
    expect(await a).toBe(await b)
    expect(await c).toBe(await a)
  })

  test('a late response for an address no longer on screen updates the cache but must not replace the view', async () => {
    resetRefresh()
    let release: (l: Loaded) => void = () => {}
    const pending = refreshItem(pr(34), () => new Promise<Loaded>(r => (release = r)), 0)
    const onScreenNow = pr(35)
    release({ ok: true, record: record(pr(34), 'gh-pr'), tier: 'cli', fetchedAt: 0 })
    const entry = await pending
    expect(cached(pr(34))?.record?.address).toBe(pr(34))
    expect(isCurrent(onScreenNow, entry.address)).toBe(false)
    expect(isCurrent(pr(34), entry.address)).toBe(true)
    expect(isCurrent(issue(34), entry.address)).toBe(true)
    expect(isCurrent(undefined, entry.address)).toBe(false)
  })

  test('a fresh entry reads as stale once its 60 s TTL passes', async () => {
    resetRefresh()
    const entry = await refreshItem(issue(36), async a => ({ ok: true, record: record(a, 'gh-issue'), tier: 'cli', fetchedAt: 0 }), 0)
    expect(freshness(entry, 59 * SEC)).toBe('fresh')
    expect(freshness(entry, 60 * SEC)).toBe('stale')
  })
})

describe('title store', () => {
  test('titleOf takes title, kind, status and favicon from a record', () => {
    const r = record('https://example.com', 'web', { status: 'open', favicon: 'https://example.com/f.ico', title: 'Hi' })
    expect(titleOf(r)).toEqual({ title: 'Hi', kind: 'web', status: 'open', favicon: 'https://example.com/f.ico' })
    expect(titleOf(record('https://x.y', 'web'))).toEqual({ title: 'title of https://x.y', kind: 'web' })
  })

  test('withTitle keeps at most the cap, dropping the least recently updated', () => {
    let map = {}
    for (let i = 0; i < 5; i++) map = withTitle(map, `a${i}`, { title: `t${i}`, kind: 'web' }, i, 3)
    expect(Object.keys(map).sort()).toEqual(['a2', 'a3', 'a4'])
    map = withTitle(map, 'a2', { title: 'renamed', kind: 'web' }, 10, 3)
    map = withTitle(map, 'a5', { title: 't5', kind: 'web' }, 11, 3)
    expect(Object.keys(map).sort()).toEqual(['a2', 'a4', 'a5'])
  })

  test('withTitle does not mutate its input', () => {
    const before = { x: { title: 'x', kind: 'web' as const, updatedAt: 0 } }
    const after = withTitle(before, 'y', { title: 'y', kind: 'web' }, 1)
    expect(Object.keys(before)).toEqual(['x'])
    expect(Object.keys(after).sort()).toEqual(['x', 'y'])
  })
})
