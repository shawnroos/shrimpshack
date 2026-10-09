import type { ClientModule } from 'claude-code'

import { C as BASE, MUTED, mute } from './theme'

type Tab = { id: string; label: string; isOn: boolean }
type Props = { tabs: Tab[]; muted?: boolean }
type State = { hovered: number }

const latest = new WeakMap<object, Props>()

function tabAt(tabs: readonly Tab[], x: number): number {
  let left = 0
  for (const [index, tab] of tabs.entries()) {
    if (x >= left && x < left + tab.label.length) return index
    left += tab.label.length
  }
  return -1
}

const Tabs: ClientModule<Props, State> = (props, surface) => {
  const { Box, Text } = surface.elements
  const C = props.muted ? MUTED : BASE
  const tone = (color: string) => (props.muted ? mute(color) : color)
  latest.set(surface, props)
  if (surface.state === undefined) {
    surface.setState({ hovered: -1 })
    surface.onPointer(event => {
      const now = latest.get(surface) ?? props
      const index = event.type === 'leave' ? -1 : tabAt(now.tabs, event.x)
      const tab = now.tabs[index]
      if (event.type === 'down' && event.button === 'left' && tab) {
        surface.post({ mode: tab.id })
        return
      }
      if ((surface.state?.hovered ?? -1) !== index) surface.setState({ hovered: index })
    })
  }
  const hovered = surface.state?.hovered ?? -1

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
