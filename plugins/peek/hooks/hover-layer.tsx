import type { ClientModule } from 'claude-code'

import { C } from './theme'

type Item = { href: string; isStarred?: boolean; inGroup?: string; key?: string } | { group: string; isStarred?: boolean }
type Props = { kind: 'rows' | 'cards'; width: number; height: number; items: Item[]; cardWidth?: number; cardHeight?: number; gap?: number; starX: number; starY: number }
type State = { hovered: number }

const latest = new WeakMap<object, Props>()

function itemAt(props: Props, x: number, y: number): { index: number; x: number; y: number } | null {
  if (props.kind === 'rows') return y >= 0 && y < props.items.length ? { index: y, x, y: 0 } : null
  const span = (props.cardWidth ?? 1) + (props.gap ?? 0)
  const index = Math.floor(x / span)
  const inside = x - index * span
  const isInCard = inside < (props.cardWidth ?? 1) && y >= 0 && y < (props.cardHeight ?? 1)
  return isInCard && index < props.items.length ? { index, x: inside, y } : null
}

// Drawn over the item buttons: transparent except the hovered item's star, and the whole item is the pointer target.
const HoverLayer: ClientModule<Props, State> = (props, surface) => {
  const { Box, Text } = surface.elements
  latest.set(surface, props)
  if (surface.state === undefined) {
    surface.setState({ hovered: -1 })
    surface.onPointer(event => {
      const now = latest.get(surface) ?? props
      const hit = itemAt(now, event.x, event.y)
      if (event.type === 'leave' || !hit) {
        if ((surface.state?.hovered ?? -1) !== -1) surface.setState({ hovered: -1 })
        return
      }
      const item = now.items[hit.index]
      if (event.type === 'down' && event.button === 'left' && item) {
        const isOnStar = hit.y === now.starY && hit.x >= now.starX && hit.x < now.starX + 2
        if ('group' in item) surface.post(isOnStar ? { starGroup: item.group } : { openGroup: item.group })
        else if (isOnStar) surface.post({ star: item.href })
        else surface.post(item.inGroup ? { open: item.href, inGroup: item.inGroup, key: item.key ?? '' } : { open: item.href })
        return
      }
      if ((surface.state?.hovered ?? -1) !== hit.index) surface.setState({ hovered: hit.index })
    })
  }
  const hovered = surface.state?.hovered ?? -1
  const item = props.items[hovered]
  const span = (props.cardWidth ?? 0) + (props.gap ?? 0)
  const left = props.kind === 'rows' ? props.starX : hovered * span + props.starX
  const top = props.kind === 'rows' ? hovered : props.starY
  return (
    <Box width={props.width} height={props.height}>
      {item && (
        <Box position="absolute" top={top} left={left} width={2} height={1}>
          <Text color={C.accent} backgroundColor={C.surface0}>{item.isStarred ? '\u{f51a}' : '\u{f41e}'}</Text>
        </Box>
      )}
    </Box>
  )
}

export default HoverLayer
