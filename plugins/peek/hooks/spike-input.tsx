import type { ClientModule } from 'claude-code'

type Props = { width: number; height: number }
type State = { last: string }

const SpikeInput: ClientModule<Props, State> = (props, surface) => {
  const { Box, Text } = surface.elements
  if (surface.state === undefined) {
    surface.setState({ last: 'none' })
    surface.onPointer(event => {
      if (event.type !== 'down') return
      const where = `${event.x},${event.y}${event.fine ? ` fine ${event.fine.x.toFixed(2)},${event.fine.y.toFixed(2)}` : ''}`
      surface.setState({ last: where })
      surface.post({ spikeClick: where })
    })
    surface.onKey(event => {
      surface.post({ spikeKey: event.key })
    })
  }
  return (
    <Box width={props.width} height={props.height}>
      <Text>{`click layer · last ${surface.state?.last ?? 'none'}`}</Text>
    </Box>
  )
}

export default SpikeInput
