import type { ClientModule } from 'claude-code'

import { taskRows } from './lib'
import { C } from './theme'

type Item = { href: string; line: number; isDone: boolean; text: string; depth: number }
type Props = { width: number; items: Item[] }
type State = { hovered: number }

const latest = new WeakMap<object, Props>()

const TaskList: ClientModule<Props, State> = (props, surface) => {
  const { Box, Text } = surface.elements
  const rows = taskRows(props.items, props.width)
  latest.set(surface, props)
  if (surface.state === undefined) {
    surface.setState({ hovered: -1 })
    surface.onPointer(event => {
      const now = latest.get(surface) ?? props
      const row = taskRows(now.items, now.width)[event.y]
      const item = row ? row.item : -1
      if (event.type === 'leave') {
        surface.setState({ hovered: -1 })
        return
      }
      if (event.type === 'down' && event.button === 'left' && row) {
        const target = now.items[row.item]
        if (target) surface.post({ toggle: `${target.href}#task-${target.line}` })
        return
      }
      if ((surface.state?.hovered ?? -1) !== item) surface.setState({ hovered: item })
    })
  }
  const hovered = surface.state?.hovered ?? -1

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
