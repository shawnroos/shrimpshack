import type { ClientModule, JsonValue } from 'claude-code'
import { bandLayout, drawBand, moveSelection, selectionAt } from './band.tsx'
import type { BandProps, BandSelection } from './band.tsx'

type State = { clicked: boolean }

let seen: JsonValue | undefined
let band: BandProps | undefined

function layoutOf(props: BandProps) {
  return bandLayout(props.work, props.columns, props.selection, props.maxLines)
}

const BandKeys: ClientModule<JsonValue, State> = (props, surface) => {
  if (props !== seen) {
    seen = props
    band = props as unknown as BandProps
  }
  const pick = (next: Required<BandSelection> | undefined) => {
    if (!band || !next) return
    band = { ...band, selection: next }
    surface.post({ select: next })
  }
  if (surface.state === undefined) {
    surface.onPointer(event => {
      if (event.type !== 'down' || !band) return
      if (!surface.state?.clicked) surface.setState({ clicked: true })
      pick(selectionAt(layoutOf(band), event.x, event.y))
    })
    // The engine hands keys over only after a click on this region; the guard keeps an unclicked band read-only wherever keys arrive anyway.
    surface.onKey(event => {
      if (!surface.state?.clicked || !band) return
      pick(moveSelection(band.work, band.selection, { key: event.key, shift: event.shift === true }))
    })
    surface.setState({ clicked: false })
  }
  const { Box, Text } = surface.elements
  return band ? drawBand({ Box, Text }, layoutOf(band)) : Text({ children: '' })
}

export default BandKeys
