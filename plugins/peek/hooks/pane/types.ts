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

export type HoverItem = { href: string; isStarred?: boolean; inGroup?: string; key?: string } | { group: string; isStarred?: boolean }

export type HoverProps = { kind: 'rows' | 'cards'; width: number; height: number; cardWidth?: number; cardHeight?: number; gap?: number; starX: number; starY: number; items: HoverItem[] }
