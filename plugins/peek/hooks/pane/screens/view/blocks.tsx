import { IMAGE_ROWS, imageBox } from '../../../measure'
import { nav } from '../../../navigation'
import type { NavIo } from '../../../navigation'
import { ICON } from '../../../theme'
import { FOOTER_ROWS, PAGE_TOP } from '../../chrome'
import type { ScreenLayout } from '../../layout'
import type { DrawContext } from '../../types'

export type Jumps = { next: () => void; prev: () => void }

export type ViewBody = { body: unknown; jumps: Jumps; position: string; layout: ScreenLayout }

const rowOf = (starts: readonly number[], scale: number, index: number) => PAGE_TOP + (starts[index] ?? 0) * scale

export function blockJumps(ctx: DrawContext, io: NavIo, count: number, prefix: string): Jumps {
  const keys = Array.from({ length: count }, (_, i) => `${prefix}-${i}`)
  const { offset } = ctx
  // The block starts are read when the key is pressed, the scale as the page was drawn.
  const rowAt = (index: number) => rowOf(ctx.layout().blockStarts, ctx.scale, index)
  const jumpTo = (key: string) => void io.scroll({ to: { key }, block: 'start' }).catch(() => undefined)
  return {
    next: () => {
      const found = keys.findIndex((_, i) => rowAt(i) > offset + PAGE_TOP + 1)
      const key = keys[found]
      if (found < 0 || !key) void io.scroll({ to: 'end' }).catch(() => undefined)
      else jumpTo(key)
    },
    prev: () => {
      const found = [...keys.keys()].reverse().find(i => rowAt(i) < offset + PAGE_TOP - 1)
      const key = found === undefined ? undefined : keys[found]
      if (!key) void io.scroll({ to: 'start' }).catch(() => undefined)
      else jumpTo(key)
    },
  }
}

// An embed's content is textWidth - 2 wide; height follows the picture, capped so it fits on screen.
export const pictureRowsOf = (ctx: DrawContext) => Math.max(IMAGE_ROWS, ctx.bodyRows - PAGE_TOP - FOOTER_ROWS - 6)

export const fullWidthOf = (ctx: DrawContext) => (width: number, height: number) => imageBox(width, height, ctx.textWidth - 2, pictureRowsOf(ctx))

export function Embed(ctx: DrawContext, key: string, icon: string, label: string, detail: string, color: string, child: unknown) {
  const { Box, Text, C, textWidth } = ctx
  return (
    <Box key={key} flexDirection="column" width={textWidth} backgroundColor={C.appBg} paddingX={1} paddingY={1}>
      <Box flexDirection="row" width={textWidth - 2}>
        <Text color={color}>{`${icon} `}</Text>
        <Text color={color} bold>{label}</Text>
        <Text color={C.overlay1} wrap="truncate-end">{detail ? ` ${detail}` : ''}</Text>
      </Box>
      <Text color={C.panelBg} wrap="truncate-end">{'─'.repeat(Math.max(1, textWidth - 2))}</Text>
      <Box flexDirection="column" width={textWidth - 2}>
        {child as never}
      </Box>
    </Box>
  )
}

export function DiagramEmbed(ctx: DrawContext, key: string, info: string, text: string) {
  const { Text, C } = ctx
  return Embed(ctx, key, ICON.mermaid, 'DIAGRAM', info, C.mauve, <Text color={C.subtext0}>{text}</Text>)
}

export type Blocks = { drawnParts: unknown[]; partRows: number[]; partHeadings: string[]; note: (rows: number, heading?: string) => void }

export function newBlocks(): Blocks {
  const drawnParts: unknown[] = []
  const partRows: number[] = []
  const partHeadings: string[] = []
  const note = (rows: number, heading = '') => {
    while (partRows.length < drawnParts.length) {
      partRows.push(rows)
      partHeadings.push(heading)
    }
  }
  return { drawnParts, partRows, partHeadings, note }
}

export function settleBlocks(ctx: DrawContext, io: NavIo, { drawnParts, partRows, partHeadings }: Blocks): ViewBody {
  const { Box, textWidth, offset } = ctx
  for (let i = partRows.length; i < drawnParts.length; i++) {
    partRows.push(IMAGE_ROWS)
    partHeadings.push('')
  }
  const blockStarts: number[] = []
  const blockHeadings: string[] = []
  let running = 0
  let lastHeading = ''
  for (const [i, rows] of partRows.entries()) {
    blockStarts.push(running)
    lastHeading = partHeadings[i] || lastHeading
    blockHeadings.push(lastHeading)
    running += rows + 1
  }
  const topBlock = [...blockStarts.keys()].reverse().find(i => rowOf(blockStarts, ctx.scale, i) <= offset + PAGE_TOP + 1) ?? 0
  nav.topBlockKey = `block-${topBlock}`
  const heading = blockHeadings[topBlock] ?? ''
  const maxScroll = Math.max(0, ctx.contentRows - ctx.bodyRows)
  const percent = maxScroll > 0 ? Math.min(100, Math.round((offset / maxScroll) * 100)) : 100
  return {
    body: (
      <Box flexDirection="column" width={textWidth}>
        {drawnParts.map((part, blockIndex) => (
          <Box key={`block-${blockIndex}`} flexDirection="column" marginBottom={1}>
            {part as never}
          </Box>
        ))}
      </Box>
    ),
    jumps: blockJumps(ctx, io, drawnParts.length, 'block'),
    position: `${percent}%${heading ? ` · § ${heading}` : ''}`,
    layout: { blockStarts, blockHeadings, estimatedRows: Math.max(1, running) },
  }
}

export const noJumps = (): Jumps => ({ next: () => {}, prev: () => {} })
