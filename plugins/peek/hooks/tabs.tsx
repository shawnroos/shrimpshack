import type { ClientModule } from 'claude-code'

import { hoverable, paletteOf } from './hover'
import type { Hovered } from './hover'

type Tab = { id: string; label: string; isOn: boolean }
type Props = { tabs: Tab[]; muted?: boolean }

function tabAt(tabs: readonly Tab[], x: number): number {
  let left = 0
  for (const [index, tab] of tabs.entries()) {
    if (x >= left && x < left + tab.label.length) return index
    left += tab.label.length
  }
  return -1
}

const Tabs: ClientModule<Props, Hovered> = (props, surface) => {
  const { Box, Text } = surface.elements
  const { C } = paletteOf(props.muted)
  const hovered = hoverable(props, surface, {
    hit: (now, x) => {
      const index = tabAt(now.tabs, x)
      return { hovered: index, target: now.tabs[index] }
    },
    click: (_now, tab) => ({ mode: tab.id }),
  })

  return (
    <Box flexDirection="row">
      {props.tabs.map((tab, index) => (
        <Text
          key={`tab-${tab.id}`}
          color={tab.isOn ? C.appBg : index === hovered ? C.accent : C.overlay0}
          backgroundColor={tab.isOn ? C.accent : C.panelBg}
          bold={tab.isOn}
        >
          {tab.label}
        </Text>
      ))}
    </Box>
  )
}

export default Tabs
