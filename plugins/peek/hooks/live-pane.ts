import type { View } from '../types'
import { setStar } from './groups-session'
import { createLive, isWebUrl, pagePoint, typedInput } from './live'
import type { FrameGeometry, HelperInput, Live, LiveFailureKind, LiveState, TypedKey, Viewport } from './live'
import { goBack, openExternally } from './navigation'
import type { NavIo } from './navigation'

export const LIVE_FRAME = 'live-frame'
// No API reports a cell's pixel size; 8 CSS px a column keeps text near its normal size at the 1 MB/s frame budget.
const LIVE_PX_PER_COLUMN = 8
const CELL_ASPECT = 2.1
export const LINE_SCROLL_PX = 80
export const WHEEL_SCROLL_PX = 60

export const liveSession = {
  live: null as Live | null,
  href: null as string | null,
  viewport: null as Viewport | null,
  isFrameDrawn: false,
  notice: null as { href: string; kind: LiveFailureKind } | null,
  isTyping: false,
  lastInputSeq: 0,
  geom: null as FrameGeometry | null,
}

function onLiveChange(io: NavIo, state: LiveState, event?: { t: string }) {
  if (state.failure && liveSession.href) {
    liveSession.notice = { href: liveSession.href, kind: state.failure.kind }
    liveSession.href = null
    liveSession.isFrameDrawn = false
  }
  if (event?.t === 'frame' && liveSession.isFrameDrawn && liveSession.href && state.frame) {
    const { path, id } = state.frame
    // A refused blit (Image not mounted yet, or mid-resize) is answered with { deny }, not a rejection; a redraw draws the newest frame instead.
    void io.blit({ key: LIVE_FRAME, source: { file: path, format: 'png', generation: id } }).then(
      result => {
        if (result.deny) io.invalidate()
      },
      () => io.invalidate(),
    )
    return
  }
  if (event?.t === 'focus') liveSession.isTyping = liveSession.href !== null && state.isEditable
  // A new document has no focused field yet; typing resumes only when the next click lands on one.
  if (event?.t === 'nav' || (event?.t === 'load' && state.load === 'loading')) liveSession.isTyping = false
  if (event?.t === 'cookies') return
  io.invalidate()
}

function sendInput(events: HelperInput[]) {
  if (events.length > 0) void liveSession.live?.command('input', { events }).catch(() => undefined)
}

export function scrollLive(dy: number, at?: { x: number; y: number }) {
  const viewport = liveSession.viewport
  if (!viewport) return
  const point = at ?? { x: Math.floor(viewport.width / 2), y: Math.floor(viewport.height / 2) }
  sendInput([{ type: 'scroll', ...point, dy }])
}

async function liveBack(io: NavIo) {
  if (liveSession.live?.state().canBack) await liveSession.live.command('back')
  else {
    await leaveLive()
    await goBack(io)
  }
}

export async function liveKey(io: NavIo, key: string) {
  const height = liveSession.viewport?.height ?? 400
  const url = liveSession.live?.state().url
  const current = key === 'o' || key === 'c' || key === 'f' ? await io.view.read() : null
  switch (key) {
    case 'j':
    case 'down':
      return scrollLive(LINE_SCROLL_PX)
    case 'k':
    case 'up':
      return scrollLive(-LINE_SCROLL_PX)
    case ' ':
    case 'pagedown':
      return scrollLive(Math.round(height * 0.8))
    case 'pageup':
      return scrollLive(-Math.round(height * 0.8))
    case 'b':
      return liveBack(io)
    case 'u':
      return void liveSession.live?.command('reload')
    case 'v':
      return leaveLive().then(() => io.invalidate())
    case 'o':
      return url && isWebUrl(url) ? void io.run(['open', url]).catch(() => undefined) : current ? openExternally(io, current) : undefined
    case 'c':
      return void io.copy({ text: url ?? current?.location ?? '' })
    case 'f':
      return url || current ? void setStar(io, url ?? current?.href ?? '') : undefined
  }
}

export type LiveInputEvent = { seq: number; type: 'click'; x: number; y: number } | ({ seq: number; type: 'key' } & TypedKey)

export async function onLiveInput(io: NavIo, events: readonly LiveInputEvent[]) {
  const fresh = events.filter(one => one.seq > liveSession.lastInputSeq).sort((a, b) => a.seq - b.seq)
  let typed: TypedKey[] = []
  const flush = () => {
    sendInput(typedInput(typed))
    typed = []
  }
  for (const one of fresh) {
    liveSession.lastInputSeq = one.seq
    if (one.type === 'click') {
      flush()
      if (liveSession.geom && liveSession.viewport) sendInput([{ type: 'click', ...pagePoint(one, liveSession.geom, liveSession.viewport) }])
    } else if (liveSession.isTyping) typed.push(one)
    else {
      flush()
      await liveKey(io, one.key)
    }
  }
  flush()
}

function liveOf(io: NavIo): Live {
  liveSession.live ??= createLive(io.liveIo(), (state, event) => onLiveChange(io, state, event))
  return liveSession.live
}

export function liveBox(columns: number, rows: number): Viewport {
  const width = Math.round(Math.max(320, Math.min(900, columns * LIVE_PX_PER_COLUMN)))
  return { width, height: Math.round((width * rows * CELL_ASPECT) / columns) }
}

export async function toggleLive(io: NavIo, current: View, viewport: Viewport) {
  if (liveSession.href === current.href) {
    await leaveLive()
    return
  }
  liveSession.notice = null
  liveSession.href = current.href
  liveSession.viewport = viewport
  liveSession.isFrameDrawn = false
  const url = current.remote?.record?.address ?? current.location
  if (!(await liveOf(io).start(url, viewport))) liveSession.href = null
  io.invalidate()
}

export async function leaveLive() {
  liveSession.href = null
  liveSession.isFrameDrawn = false
  liveSession.isTyping = false
  await liveSession.live?.leave().catch(() => undefined)
}
