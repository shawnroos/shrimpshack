import type { ClientModule } from 'claude-code'

type Input = { type: 'click'; x: number; y: number } | { type: 'key'; key: string; ctrl?: boolean; meta?: boolean }
type Pending = Input & { seq: number }
type Props = { width: number; height: number; acked: number }
type State = { seq: number; pending: Pending[] }

const latest = new WeakMap<object, Props>()

// A later post in the same frame replaces an unsent one, so every post carries all input peek has not acknowledged yet.
const LiveInput: ClientModule<Props, State> = (props, surface) => {
  const { Box } = surface.elements
  latest.set(surface, props)
  const unacked = (state: State) => state.pending.filter(one => one.seq > (latest.get(surface) ?? props).acked)
  const push = (event: Input) => {
    const now = surface.state ?? { seq: props.acked, pending: [] }
    const seq = Math.max(now.seq, (latest.get(surface) ?? props).acked) + 1
    const pending = [...unacked(now), { ...event, seq }]
    surface.setState({ seq, pending })
    surface.post({ liveInput: pending })
  }
  if (surface.state === undefined) {
    surface.setState({ seq: props.acked, pending: [] })
    surface.onPointer(event => {
      if (event.type === 'down' && event.button === 'left') push({ type: 'click', x: event.x, y: event.y })
    })
    surface.onKey(event => push({ type: 'key', key: event.key, ...(event.ctrl ? { ctrl: true } : {}), ...(event.meta ? { meta: true } : {}) }))
  }
  return <Box width={props.width} height={props.height} />
}

export default LiveInput
