import type { ClientModule } from 'claude-code'

type TickerState = { frame: number; position: number; keys: number; lastKey: string }

const SPINNER = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']

const Ticker: ClientModule<{ width: number }, TickerState> = (props, surface) => {
  const { Box, Text } = surface.elements
  const width = Math.max(10, props.width)
  if (surface.state === undefined) {
    const start: TickerState = { frame: 0, position: 0, keys: 0, lastKey: '—' }
    surface.setState(start)
    surface.every(120, () => {
      const now = surface.state ?? start
      surface.setState({ ...now, frame: now.frame + 1 })
    })
    surface.onKey(event => {
      const now = surface.state ?? start
      const step = event.key === 'left' ? -1 : event.key === 'right' ? 1 : 0
      surface.setState({
        ...now,
        keys: now.keys + 1,
        lastKey: event.key,
        position: Math.min(width - 1, Math.max(0, now.position + step)),
      })
    })
  }
  const state = surface.state ?? { frame: 0, position: 0, keys: 0, lastKey: '—' }
  const track = Array.from({ length: width }, (_, index) => (index === state.position ? '●' : '·')).join('')

  return (
    <Box flexDirection="column">
      <Text>
        <Text color="cyan">{SPINNER[state.frame % SPINNER.length]}</Text> frame {state.frame} · keys {state.keys} · last{' '}
        <Text bold>{state.lastKey}</Text>
      </Text>
      <Text color="yellow">{track}</Text>
      <Text dimColor>Click here, then ← → move the dot. Esc gives the keys back.</Text>
    </Box>
  )
}

export default Ticker
