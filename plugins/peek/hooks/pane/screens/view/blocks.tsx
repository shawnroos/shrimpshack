import type { RenderChildren } from 'claude-code'

import type { ListItem, TablePart } from '../../../markdown'
import { IMAGE_ROWS, imageBox } from '../../../measure'
import { columnWidths, fitCell, fitsWidth } from '../../../tabular'
import { nav } from '../../../navigation'
import type { NavIo } from '../../../navigation'
import { ICON } from '../../../theme'
import { FOOTER_ROWS, PAGE_TOP } from '../../chrome'
import type { ScreenLayout } from '../../layout'
import type { BlockNav } from '../../blocks/row'
import type { DrawContext } from '../../types'

export type Jumps = { next: () => void; prev: () => void }

export type ViewBody = { body: RenderChildren; jumps: Jumps; position: string; layout: ScreenLayout }

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

export function Embed(ctx: DrawContext, key: string, icon: string, label: string, detail: string, color: string, child: RenderChildren) {
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
        {child}
      </Box>
    </Box>
  )
}

export function DiagramEmbed(ctx: DrawContext, key: string, info: string, text: string) {
  const { Text, C } = ctx
  return Embed(ctx, key, ICON.mermaid, 'DIAGRAM', info, C.mauve, <Text color={C.subtext0}>{text}</Text>)
}

// A table whose columns cannot all show in full stacks each row as label/value
// lines, so a narrow pane wraps cells instead of cutting them.
export function TableBlock(ctx: DrawContext, key: string, { header, align, rows }: TablePart, width = ctx.textWidth): { node: RenderChildren; rows: number } {
  const { Box, Text, C, isMenuOpen } = ctx
  const ink = isMenuOpen ? C.overlay1 : C.text
  if (!fitsWidth([header, ...rows], width)) {
    const labelWidth = Math.min(Math.max(...header.map(name => name.length)) + 2, Math.floor(width / 3))
    const valueWidth = Math.max(1, width - labelWidth)
    const node = (
      <Box key={key} flexDirection="column" width={width}>
        {rows.map((row, r) => (
          <Box key={`${key}-card-${r}`} flexDirection="column">
            {r > 0 && <Text color={C.surface1} wrap="truncate-end">{'─'.repeat(width)}</Text>}
            {header.map((name, c) => (
              <Box key={`${key}-card-${r}-${c}`} flexDirection="row">
                <Box width={labelWidth} flexShrink={0}>
                  <Text color={C.accent} bold wrap="truncate-end">{name}</Text>
                </Box>
                <Box width={valueWidth}>
                  <Text color={ink}>{row[c] || ' '}</Text>
                </Box>
              </Box>
            ))}
          </Box>
        ))}
      </Box>
    )
    const lines = rows.reduce((sum, row) => sum + header.reduce((cells, _, c) => cells + Math.max(1, Math.ceil((row[c] ?? '').length / valueWidth)), 0), 0)
    return { node, rows: lines + Math.max(0, rows.length - 1) }
  }
  const widths = columnWidths([header, ...rows], width)
  const line = (row: readonly string[]) => widths.map((cell, c) => fitCell(row[c] ?? '', cell, align[c])).join('  ')
  const node = (
    <Box key={key} flexDirection="column" width={width}>
      <Text color={C.accent} bold wrap="truncate-end">{line(header)}</Text>
      <Text color={C.surface1} wrap="truncate-end">{widths.map(cell => '─'.repeat(cell)).join('  ')}</Text>
      {rows.map((row, r) => (
        <Text key={`${key}-row-${r}`} color={ink} backgroundColor={r % 2 ? C.cardBg : undefined} wrap="truncate-end">
          {line(row)}
        </Text>
      ))}
    </Box>
  )
  return { node, rows: 2 + rows.length }
}

const LIST_GLYPH = { bullet: '\u23f5 ', open: '\u{f0131} ', done: '\u{f0135} ' } as const

export function ListBlock(ctx: DrawContext, key: string, items: readonly ListItem[], onLink: (href: string) => void, width = ctx.textWidth): { node: RenderChildren; rows: number } {
  const { Box, Text, Markdown, C, isMenuOpen } = ctx
  const node = (
    <Box key={key} flexDirection="column" width={width}>
      {items.map((item, i) => {
        const isDone = item.marker === 'done'
        return (
          <Box key={`${key}-item-${i}`} flexDirection="row" marginLeft={item.depth * 2}>
            <Text color={isDone ? C.overlay0 : C.accent}>{LIST_GLYPH[item.marker]}</Text>
            <Box flexShrink={1}>
              <Markdown dimColor={isMenuOpen || isDone} key={`${key}-text-${i}`} text={isDone ? `~~${item.text}~~` : item.text} onLinkPress={link => onLink(link.href)} />
            </Box>
          </Box>
        )
      })}
    </Box>
  )
  const rows = items.reduce((sum, item) => sum + Math.max(1, Math.ceil(item.text.length / Math.max(10, width - 2 - item.depth * 2))), 0)
  return { node, rows }
}

// `nav` holds the page's selectable block rows, in drawn order, for the keyboard.
export type Blocks = { drawnParts: RenderChildren[]; partRows: number[]; partHeadings: string[]; nav: BlockNav[]; note: (rows: number, heading?: string) => void }

export function newBlocks(): Blocks {
  const drawnParts: RenderChildren[] = []
  const partRows: number[] = []
  const partHeadings: string[] = []
  const nav: BlockNav[] = []
  const note = (rows: number, heading = '') => {
    while (partRows.length < drawnParts.length) {
      partRows.push(rows)
      partHeadings.push(heading)
    }
  }
  return { drawnParts, partRows, partHeadings, nav, note }
}

export function settleBlocks(ctx: DrawContext, io: NavIo, { drawnParts, partRows, partHeadings, nav: rows }: Blocks): ViewBody {
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
            {part}
          </Box>
        ))}
      </Box>
    ),
    jumps: blockJumps(ctx, io, drawnParts.length, 'block'),
    position: `${percent}%${heading ? ` · § ${heading}` : ''}`,
    layout: { blockStarts, blockHeadings, estimatedRows: Math.max(1, running), nav: rows.map((one, line) => ({ ...one, line, col: 0 })) },
  }
}

export const noJumps = (): Jumps => ({ next: () => {}, prev: () => {} })
