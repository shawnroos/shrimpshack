import type { Loaded, RemoteFailure, Tier } from '../../types'
import type { Captured, CaptureIo } from '../capture'
import { capturedGithubRef, fromCapture as githubFromCapture, loadGithub } from './github'
import { capturedLinearRef, fromCapture as linearFromCapture, loadLinear } from './linear'
import { learnLinear } from './linear-identity'
import type { Ref } from '../refs'
import { loadSlack } from './slack'
import type { SourceIo } from '../source-io'
import { ICON } from '../theme'
import { fromCapture as webFromCapture, loadWeb } from './web'
import { parseUrl } from '../wire'

export type RemoteIo = SourceIo & CaptureIo

export type SourceId = 'github' | 'linear' | 'slack' | 'web'

export type FailureText = { title: string; hint: string }

export type CaptureReader = {
  servers: RegExp
  refOf: (name: string, args: Record<string, unknown>, text: string) => Ref | null
  learn?: (found: readonly Ref[]) => boolean
}

export type SourceAdapter = {
  id: SourceId
  // Takes any kind string, so a kind no table lists yet still finds its source by prefix.
  matches: (kind: string) => boolean
  // The back-off bucket comes from the hostname, not the parsed Ref: `o/r#12` waits with web, and github.com/settings with GitHub.
  ownsHost: (host: string) => boolean
  isTimed: (ref: Ref) => boolean
  tierLabel: (tier: Tier | undefined) => string
  // The header shortens a crumb by keeping its first two characters as the icon, so every trail piece needs one.
  trailIcon: (index: number, count: number) => string
  trailHref?: (address: string, index: number, count: number) => string | undefined
  load: (io: RemoteIo, ref: Ref, now: number) => Promise<Loaded>
  fromCapture?: (captured: Captured, ref: Ref) => Loaded | null
  capture?: CaptureReader
}

export function failureText(kind: RemoteFailure): FailureText {
  switch (kind) {
    case 'cli-missing':
      return { title: 'GitHub CLI is not installed', hint: 'Install it with `brew install gh`, then run `gh auth login`' }
    case 'cli-unauthed':
      return { title: 'GitHub CLI is not signed in', hint: 'Run `gh auth login` in a terminal' }
    case 'key-missing':
      return { title: 'No Linear API key found', hint: 'Set LINEAR_API_KEY or add it to ~/.secrets' }
    case 'key-refused':
      return { title: 'Linear refused the API key', hint: 'Create a new key in Linear settings and update LINEAR_API_KEY' }
    case 'not-found-or-no-access':
      return { title: 'Not found, or you have no access', hint: 'Check the link, or open it in the browser' }
    case 'gone':
      return { title: 'Not found: it was deleted, moved, or you have no access', hint: 'Check the link, or open it in the browser' }
    case 'rate-limited':
      return { title: 'Rate limited', hint: 'Wait a minute, then refresh' }
    case 'offline':
      return { title: 'Could not reach the service', hint: 'Check your connection, then refresh' }
    case 'query-bug':
      return { title: 'peek sent a request the service rejected', hint: 'Open it in the browser; this is a peek bug' }
    case 'fetch-blocked':
      return { title: 'Your network policy blocks this request', hint: 'Open it in the browser instead' }
    case 'process-unavailable':
      return { title: 'Command-line tools are unavailable here', hint: 'This surface cannot run command-line tools' }
    case 'slack-unavailable':
      return { title: 'Slack is not connected', hint: 'Slack: connect the Slack MCP server (/mcp), or install the Slack CLI and run `slack login`' }
  }
}

function tierLabels(names: Partial<Record<Tier, string>>): (tier: Tier | undefined) => string {
  return tier => (tier === 'session' ? 'from this session' : ((tier && names[tier]) ?? `via ${tier ?? '?'}`))
}

const GITHUB: SourceAdapter = {
  id: 'github',
  matches: kind => kind.startsWith('gh-'),
  ownsHost: host => host === 'github.com',
  isTimed: ref => ref.kind !== 'gh-repo',
  tierLabel: tierLabels({ cli: 'via gh' }),
  trailIcon: (index, count) => (index === 0 && count > 1 ? '\u{f09b}' : ICON['gh-repo']),
  trailHref: (address, index, count) => {
    const [owner, repo] = (parseUrl(address)?.pathname ?? '').split('/').filter(Boolean)
    const levels = count > 1 ? [owner, owner && repo ? `${owner}/${repo}` : undefined] : [owner]
    const path = levels[index]
    return path ? `https://github.com/${path}` : undefined
  },
  load: loadGithub,
  fromCapture: githubFromCapture,
  // Slack's own tools name no item; a GitHub-shaped read on a Slack server has always been read as GitHub.
  capture: { servers: /github|slack/i, refOf: capturedGithubRef },
}

const LINEAR: SourceAdapter = {
  id: 'linear',
  matches: kind => kind.startsWith('linear-'),
  ownsHost: host => host === 'linear.app',
  isTimed: ref => ref.kind === 'linear-issue',
  tierLabel: tierLabels({ api: 'via Linear API' }),
  trailIcon: index => (index === 0 ? '\u{f0c0}' : ICON['linear-project']),
  load: loadLinear,
  fromCapture: linearFromCapture,
  capture: { servers: /linear/i, refOf: (_name, args, text) => capturedLinearRef(args, text), learn: learnLinear },
}

const SLACK: SourceAdapter = {
  id: 'slack',
  matches: kind => kind.startsWith('slack-'),
  ownsHost: host => host.endsWith('.slack.com'),
  isTimed: () => true,
  tierLabel: tierLabels({ mcp: 'via Slack MCP', cli: 'via slack' }),
  trailIcon: index => (index === 0 ? ICON['slack-thread'] : '\u{f086}'),
  load: loadSlack,
}

const WEB: SourceAdapter = {
  id: 'web',
  matches: kind => kind === 'web',
  ownsHost: () => false,
  isTimed: () => false,
  tierLabel: tierLabels({ cli: 'via curl', api: 'via web fetch' }),
  trailIcon: () => '\u{f0ac}',
  trailHref: (address, index) => {
    const url = parseUrl(address)
    return index === 0 && url ? `${url.protocol}//${url.host}/` : undefined
  },
  load: loadWeb,
  fromCapture: webFromCapture,
}

const ADAPTERS: readonly SourceAdapter[] = [GITHUB, LINEAR, SLACK, WEB]

export function adapterOfKind(kind: string): SourceAdapter {
  return ADAPTERS.find(adapter => adapter.matches(kind)) ?? WEB
}

export function adapterFor(ref: Ref): SourceAdapter {
  return adapterOfKind(ref.kind)
}

export function adapterOfAddress(address: string): SourceAdapter {
  const host = parseUrl(address)?.hostname.toLowerCase().replace(/^www\./, '')
  return (host !== undefined && ADAPTERS.find(adapter => adapter.ownsHost(host))) || WEB
}

// Linear first: a server named for both is read as Linear, as before.
const CAPTURE_READERS = [LINEAR, GITHUB].flatMap(adapter => (adapter.capture ? [adapter.capture] : []))

export function captureReaderOf(server: string): CaptureReader | undefined {
  return CAPTURE_READERS.find(reader => reader.servers.test(server))
}
