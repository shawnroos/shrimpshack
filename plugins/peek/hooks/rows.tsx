import type { ClientModule } from 'claude-code'

import { hoverable, paletteOf } from './hover'
import type { Hovered } from './hover'

type Row = { href: string; icon: string; color: string; name: string; folder: string; meta: string; isStarred?: boolean; canStar?: boolean }
type Props = { width: number; rows: Row[]; selected?: number; muted?: boolean }

const Rows: ClientModule<Props, Hovered> = (props, surface) => {
  const { Box, Text } = surface.elements
  const { C, tone } = paletteOf(props.muted)
  const hovered = hoverable(props, surface, {
    hit: (now, x, y) => {
      const row = now.rows[y]
      return row ? { hovered: y, target: { row, x } } : null
    },
    click: (_now, { row, x }) => (x < 2 && row.canStar !== false ? { star: row.href } : { open: row.href }),
  })

  return (
    <Box flexDirection="column" width={props.width}>
      {props.rows.map((row, index) => {
        const isSelected = index === props.selected
        const isHot = index === hovered || isSelected
        const room = Math.max(4, props.width - row.meta.length - 1)
        return (
          <Box
            key={`row-${index}`}
            flexDirection="row"
            justifyContent="space-between"
            width={props.width}
            backgroundColor={isSelected ? C.surface0 : undefined}
          >
            <Box width={room}>
              <Text wrap="truncate-end">
                {row.canStar !== false && (row.isStarred || isHot) ? (
                  <Text color={C.accent}>{`${row.isStarred ? '\u{f51a}' : '\u{f41e}'}  `}</Text>
                ) : (
                  <Text color={tone(row.color)}>{`${row.icon}  `}</Text>
                )}
                <Text color={isHot ? C.accent : C.text} bold={isHot}>{row.name}</Text>
                <Text color={C.overlay0}>{row.folder ? `  ${row.folder}` : ''}</Text>
              </Text>
            </Box>
            <Text color={C.overlay0}>{row.meta}</Text>
          </Box>
        )
      })}
    </Box>
  )
}

export default Rows
