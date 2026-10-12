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
