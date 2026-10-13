import type { ClientModule } from 'claude-code'

import { hoverable, paletteOf } from './hover'
import type { Hovered } from './hover'
import type { PaneWire } from './pane/messages'

export type CrumbSegment = { text: string; fg: string; bg: string; bold?: boolean; crumb: number; isEdge?: boolean }
type Props = { segments: CrumbSegment[]; presses: (PaneWire | null)[] }

function crumbAt(segments: readonly CrumbSegment[], x: number): number {
  let left = 0
  for (const one of segments) {
    const width = [...one.text].length
    if (x >= left && x < left + width) return one.crumb
    left += width
  }
  return -1
}

const Crumbs: ClientModule<Props, Hovered> = (props, surface) => {
  const { Box, Text } = surface.elements
  const { C } = paletteOf(false)
  const hovered = hoverable(props, surface, {
    hit: (now, x) => {
      const index = crumbAt(now.segments, x)
      const press = now.presses[index]
      return press ? { hovered: index, target: press } : { hovered: -1 }
    },
    click: (_now, press) => press,
  })
  return (
    <Box flexDirection="row">
      {props.segments.map((one, i) => (
        <Text
          key={`crumb-seg-${i}`}
          color={!one.isEdge && one.crumb === hovered ? C.accent : one.fg}
          backgroundColor={one.bg}
          bold={one.bold}
          underline={!one.isEdge && one.crumb === hovered}
        >
          {one.text}
        </Text>
      ))}
    </Box>
  )
}

export default Crumbs
