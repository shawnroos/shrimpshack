import type { RenderChildren } from 'claude-code'

import { chunked, CARD_GAP, CARD_MIN, CARD_ROWS } from '../layout'
import { fitRow } from '../../measure'
import { order } from '../../views/select'
import type { Item } from '../../views/items'
import { claimRow, glyphOf, rightParts } from './row'
import type { BlockDraw, BlockEnv } from './row'

// A card is CARD_ROWS tall: a blank row, name, creator and due, flag, a blank row; card rows sit a row apart.
export function drawCards(env: BlockEnv, items: readonly Item[]): BlockDraw {
  const { Box, Text, Button, C } = env.ctx
  const perRow = Math.max(1, Math.floor((env.width + CARD_GAP) / (CARD_MIN + CARD_GAP)))
  const cardWidth = Math.floor((env.width - (perRow - 1) * CARD_GAP) / perRow)
  const room = cardWidth - 2
  const card = (item: Item): RenderChildren => {
    const row = claimRow(env, item, false)
    const { glyph, color } = glyphOf(env, item)
    const parts = rightParts(item)
    const meta = parts.filter(one => !one.keep).map(one => one.text).join(' · ')
    const flag = parts.some(one => one.keep) ? '⚑ missing props' : ' '
    return (
      <Box key={row.key} flexDirection="column" width={cardWidth} height={CARD_ROWS} paddingX={1} paddingY={1} flexShrink={0} backgroundColor={row.isSelected ? C.surface0 : C.cardBg}>
        <Box flexDirection="row" height={1} overflow="hidden">
          <Text color={color}>{`${glyph} `}</Text>
          <Button key={row.buttonKey} label={fitRow(item.name, [], room - 2).name} plain {...(row.isSelected ? { autoFocus: true } : {})} onPress={() => env.open(item.href)} />
        </Box>
        <Text color={C.overlay0} wrap="truncate-end">{meta ? fitRow(meta, [], room).name : ' '}</Text>
        <Text color={C.red} wrap="truncate-end">{fitRow(flag, [], room).name}</Text>
      </Box>
    )
  }
  const rows = chunked(order(items).items, perRow)
  return {
    node: (
      <Box key={env.key} flexDirection="column" width={env.width}>
        {rows.map((line, r) => (
          <Box key={`${env.key}-cards-${r}`} flexDirection="row" marginBottom={r < rows.length - 1 ? 1 : 0}>
            {line.map((item, c) => [...(c ? [<Box key={`${env.key}-gap-${r}-${c}`} width={CARD_GAP} flexShrink={0} />] : []), card(item)])}
          </Box>
        ))}
      </Box>
    ),
    rows: rows.length * CARD_ROWS + Math.max(0, rows.length - 1),
  }
}
