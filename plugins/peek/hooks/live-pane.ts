import type { LiveFailure, View } from '../types'
import { setStar } from './groups-session'
import { createLive, isWebUrl, pagePoint, typedInput } from './live'
import type { FrameGeometry, HelperInput, Live, LiveState, TypedKey, Viewport } from './live'
import { goBack, openExternally } from './navigation'
import type { NavIo } from './navigation'
import type { Action } from './pane/types'

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
  notice: null as { href: string; kind: LiveFailure } | null,
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

// The keys the live page answers to, from the footer and from the live input layer alike; liveKey routes by hotkey or `keys`.
export function liveActions(io: NavIo, isStarred = false): Action[] {
  const pageHeight = () => liveSession.viewport?.height ?? 400
  const liveUrl = () => liveSession.live?.state().url
  return [
    { id: 'next', label: 'Down', hotkey: 'j', keys: ['down'], run: () => scrollLive(LINE_SCROLL_PX) },
    { id: 'prev', label: 'Up', hotkey: 'k', keys: ['up'], run: () => scrollLive(-LINE_SCROLL_PX) },
    {
      id: 'star',
      label: isStarred ? 'Unstar' : 'Star',
      hotkey: 'f',
      run: async () => {
        const url = liveUrl()
        const current = await io.view.read()
        return url || current ? void setStar(io, url ?? current?.href ?? '') : undefined
      },
    },
    {
      id: 'open',
      label: 'Open in browser',
      hotkey: 'o',
      run: async () => {
        const url = liveUrl()
        const current = await io.view.read()
        return url && isWebUrl(url) ? void io.run(['open', url]).catch(() => undefined) : current ? openExternally(io, current) : undefined
      },
    },
    { id: 'refresh', label: 'Reload', hotkey: 'u', run: () => void liveSession.live?.command('reload') },
    { id: 'back', label: 'Back', hotkey: 'b', run: () => liveBack(io) },
    {
      id: 'copy',
      label: 'Copy link',
      hotkey: 'c',
      run: async () => {
        const url = liveUrl()
        const current = await io.view.read()
        return void io.copy({ text: url ?? current?.location ?? '' })
      },
    },
    { id: 'page-down', label: 'Page down', keys: [' ', 'pagedown'], run: () => scrollLive(Math.round(pageHeight() * 0.8)) },
    { id: 'page-up', label: 'Page up', keys: ['pageup'], run: () => scrollLive(-Math.round(pageHeight() * 0.8)) },
    { id: 'reader', label: 'Reader', keys: ['v'], run: () => leaveLive().then(() => io.invalidate()) },
  ]
}

export async function liveKey(io: NavIo, key: string) {
  return liveActions(io).find(one => one.hotkey === key || one.keys?.includes(key))?.run()
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
