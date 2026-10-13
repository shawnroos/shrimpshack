import type { Ports } from './ports'
import type { RemoteFailure } from '../types'
import { fromHttpStatus, ghFailure, isPolicyRefusal } from './sources/classify'
import { parseUrl } from './wire'
import { sessionMemo } from './cache'
import { findKey } from './sources/linear-credentials'

const TOOLS_PROBE = 'for t in gh curl; do command -v "$t" >/dev/null 2>&1 && echo "$t"; done'
const GH_TIMEOUT_MS = 20_000

export type SourceIo = Pick<Ports, 'sessionId' | 'run' | 'fetch' | 'linearKeyEnv' | 'home' | 'read' | 'sleep'>

export type Probe = {
  gh: RemoteFailure | null
  hasCurl: boolean
  hasKey: boolean
}

export type Failed = { ok: false; failure: RemoteFailure; detail?: string }

// Only a working gh is kept: a later `gh auth login` or install must be noticed without restarting the session.
const probes = sessionMemo<Probe>({ keep: found => found.gh === null })

export async function probe(io: SourceIo): Promise<Probe> {
  return probes.get(await io.sessionId(), () => runProbe(io))
}

async function runProbe(io: SourceIo): Promise<Probe> {
  const [key, tools] = await Promise.all([findKey(io), io.run(['sh', '-c', TOOLS_PROBE], { timeoutMs: 5000 }).catch(() => null)])
  const hasKey = key !== null
  if (!tools) return { gh: 'process-unavailable', hasCurl: false, hasKey }
  const found = new Set(tools.stdout.split('\n').map(line => line.trim()))
  const hasCurl = found.has('curl')
  if (!found.has('gh')) return { gh: 'cli-missing', hasCurl, hasKey }
  const status = await io.run(['gh', 'auth', 'status'], { timeoutMs: 10_000 }).catch(() => null)
  const gh: RemoteFailure | null = status === null ? 'offline' : status.exitCode === 0 ? null : 'cli-unauthed'
  return { gh, hasCurl, hasKey }
}

export async function hasCurl(io: SourceIo): Promise<boolean> {
  return (await probe(io)).hasCurl
}

export async function runGh(io: SourceIo, args: readonly string[]): Promise<{ ok: true; stdout: string } | Failed> {
  const found = await probe(io)
  if (found.gh) return { ok: false, failure: found.gh }
  const ran = await io.run(['gh', ...args], { timeoutMs: GH_TIMEOUT_MS }).catch(() => null)
  if (!ran) return { ok: false, failure: 'offline' }
  if (ran.exitCode !== 0) return { ok: false, failure: ghFailure(ran.stderr) }
  return { ok: true, stdout: ran.stdout }
}

const STATUS_TEXT: Record<number, string> = {
  400: 'Bad Request',
  401: 'Unauthorized',
  403: 'Forbidden',
  404: 'Not Found',
  410: 'Gone',
  429: 'Too Many Requests',
  500: 'Internal Server Error',
  502: 'Bad Gateway',
  503: 'Service Unavailable',
}

export function httpDetail(status: number, url: string): string {
  const host = parseUrl(url)?.host ?? ''
  return [`HTTP ${status}`, STATUS_TEXT[status], host && `from ${host}`].filter(Boolean).join(' ')
}

export async function httpText(io: SourceIo, url: string): Promise<{ ok: true; text: string; finalUrl?: string } | Failed> {
  const parsed = parseUrl(url)
  if (!parsed) return { ok: false, failure: 'query-bug' }
  if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') return { ok: false, failure: 'query-bug' }
  const target = parsed.href
  let response
  try {
    response = await io.fetch(target)
  } catch (error) {
    return { ok: false, failure: isPolicyRefusal(error) ? 'fetch-blocked' : 'offline' }
  }
  if (!response.ok) return { ok: false, failure: fromHttpStatus(response.status, 'page'), detail: httpDetail(response.status, target) }
  return { ok: true, text: response.text }
}
