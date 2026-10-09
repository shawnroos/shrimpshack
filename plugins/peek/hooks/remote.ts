import type { Loaded } from '../types'
import { lookup, replay } from './capture'
import type { Captured, CaptureIo } from './capture'
import { fromCapture as githubFromCapture, loadGithub } from './github'
import { fromCapture as linearFromCapture, loadLinear } from './linear'
import type { Ref } from './refs'
import type { SourceIo } from './sources'
import { fromCapture as webFromCapture, loadWeb } from './web'

export type RemoteIo = SourceIo & CaptureIo

function liveLoader(ref: Ref): (io: SourceIo, ref: Ref, now: number) => Promise<Loaded> {
  if (ref.kind === 'linear-issue' || ref.kind === 'linear-project') return loadLinear
  if (ref.kind === 'web') return loadWeb
  return loadGithub
}

function normalise(captured: Captured, ref: Ref, now: number): Loaded | null {
  if (ref.kind === 'linear-issue' || ref.kind === 'linear-project') return linearFromCapture(captured, ref, now)
  if (ref.kind === 'web') return webFromCapture(captured, ref, now)
  return githubFromCapture(captured, ref, now)
}

// Replay repeats an MCP read with no permission prompt, so only a refresh asks
// for it; an open uses whatever the session already fetched.
export async function loadItem(io: RemoteIo, ref: Ref, now: number, options: { canReplay?: boolean } = {}): Promise<Loaded> {
  const live = await liveLoader(ref)(io, ref, now)
  if (live.ok) return live
  const replayed = options.canReplay ? await replay(io, ref.address).catch(() => null) : null
  const captured = replayed ?? lookup(ref.address)
  return (captured && normalise(captured, ref, now)) ?? live
}
