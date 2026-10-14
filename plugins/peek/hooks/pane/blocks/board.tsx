import type { Item } from '../../views/items'
import { CARD_GAP, CARD_MIN } from '../layout'
import { SectionRule } from '../widgets'
import { countNodes } from './row'
import type { BlockDraw, BlockEnv } from './row'
import { drawShelves, shelvesOf } from './sections'
import { treeLines } from './tree'

const boardFits = (columns: number, width: number) => columns * CARD_MIN + Math.max(0, columns - 1) * CARD_GAP <= width

// Columns side by side when each gets a card's width; otherwise the same split stacks as sections.
export function drawBoard(env: BlockEnv, items: readonly Item[], options: Record<string, string>): BlockDraw {
  const { Box } = env.ctx
  const shelves = shelvesOf(env, items, options)
  if (!boardFits(shelves.length, env.width)) return drawShelves(env, shelves)
  const columnWidth = Math.floor((env.width - (shelves.length - 1) * CARD_GAP) / shelves.length)
  const columns = shelves.map(shelf => ({ shelf, lines: treeLines(env, shelf.roots, columnWidth) }))
  return {
    node: (
      <Box key={env.key} flexDirection="row" width={env.width}>
        {columns.map(({ shelf, lines }, index) => [
          ...(index ? [<Box key={`${env.key}-gap-${index}`} width={CARD_GAP} flexShrink={0} />] : []),
          <Box key={`${env.key}-col-${shelf.key}`} flexDirection="column" width={columnWidth} flexShrink={0}>
            {SectionRule(env.ctx, shelf.label, String(countNodes(shelf.roots)), columnWidth, `${env.key}-${shelf.key}-head`)}
            {lines}
          </Box>,
        ])}
      </Box>
    ),
    rows: 1 + Math.max(0, ...columns.map(column => column.lines.length)),
  }
}
