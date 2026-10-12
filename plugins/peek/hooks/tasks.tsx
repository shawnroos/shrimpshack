import type { ClientModule } from 'claude-code'

import { hoverable, paletteOf } from './hover'
import type { Hovered } from './hover'
import { taskRows } from './measure'

type Item = { href: string; line: number; isDone: boolean; text: string; depth: number }
type Props = { width: number; items: Item[]; muted?: boolean }

const TaskList: ClientModule<Props, Hovered> = (props, surface) => {
  const { Box, Text } = surface.elements
  const { C } = paletteOf(props.muted)
  const rows = taskRows(props.items, props.width)
  const hovered = hoverable(props, surface, {
    hit: (now, _x, y) => {
      const row = taskRows(now.items, now.width)[y]
      return row ? { hovered: row.item, target: now.items[row.item] } : null
    },
    click: (_now, target) => ({ toggle: `${target.href}#task-${target.line}` }),
  })

  return (
    <Box flexDirection="column" width={props.width}>
      {rows.map((row, index) => {
        const item = props.items[row.item]
        if (!item) return null
        const isHot = row.item === hovered
        const color = isHot ? C.accent : item.isDone ? C.overlay0 : C.text
        const box = item.isDone ? '\u{f0135}' : '\u{f0131}'
        return (
          <Text key={`row-${index}`} wrap="truncate-end">
            <Text>{' '.repeat(item.depth * 2)}</Text>
            <Text color={color}>{row.isFirst ? `${box} ` : '  '}</Text>
            <Text color={color} strikethrough={isHot && !item.isDone}>{row.text}</Text>
          </Text>
        )
      })}
    </Box>
  )
}

export default TaskList
