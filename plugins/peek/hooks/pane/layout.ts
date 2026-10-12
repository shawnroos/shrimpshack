import type { NavItem } from './types'

// What a screen drew, for the handlers that act on it: the keyboard order and each item's row, the reader's
// block starts and headings for the jump keys, and the row estimate the next draw scales by.
export type Layout = {
  nav: NavItem[]
  blockStarts: number[]
  blockHeadings: string[]
  estimatedRows: number
}

// A field a screen leaves out keeps the last draw's value: a reader view with nothing to count still hands its
// predecessor's estimate to the next draw, as before.
export type ScreenLayout = Partial<Layout>

export const EMPTY_LAYOUT: Layout = { nav: [], blockStarts: [], blockHeadings: [], estimatedRows: 1 }

export const LIST_CHUNK = 10
export const CARD_ROWS = 5
export const CARD_MIN = 26
export const CARD_GAP = 2
