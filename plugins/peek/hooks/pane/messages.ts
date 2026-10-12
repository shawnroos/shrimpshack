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
