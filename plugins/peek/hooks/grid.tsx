import type { ClientModule } from 'claude-code'

import { C as BASE, MUTED, mute } from './theme'

type Card = { href: string; icon: string; color: string; name: string; folder: string; meta: string; isStarred?: boolean }
type Props = { cardWidth: number; gap: number; cards: Card[]; selected?: number; muted?: boolean }
type State = { hovered: number }

export const CARD_ROWS = 5

const latest = new WeakMap<object, Props>()

function cardAt(props: Props, x: number, y: number): number {
  const span = props.cardWidth + props.gap
  const column = Math.floor(x / span)
  const isInCard = x - column * span < props.cardWidth && y >= 0 && y < CARD_ROWS
  return isInCard && column < props.cards.length ? column : -1
}

// The star sits on the name row, just inside the card's 2-column padding.
function isOnStar(props: Props, x: number, y: number): boolean {
  const inside = x - Math.floor(x / (props.cardWidth + props.gap)) * (props.cardWidth + props.gap)
  return y === 1 && inside >= 2 && inside < 4
}

const Grid: ClientModule<Props, State> = (props, surface) => {
  const { Box, Text } = surface.elements
  const C = props.muted ? MUTED : BASE
  const tone = (color: string) => (props.muted ? mute(color) : color)
  latest.set(surface, props)
  if (surface.state === undefined) {
    surface.setState({ hovered: -1 })
    surface.onPointer(event => {
      const now = latest.get(surface) ?? props
      const index = event.type === 'leave' ? -1 : cardAt(now, event.x, event.y)
      const card = now.cards[index]
      if (event.type === 'down' && event.button === 'left' && card) {
        surface.post(isOnStar(now, event.x, event.y) ? { star: card.href } : { open: card.href })
        return
      }
      if ((surface.state?.hovered ?? -1) !== index) surface.setState({ hovered: index })
    })
  }
  const hovered = surface.state?.hovered ?? -1
  const inner = Math.max(4, props.cardWidth - 4)

  return (
    <Box flexDirection="row" columnGap={props.gap}>
      {props.cards.map((card, index) => {
        const isSelected = index === props.selected
        const isHot = index === hovered || isSelected
        return (
          <Box
            key={`card-${index}`}
            flexDirection="column"
            width={props.cardWidth}
            height={CARD_ROWS}
            paddingX={2}
            paddingY={1}
            backgroundColor={isSelected ? C.surface0 : C.panelBg}
          >
            <Text wrap="truncate-end">
              {card.isStarred || isHot ? (
                <Text color={C.accent}>{`${card.isStarred ? '\u{f51a}' : '\u{f41e}'} `}</Text>
              ) : (
                <Text color={tone(card.color)}>{`${card.icon} `}</Text>
              )}
              <Text color={isHot ? C.accent : C.text} bold>{card.name.slice(0, inner)}</Text>
            </Text>
            <Text color={C.overlay0} wrap="truncate-start">{card.folder || ' '}</Text>
            <Text wrap="truncate-end">
              <Text color={isHot ? C.overlay1 : C.overlay0}>{card.meta}</Text>
            </Text>
          </Box>
        )
      })}
    </Box>
  )
}

export default Grid
