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
