import { describe, expect, test } from 'claude-code/testing'

import type { Loaded, RemoteRecord } from '../types'
import { cached, dueAddresses, refreshItem, resetRefresh } from '../hooks/refresh'

const MIN = 60_000
const pr = (n: number) => `https://github.com/o/r/pull/${n}`
const linear = (n: number) => `https://linear.app/acme/issue/WEB-${n}`

function record(address: string, extra: Partial<RemoteRecord> = {}): RemoteRecord {
  return { address, kind: address.includes('linear') ? 'linear-issue' : 'gh-pr', title: `title of ${address}`, trail: [], meta: [], browserUrl: address, ...extra }
}

const good = (address: string, now: number): Loaded => ({ ok: true, record: record(address), tier: 'cli', fetchedAt: now })
// An ok answer with no record makes settle throw: the one way it can.
const malformed = { ok: true, tier: 'cli', fetchedAt: 0 } as unknown as Loaded

describe('refresh dedupe and in-flight', () => {
  test('a pull request and its issue spelling share one in-flight load; once it settles the next refresh loads again', async () => {
    resetRefresh()
    const calls: string[] = []
    let release: () => void = () => {}
    const load = (address: string) => {
      calls.push(address)
      return new Promise<Loaded>(r => (release = () => r(good(address, 0))))
    }
    const a = refreshItem(pr(1), load, 0)
    const b = refreshItem('https://github.com/o/r/issues/1', load, 0)
    expect(a).toBe(b)
    release()
    await a
    const c = refreshItem(pr(1), load, 10)
    release()
    await c
    expect(calls).toEqual([pr(1), pr(1)])
  })

  test('a load that throws settles as offline, clears the in-flight entry and lets the next refresh load again', async () => {
    resetRefresh()
    let calls = 0
    const load = async () => {
      calls++
      throw new Error('boom')
    }
    expect(await refreshItem(pr(2), load, 0)).toEqual({ address: pr(2), attemptedAt: 0, state: 'failed', failure: 'offline', failureDetail: undefined })
    await refreshItem(pr(2), load, 10)
    expect(calls).toBe(2)
  })
})

describe('a settle that throws', () => {
  test('the refresh rejects, a first load stays loading, and another item still loads', async () => {
    resetRefresh()
    await expect(refreshItem(pr(3), async () => malformed, 0)).rejects.toThrow()
    expect(cached(pr(3))).toEqual({ address: pr(3), attemptedAt: 0, state: 'loading' })
    expect((await refreshItem(pr(4), async () => good(pr(4), 0), 0)).state).toBe('fresh')
  })

  test('over a cached record the entry stays refreshing with the old record', async () => {
    resetRefresh()
    await refreshItem(pr(5), async () => good(pr(5), 0), 0)
    await expect(refreshItem(pr(5), async () => malformed, MIN)).rejects.toThrow()
    expect(cached(pr(5))?.state).toBe('refreshing')
    expect(cached(pr(5))?.attemptedAt).toBe(MIN)
    expect(cached(pr(5))?.record?.title).toBe(`title of ${pr(5)}`)
  })

  test('the throw clears an earlier back-off on its source, as a live answer does, and leaves other sources alone', async () => {
    resetRefresh()
    await refreshItem(pr(6), async () => good(pr(6), 0), 0)
    await refreshItem(linear(6), async () => good(linear(6), 0), 0)
    // Four rate limits in a row put the back-off at 8 minutes, past the 5-minute background interval.
    for (let i = 0; i < 4; i++) {
      await refreshItem(pr(6), async () => ({ ok: false, failure: 'rate-limited' }), 0)
      await refreshItem(linear(6), async () => ({ ok: false, failure: 'rate-limited' }), 0)
    }
    const input = { background: [pr(6), linear(6)], now: 5 * MIN, lastActivity: 5 * MIN }
    expect(dueAddresses(input)).toEqual([])
    await expect(refreshItem(pr(7), async () => malformed, 0)).rejects.toThrow()
    expect(dueAddresses(input)).toEqual([pr(6)])
  })

  test('after the throw, the next refresh of that item loads again instead of sharing the failed one', async () => {
    resetRefresh()
    let calls = 0
    const load = async () => {
      calls++
      return calls === 1 ? malformed : good(pr(8), 0)
    }
    await expect(refreshItem(pr(8), load, 0)).rejects.toThrow()
    expect((await refreshItem(pr(8), load, 10)).state).toBe('fresh')
    expect(calls).toBe(2)
  })
})
