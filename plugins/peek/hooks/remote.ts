import type { Loaded } from '../types'
import { lookup, replay } from './capture'
import type { Captured, CaptureIo } from './capture'
import { fromCapture as githubFromCapture, loadGithub } from './github'
import { fromCapture as linearFromCapture, loadLinear } from './linear'
import type { Ref } from './refs'
import type { SourceIo } from './sources'
import { fromCapture as webFromCapture, loadWeb, withRemoteMedia } from './web'

export type RemoteIo = SourceIo & CaptureIo

type Source = {
  load: (io: SourceIo, ref: Ref, now: number) => Promise<Loaded>
  fromCapture: (captured: Captured, ref: Ref) => Loaded | null
}

function sourceFor(ref: Ref): Source {
  if (ref.kind === 'linear-issue' || ref.kind === 'linear-project') return { load: loadLinear, fromCapture: linearFromCapture }
  if (ref.kind === 'web') return { load: loadWeb, fromCapture: webFromCapture }
  return { load: loadGithub, fromCapture: githubFromCapture }
}

// Replay repeats an MCP read with no permission prompt, so only a refresh asks
// for it; an open uses whatever the session already fetched.
export async function loadItem(io: RemoteIo, ref: Ref, now: number, options: { canReplay?: boolean } = {}): Promise<Loaded> {
  const source = sourceFor(ref)
  const live = await source.load(io, ref, now)
  if (live.ok) return withMedia(io, live)
  const replayed = options.canReplay ? await replay(io, ref.address).catch(() => null) : null
  const captured = replayed ?? lookup(ref.address)
  const fallback = captured ? source.fromCapture(captured, ref) : null
  return fallback?.ok ? withMedia(io, { ...fallback, liveFailure: live.failure }) : live
}

// A reader page placed its media while it parsed the HTML. A README's badge row would become a stack of image embeds.
async function withMedia(io: SourceIo, loaded: Extract<Loaded, { ok: true }>): Promise<Loaded> {
  if (loaded.record.kind === 'web' || loaded.record.kind === 'gh-repo') return loaded
  const record = await withRemoteMedia(io, loaded.record).catch(() => loaded.record)
  return { ...loaded, record }
}
