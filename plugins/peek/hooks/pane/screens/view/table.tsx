import type { View } from '../../../../types'
import type { NavIo } from '../../../navigation'
import { columnWidths, fitCell } from '../../../tabular'
import { PAGE_TOP } from '../../chrome'
import { LIST_CHUNK, chunked } from '../../layout'
import type { DrawContext } from '../../types'
import { blockJumps } from './blocks'
import type { ViewBody } from './blocks'

export function tableBody(ctx: DrawContext, io: NavIo, table: NonNullable<View['table']>): ViewBody {
  const { Box, Text, C, textWidth, offset } = ctx
  const widths = columnWidths([table.header, ...table.rows], textWidth)
  const line = (row: readonly string[]) => widths.map((width, c) => fitCell(row[c] ?? '', width)).join('  ')
  const chunks = chunked(table.rows, LIST_CHUNK)
  const body = (
    <Box flexDirection="column" width={textWidth}>
      <Text color={C.accent} bold wrap="truncate-end">{line(table.header)}</Text>
      <Text color={C.surface1} wrap="truncate-end">{widths.map(width => '─'.repeat(width)).join('  ')}</Text>
      {chunks.map((chunk, i) => (
        <Box key={`chunk-${i}`} flexDirection="column">
          {chunk.map((row, r) => (
            <Text
              key={`table-row-${i * LIST_CHUNK + r}`}
              color={C.text}
              backgroundColor={(i * LIST_CHUNK + r) % 2 ? C.cardBg : undefined}
              wrap="truncate-end"
            >
              {line(row)}
            </Text>
          ))}
        </Box>
      ))}
      {table.total > table.rows.length && (
        <Text color={C.overlay0}>{`… ${table.total - table.rows.length} more rows. Press o to open the whole file.`}</Text>
      )}
    </Box>
  )
  const jumps = blockJumps(ctx, io, chunks.length, 'chunk')
  const first = Math.max(1, Math.min(table.rows.length, offset - PAGE_TOP - 1))
  return { body, jumps, position: `row ${first} of ${table.total}`, layout: { blockStarts: chunks.map((_, i) => 2 + i * LIST_CHUNK), estimatedRows: Math.max(1, 2 + table.rows.length) } }
}
