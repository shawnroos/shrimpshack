import { describe, expect, test } from 'claude-code/testing'

import type { Loaded, RemoteKind, Tier, View } from '../types'
import { typeOf } from '../hooks/kinds'
import { sourceLine } from '../hooks/navigation'
import { dueAddresses, isTimed, refreshItem, resetRefresh } from '../hooks/refresh'
import { adapterOfKind } from '../hooks/sources/adapter'

const trailIcon = (kind: string, index: number, count: number) => adapterOfKind(kind).trailIcon(index, count)

const MIN = 60_000
const THREAD = 'https://acme.slack.com/archives/C0123ABCD/p1791759796763609'
const REPLY = 'https://acme.slack.com/archives/C0123ABCD/p1791761128357239?thread_ts=1791759796.763609&cid=C0123ABCD'

// One timed address per back-off bucket; `o/r#N` is timed but its bucket comes from the hostname, so it is web's.
const PROBES = {
  github: 'https://github.com/probe/probe/pull/1',
  linear: 'https://linear.app/probe/issue/PRB-1',
  slack: 'https://probe.slack.com/archives/C0PROBE00/p1791759796000001',
  web: 'probe/probe#1',
} as const

const loadedOk = async (address: string): Promise<Loaded> => ({
  ok: true,
  record: { address, kind: 'gh-pr', title: address, trail: [], meta: [], browserUrl: address },
  tier: 'cli',
  fetchedAt: 0,
})
const rateLimited = async (): Promise<Loaded> => ({ ok: false, failure: 'rate-limited' })

async function heldBuckets(address: string): Promise<string[]> {
  resetRefresh()
  for (const probe of Object.values(PROBES)) await refreshItem(probe, loadedOk, 0)
  // Four rate limits push the wait to 8 minutes, past the 5-minute background interval.
  for (let i = 0; i < 4; i++) await refreshItem(address, rateLimited, 0)
  const due = dueAddresses({ background: Object.values(PROBES), now: 6 * MIN, lastActivity: 6 * MIN })
  return Object.entries(PROBES)
    .filter(([, probe]) => !due.includes(probe))
    .map(([bucket]) => bucket)
}

describe('refresh timing and back-off bucket per address', () => {
  const ROWS: [string, boolean, string][] = [
    ['https://github.com/o/r/pull/9', true, 'github'],
    ['https://github.com/o/r/issues/9', true, 'github'],
    ['http://www.github.com/o/r/pull/9/files#x', true, 'github'],
    ['https://github.com/o/r', false, 'github'],
    ['https://github.com/acme', false, 'github'],
    ['https://github.com/settings/issues/5', false, 'github'],
    ['acme/widgets#42', true, 'web'],
    ['#42', false, 'web'],
    ['https://linear.app/acme/issue/ABC-9', true, 'linear'],
    ['https://linear.app/acme/project/launch-1', false, 'linear'],
    ['https://linear.app/acme', false, 'linear'],
    [THREAD, true, 'slack'],
    [REPLY, true, 'slack'],
    ['https://acme.slack.com/messages/C0123ABCD', false, 'slack'],
    ['https://example.com/page', false, 'web'],
    ['ftp://github.com/x', false, 'github'],
    ['not a url', false, 'web'],
  ]
  for (const [address, timed, bucket] of ROWS) {
    test(`${address}: timed ${timed}, backs off with ${bucket}`, async () => {
      expect(isTimed(address)).toBe(timed)
      expect(await heldBuckets(address)).toEqual([bucket])
    })
  }
})

describe('tier label and trail icon per kind', () => {
  const KINDS: (RemoteKind | undefined)[] = ['gh-pr', 'gh-issue', 'gh-repo', 'linear-issue', 'linear-project', 'slack-thread', 'web', undefined]
  const TIERS: (Tier | undefined)[] = ['cli', 'api', 'mcp', 'session', undefined]
  const LABELS: Record<string, string[]> = {
    gh: ['via gh', 'via api', 'via mcp', 'from this session', 'via ?'],
    linear: ['via cli', 'via Linear API', 'via mcp', 'from this session', 'via ?'],
    slack: ['via slack', 'via api', 'via Slack MCP', 'from this session', 'via ?'],
    web: ['via curl', 'via web fetch', 'via mcp', 'from this session', 'via ?'],
  }
  const familyOfKind = (kind: string | undefined) => (kind?.startsWith('gh-') ? 'gh' : kind?.startsWith('linear-') ? 'linear' : kind?.startsWith('slack-') ? 'slack' : 'web')
  for (const kind of KINDS) {
    test(`${kind ?? 'no record'} names each tier`, () => {
      const labels = TIERS.map(tier => {
        const remote: NonNullable<View['remote']> = { tier, fetchedAt: 1000, ...(kind ? { record: { address: 'a', kind, title: 't', trail: [], meta: [], browserUrl: 'a' } } : {}) }
        return sourceLine(remote, 1000)
      })
      expect(labels).toEqual((LABELS[familyOfKind(kind)] ?? []).map(name => `${name} · 0s ago`))
    })
  }

  const ICONS: Record<string, [string, string, string]> = {
    gh: ['\u{f401}', '\u{f09b}', '\u{f401}'],
    linear: ['\u{f0c0}', '\u{f0c0}', '\u{f0e8}'],
    slack: ['\u{f198}', '\u{f198}', '\u{f086}'],
    web: ['\u{f0ac}', '\u{f0ac}', '\u{f0ac}'],
  }
  const ICON_KINDS = ['gh-pr', 'gh-issue', 'gh-repo', 'gh-number', 'gh-future', 'linear-issue', 'linear-project', 'linear-x', 'slack-thread', 'slack-x', 'web', 'markdown', '']
  for (const kind of ICON_KINDS) {
    test(`${kind || 'empty kind'} trail icons at (0 of 1), (0 of 2), (1 of 2)`, () => {
      expect([trailIcon(kind, 0, 1), trailIcon(kind, 0, 2), trailIcon(kind, 1, 2)]).toEqual(ICONS[familyOfKind(kind)] ?? [])
    })
  }

  test('an unlisted kind sorts as a page unless it is outside every source family', () => {
    expect(['gh-x', 'linear-x', 'slack-x', 'notion-page', 'x'].map(typeOf)).toEqual(['html', 'html', 'html', 'code', 'code'])
  })
})
