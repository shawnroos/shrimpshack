import type { NavItem } from './types'

// What a screen drew, for the handlers that act on it: the keyboard order and each item's row, the reader's
// block starts and headings for the jump keys, and the row estimate the next draw scales by.
export type Layout = {
  nav: NavItem[]
  // Set by a group page, whose selection is kept as the open group's item: the row it drew selected, which
  // stands while that item is not among its rows.
  group?: { id: string; selected: number }
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

type Placed = Omit<NavItem, 'line' | 'col'>

export const chunked = <T>(items: readonly T[], size: number) => Array.from({ length: Math.ceil(items.length / size) }, (_, i) => items.slice(i * size, i * size + size))

// Lays a list screen out top to bottom. Each call draws its nodes through the callback and, in the same step,
// adds their keyboard order, block starts and rows, so the counts cannot drift from what is drawn. `first` is
// the nav index of a part's first item.
export function layoutBuilder() {
  const nav: NavItem[] = []
  const blockStarts: number[] = []
  let rows = 0
  let line = 0
  return {
    nav: nav as readonly NavItem[],
    space(count: number) {
      rows += count
    },
    // A section rule and a blank row over the body, then one row after it.
    section<N>(body: () => N): N {
      rows += 2
      const drawn = body()
      rows += 1
      return drawn
    },
    // Cards `perRow` to a row, each row CARD_ROWS tall and a gap: one keyboard line and one block per row.
    grid<T, N>(items: readonly T[], perRow: number, place: (one: T, row: number) => Placed, draw: (row: readonly T[], r: number, first: number) => N): N[] {
      return chunked(items, perRow).map((row, r) => {
        const first = nav.length
        const at = line++
        blockStarts.push(rows)
        row.forEach((one, col) => nav.push({ ...place(one, r), line: at, col }))
        rows += CARD_ROWS + 1
        return draw(row, r, first)
      })
    },
    // One row and one keyboard line per item, `chunk` items to a block.
    list<T, N>(items: readonly T[], chunk: number, place: (one: T, part: number) => Placed, draw: (part: readonly T[], p: number, first: number) => N): N[] {
      return chunked(items, chunk).map((part, p) => {
        const first = nav.length
        blockStarts.push(rows)
        for (const one of part) nav.push({ ...place(one, p), line: line++, col: 0 })
        rows += part.length
        return draw(part, p, first)
      })
    },
    // Rows of one line each that the jump keys do not stop at.
    lines<T, N>(items: readonly T[], place: (one: T, index: number) => Placed, draw: (one: T, index: number) => N): N[] {
      return items.map(one => {
        const index = nav.length
        nav.push({ ...place(one, index), line: line++, col: 0 })
        rows += 1
        return draw(one, index)
      })
    },
    // Boxes already drawn and measured, such as group cards: one keyboard line and one block each.
    measured(items: readonly { rows: number; place: Placed }[]) {
      for (const one of items) {
        blockStarts.push(rows)
        nav.push({ ...one.place, line: line++, col: 0 })
        rows += one.rows
      }
    },
    done(): Pick<Layout, 'nav' | 'blockStarts' | 'estimatedRows'> {
      return { nav, blockStarts, estimatedRows: Math.max(1, rows) }
    },
  }
}

export type LayoutBuilder = ReturnType<typeof layoutBuilder>

// Counts a box's rows where its JSX is written: each helper hands back the prop value or node it counts.
export function rowCounter() {
  let rows = 0
  return {
    line<N>(node: N, count = 1): N {
      rows += count
      return node
    },
    margin(count: number) {
      rows += count
      return count
    },
    paddingY(count: number) {
      rows += 2 * count
      return count
    },
    get rows() {
      return rows
    },
  }
}
