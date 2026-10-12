import type { BoxProps, ButtonProps, ClientProps, CodeProps, ElementConstructor, ImageProps, InputProps, MarkdownProps, PluginState, RenderSurface, TextProps } from 'claude-code'

import type { Mode, View } from '../../types'
import type { GroupMenuFor } from '../groups-session'
import type { Cell, NavIo } from '../navigation'
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

export type PictureBudget = { used: number }

type PaneState = PluginState['peek']

export type DrawContext = WidgetCtx & {
  Markdown: ElementConstructor<MarkdownProps>
  Code: ElementConstructor<CodeProps>
  Input?: ElementConstructor<InputProps>
  surface: RenderSurface
  isMenuOpen: boolean
  current: View | null
  chosen: Mode
  list: PaneState['mentions']
  filter: string
  now: number
  cwd: string
  home: string
  offset: number
  bodyColumns: number
  bodyRows: number
  columns: number
  isNarrow: boolean
  textWidth: number
  pageWidth: number
  // From the previous draw's row estimate, taken before this draw's screen replaces it.
  scale: number
}

export type NavItem = { href: string; key: string; line: number; col: number; group?: string }

export type Direction = 'up' | 'down' | 'left' | 'right'

export type PaneActions = {
  io: NavIo
  scope: Cell<PaneState['scope']>
  roleFilter: Cell<PaneState['roleFilter']>
  galleryType: Cell<PaneState['galleryType']>
  gallerySort: Cell<PaneState['gallerySort']>
  galleryFilter: Cell<PaneState['galleryFilter']>
  moveSelection: (direction: Direction) => Promise<void>
  selectAndOpen: (index: number) => Promise<void>
  selectedNav: () => Promise<NavItem | undefined>
  openNav: (one: NavItem | undefined) => Promise<void>
  close: () => Promise<unknown>
}

export type Key = { key: string; label: string; hotkey: string; onPress: () => void; menu?: string }

export type Crumb = { label: string; fg: string; bg: string; bold?: boolean; canShrink?: boolean }

export type Screen = { crumbs: Crumb[]; content: unknown; info: string; keys: Key[]; menuOn?: GroupMenuFor; pageBg?: string }
