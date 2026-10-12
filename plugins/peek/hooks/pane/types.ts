import type { BoxProps, ButtonProps, ClientProps, ElementConstructor, ImageProps, TextProps } from 'claude-code'

import type { MUTED } from '../theme'

export type Palette = typeof MUTED

export type WidgetCtx = {
  Box: ElementConstructor<BoxProps>
  Text: ElementConstructor<TextProps>
  Button: ElementConstructor<ButtonProps>
  Image?: ElementConstructor<ImageProps>
  Client?: ElementConstructor<ClientProps>
  C: Palette
}
