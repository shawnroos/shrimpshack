import type { ClientModule } from 'claude-code'

import { C as BASE, MUTED, mute } from './theme'

type Row = { href: string; icon: string; color: string; name: string; folder: string; meta: string; isStarred?: boolean; canStar?: boolean }
type Props = { width: number; rows: Row[]; selected?: number; muted?: boolean }
type State = { hovered: number }

const latest = new WeakMap<object, Props>()

const Rows: ClientModule<Props, State> = (props, surface) => {
  const { Box, Text } = surface.elements
  const C = props.muted ? MUTED : BASE
  const tone = (color: string) => (props.muted ? mute(color) : color)
  latest.set(surface, props)
  if (surface.state === undefined) {
    surface.setState({ hovered: -1 })
    surface.onPointer(event => {
      const now = latest.get(surface) ?? props
      const row = now.rows[event.y]
      if (event.type === 'leave' || !row) {
        if ((surface.state?.hovered ?? -1) !== -1) surface.setState({ hovered: -1 })
        return
      }
      if (event.type === 'down' && event.button === 'left') {
        surface.post(event.x < 2 && row.canStar !== false ? { star: row.href } : { open: row.href })
        return
      }
      if ((surface.state?.hovered ?? -1) !== event.y) surface.setState({ hovered: event.y })
    })
  }
  const hovered = surface.state?.hovered ?? -1

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
