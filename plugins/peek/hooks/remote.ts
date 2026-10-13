import type { Loaded } from '../types'
import { lookup, replay } from './capture'
import type { Ref } from './refs'
import { adapterFor } from './sources/adapter'
import type { RemoteIo } from './sources/adapter'
import type { SourceIo } from './source-io'
import { withRemoteMedia } from './sources/web'

export type { RemoteIo } from './sources/adapter'

// Replay repeats an MCP read, which can ask for permission, so only a refresh
// does it; an open uses whatever the session already fetched.
export async function loadItem(io: RemoteIo, ref: Ref, now: number, options: { canReplay?: boolean } = {}): Promise<Loaded> {
  const source = adapterFor(ref)
  const live = await source.load(io, ref, now)
  if (live.ok) return withMedia(io, live)
  const replayed = options.canReplay ? await replay(io, ref.address).catch(() => null) : null
  const captured = replayed ?? lookup(ref.address)
  // A source with no capture reader (Slack) still replays: dropping the replay would change which MCP calls a refresh makes.
  const fallback = captured ? (source.fromCapture?.(captured, ref) ?? null) : null
  return fallback?.ok ? withMedia(io, { ...fallback, liveFailure: live.failure }) : live
}

// A reader page placed its media while it parsed the HTML. A README's badge row would become a stack of image embeds.
async function withMedia(io: SourceIo, loaded: Extract<Loaded, { ok: true }>): Promise<Loaded> {
  if (loaded.record.kind === 'web' || loaded.record.kind === 'gh-repo') return loaded
  const record = await withRemoteMedia(io, loaded.record).catch(() => loaded.record)
  return { ...loaded, record }
}
