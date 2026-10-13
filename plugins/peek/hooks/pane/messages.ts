import type { Mode } from '../../types'
import type { LiveInputEvent } from '../live-pane'

// What the client modules post, as they post it.
export type PaneWire =
  | { liveInput: LiveInputEvent[] }
  | { star: string }
  | { toggle: string }
  | { mode: Mode }
  | { openGroup: string }
  | { starGroup: string }
  | { open: string; inGroup: string; key: string }
  | { open: string }
  | { go: string }

export type PaneMessage =
  | { t: 'liveInput'; events: LiveInputEvent[] }
  | { t: 'star'; href: string }
  | { t: 'toggle'; href: string }
  | { t: 'mode'; mode: Mode }
  | { t: 'openGroup'; id: string }
  | { t: 'starGroup'; id: string }
  | { t: 'openInGroup'; href: string; group: string; key: string }
  | { t: 'open'; href: string }
  | { t: 'go'; href: string }

const MODE_IDS: Record<Mode, true> = { view: true, recent: true, gallery: true, groups: true }
const isMode = (value: unknown): value is Mode => typeof value === 'string' && Object.prototype.hasOwnProperty.call(MODE_IDS, value)

// A post naming several of these is read by the first match, in this order.
export function parsePaneMessage(data: unknown): PaneMessage | null {
  if (typeof data !== 'object' || data === null) return null
  const one = data as Record<string, unknown>
  if (Array.isArray(one.liveInput)) return { t: 'liveInput', events: one.liveInput as LiveInputEvent[] }
  if (typeof one.star === 'string') return { t: 'star', href: one.star }
  if (typeof one.toggle === 'string') return { t: 'toggle', href: one.toggle }
  if (isMode(one.mode)) return { t: 'mode', mode: one.mode }
  if (typeof one.openGroup === 'string') return { t: 'openGroup', id: one.openGroup }
  if (typeof one.starGroup === 'string') return { t: 'starGroup', id: one.starGroup }
  if (typeof one.open === 'string' && typeof one.inGroup === 'string') return { t: 'openInGroup', href: one.open, group: one.inGroup, key: String(one.key ?? '') }
  if (typeof one.open === 'string') return { t: 'open', href: one.open }
  if (typeof one.go === 'string') return { t: 'go', href: one.go }
  return null
}
