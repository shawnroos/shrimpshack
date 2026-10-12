import type { ClientSurface, JsonValue } from 'claude-code'

import { C as BASE, MUTED, mute } from './theme'

export type Hovered = { hovered: number }
export type Hit<T> = { hovered: number; target?: T }

export function paletteOf(isMuted: boolean | undefined) {
  return { C: isMuted ? MUTED : BASE, tone: (color: string) => (isMuted ? mute(color) : color) }
}

const latest = new WeakMap<object, unknown>()

// The pointer listener is attached once, on the first render, so it reads the props of the latest render.
export function hoverable<P, T>(
  props: P,
  surface: ClientSurface<Hovered>,
  options: { hit: (props: P, x: number, y: number) => Hit<T> | null; click: (props: P, target: T) => JsonValue },
): number {
  latest.set(surface, props)
  if (surface.state === undefined) {
    surface.setState({ hovered: -1 })
    surface.onPointer(event => {
      const now = (latest.get(surface) as P | undefined) ?? props
      const found = event.type === 'leave' ? null : options.hit(now, event.x, event.y)
      if (event.type === 'down' && event.button === 'left' && found?.target !== undefined) {
        surface.post(options.click(now, found.target))
        return
      }
      const hovered = found?.hovered ?? -1
      if ((surface.state?.hovered ?? -1) !== hovered) surface.setState({ hovered })
    })
  }
  return surface.state?.hovered ?? -1
}
