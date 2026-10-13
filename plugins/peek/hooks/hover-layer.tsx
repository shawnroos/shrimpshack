import type { ClientModule } from 'claude-code'

import { hoverable } from './hover'
import type { Hovered } from './hover'
import type { PaneWire } from './pane/messages'
import type { HoverItem, HoverProps } from './pane/types'
import { C, ICON } from './theme'

type Spot = { index: number; x: number; y: number }

function itemAt(props: HoverProps, x: number, y: number): Spot | null {
  if (props.kind === 'rows') return y >= 0 && y < props.items.length ? { index: y, x, y: 0 } : null
  const span = props.cardWidth + props.gap
  const index = Math.floor(x / span)
  const inside = x - index * span
  const isInCard = inside < props.cardWidth && y >= 0 && y < props.cardHeight
  return isInCard && index < props.items.length ? { index, x: inside, y } : null
}

function message(props: HoverProps, { item, spot }: { item: HoverItem; spot: Spot }): PaneWire {
  const isOnStar = spot.y === props.starY && spot.x >= props.starX && spot.x < props.starX + 2
  if ('group' in item) return isOnStar ? { starGroup: item.group } : { openGroup: item.group }
  if (isOnStar) return { star: item.href }
  return item.inGroup ? { open: item.href, inGroup: item.inGroup, key: item.key ?? '' } : { open: item.href }
}

// Drawn over the item buttons: transparent except the hovered item's star, and the whole item is the pointer target.
// Mount it as the last child of its parent: an absolute Box paints under every sibling after it, which hides the star.
const HoverLayer: ClientModule<HoverProps, Hovered> = (props, surface) => {
  const { Box, Text } = surface.elements
  const hovered = hoverable(props, surface, {
    hit: (now, x, y) => {
      const spot = itemAt(now, x, y)
      if (!spot) return null
      const item = now.items[spot.index]
      return { hovered: spot.index, target: item && { item, spot } }
    },
    click: message,
  })
  const item = props.items[hovered]
  const left = props.kind === 'rows' ? props.starX : hovered * (props.cardWidth + props.gap) + props.starX
  const top = props.kind === 'rows' ? hovered : props.starY
  return (
    <Box width={props.width} height={props.height}>
      {item && (
        <Box position="absolute" top={top} left={left} width={2} height={1}>
          <Text color={C.accent} backgroundColor={C.surface0}>{item.isStarred ? ICON.star : ICON.unstarred}</Text>
        </Box>
      )}
    </Box>
  )
}

export default HoverLayer
