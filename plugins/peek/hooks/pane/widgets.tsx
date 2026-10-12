import { fitName } from '../measure'
import type { ItemLook } from './look'
import type { HoverProps, PictureBudget, WidgetCtx } from './types'

// The engine refuses a whole pane whose Image sources pass 2097152 bytes; past this budget a picture shows as a link.
const IMAGE_TREE_BUDGET = 1_900_000

export function SectionRule(ctx: WidgetCtx, label: string, right: string, width: number, key?: string) {
  const { Text, C } = ctx
  const head = `${label} `
  const tail = right ? ` ${right}` : ''
  return (
    <Text {...(key === undefined ? {} : { key })} wrap="truncate-end">
      <Text color={C.accent} bold>{head}</Text>
      <Text color={C.surface1}>{'─'.repeat(Math.max(1, width - head.length - tail.length))}</Text>
      <Text color={C.overlay0}>{tail}</Text>
    </Text>
  )
}

// An absolute Box paints over the siblings before it, so the caller draws this as its parent's last child.
export function HoverLayer(ctx: WidgetCtx, key: string, props: HoverProps) {
  const { Box, Client } = ctx
  return (
    Client && (
      <Box position="absolute" top={0} left={0} width={props.width} height={props.height}>
        <Client key={key} module="../hover-layer.tsx" props={props} width={props.width} height={props.height} />
      </Box>
    )
  )
}

export function fitPicture(budget: PictureBudget, png: string | undefined): string | undefined {
  if (!png || budget.used + png.length > IMAGE_TREE_BUDGET) return undefined
  budget.used += png.length
  return png
}

export type IconSlot = {
  isStarred: boolean
  png?: string
  icon: string
  imageKey: string
  buttonKey: string
  autoFocus?: true
  onPress: () => void
  boxes?: { image?: string; button?: string }
}

const keyed = (key: string | undefined) => (key === undefined ? {} : { key })

// Returns the image and the button as two siblings; `boxes` wraps each in a non-shrinking Box (keyed when given).
export function ItemIcon(ctx: WidgetCtx, slot: IconSlot) {
  const { Box, Button, Image } = ctx
  const boxes = slot.boxes
  const picture = slot.png && !slot.isStarred && Image && <Image key={slot.imageKey} source={{ png: slot.png }} columns={2} rows={1} alt={slot.icon} />
  const button = <Button key={slot.buttonKey} label={slot.isStarred ? '\u{f51a}' : slot.png ? ' ' : slot.icon} plain autoFocus={slot.autoFocus} onPress={slot.onPress} />
  return [
    picture && (boxes ? <Box {...keyed(boxes.image)} flexShrink={0}>{picture}</Box> : picture),
    boxes ? <Box {...keyed(boxes.button)} flexShrink={0}>{button}</Box> : button,
  ]
}

export type RowSpec = {
  key: string
  width: number
  isSelected: boolean
  icon: IconSlot
  nameKey: string
  nameColor: string
  meta: string
  metaColor: string
  metaKey?: string
}

export function ItemRow(ctx: WidgetCtx, look: ItemLook, row: RowSpec) {
  const { Box, Text, C } = ctx
  const leftWidth = Math.max(4, row.width - row.meta.length - 1)
  const nameRoom = Math.max(8, Math.floor((leftWidth - 3) * 0.6))
  return (
    <Box
      key={row.key}
      height={1}
      flexDirection="row"
      justifyContent="space-between"
      width={row.width}
      backgroundColor={row.isSelected ? C.surface0 : undefined}
      hover={{ backgroundColor: C.surface0 }}
    >
      <Box flexDirection="row" width={leftWidth} height={1} overflow="hidden">
        {...ItemIcon(ctx, row.icon)}
        <Box key={row.nameKey} flexShrink={0}>
          <Text color={row.nameColor} bold={row.isSelected} hover={{ color: C.accent }} wrap="truncate-end">{`  ${fitName(look.name, nameRoom)}`}</Text>
        </Box>
        <Box flexShrink={1} flexGrow={1} overflow="hidden">
          <Text color={C.overlay0} wrap="truncate-middle">{look.where ? `  ${look.where}` : ''}</Text>
        </Box>
      </Box>
      <Box {...keyed(row.metaKey)} flexShrink={0} height={1}>
        <Text color={row.metaColor}>{row.meta}</Text>
      </Box>
    </Box>
  )
}

export type CardSpec = {
  key: string
  width: number
  height: number
  background: string
  // Clipped: the head row truncates the full name. Otherwise the name is cut to the card's inner width.
  clip: boolean
  icon: IconSlot
  nameKey: string
  nameColor: string
  meta: string
  metaColor: string
}

export function ItemCard(ctx: WidgetCtx, look: ItemLook, card: CardSpec) {
  const { Box, Text, C } = ctx
  return (
    <Box key={card.key} flexDirection="column" width={card.width} height={card.height} paddingX={2} paddingY={1} backgroundColor={card.background} hover={{ backgroundColor: C.surface0 }}>
      <Box flexDirection="row" {...(card.clip ? { height: 1, overflow: 'hidden' as const } : {})}>
        {...ItemIcon(ctx, card.icon)}
        <Box key={card.nameKey} {...(card.clip ? { flexShrink: 1 } : {})}>
          {card.clip ? (
            <Text color={card.nameColor} bold hover={{ color: C.accent }} wrap="truncate-end">{` ${look.name}`}</Text>
          ) : (
            <Text color={card.nameColor} bold hover={{ color: C.accent }}>{` ${look.name.slice(0, Math.max(4, card.width - 7))}`}</Text>
          )}
        </Box>
      </Box>
      <Text color={C.overlay0} wrap="truncate-start">{look.where || ' '}</Text>
      <Text color={card.metaColor} wrap="truncate-end">{card.meta}</Text>
    </Box>
  )
}
