import type { NavItem } from './types'

// Screens write this while drawing and the move, focus and scroll hooks read it; only module state, never UI state.
export const layout = {
  navOrder: [] as NavItem[],
  blockStarts: [] as number[],
  blockHeadings: [] as string[],
  estimatedRows: 1,
  contentRows: 0,
}
