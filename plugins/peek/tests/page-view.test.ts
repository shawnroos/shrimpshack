import { describe, expect, test } from 'claude-code/testing'

import { columnWidths, fitCell } from '../hooks/lib'
import { validatePage } from '../hooks/page'
import type { Block, CardItem, ListItem, Page } from '../hooks/page'
import { EMPTY_PAGE, EMPTY_SECTION, PAGE_MEDIA_BASE, drawPage } from '../hooks/page-view'
import type { PageItemLook, PageNavSink, PageWriters } from '../hooks/page-view'

type Node = { el?: string; children?: unknown[]; [prop: string]: unknown }
type Log = {
  blockSets: number
  rules: string[]
  media: { index: number; alt: string; url: string; heading: string }[]
  markdown: { key: string; text: string; heading: string }[]
  cardLooks: PageItemLook[]
  rowLooks: PageItemLook[]
  opened: string[]
  copied: string[]
  notices: string[]
  picked: number[]
}

const WIDTH = 60
const CARD_ROWS = 5
const STARRED = 'https://figma.com/file/starred'
const BUDGET = 10

const element = (el: string) => (props: Record<string, unknown>) => ({ el, ...props })

function fakeWriters(): { writers: PageWriters; log: Log } {
  const log: Log = { blockSets: 0, rules: [], media: [], markdown: [], cardLooks: [], rowLooks: [], opened: [], copied: [], notices: [], picked: [] }
  const writers: PageWriters = {
    elements: { Box: element('Box') as never, Text: element('Text') as never, Button: element('Button') as never },
    colors: { accent: 'accent', text: 'text', subtext0: 'subtext0', overlay0: 'overlay0', overlay1: 'overlay1', surface0: 'surface0', surface1: 'surface1' },
    blocks: ({ drawnParts, note }) => {
      log.blockSets += 1
      let bytes = 0
      return {
        fitsPane: png => {
          if (bytes + png.length > BUDGET) return false
          bytes += png.length
          return true
        },
        sectionRule: (key, label) => {
          log.rules.push(label)
          drawnParts.push({ el: 'rule', key, label })
          note(1, label)
        },
        mediaBlock: (index, alt, url, heading) => {
          log.media.push({ index, alt, url, heading })
          drawnParts.push({ el: 'media', key: `media-${index}`, url })
          note(4, heading)
        },
        markdownBlocks: (key, text, heading) => {
          log.markdown.push({ key, text, heading })
          drawnParts.push({ el: 'markdown', key, text })
          note(2, heading)
        },
      }
    },
    cards: <T,>(sink: PageNavSink, lookOf: (one: T) => PageItemLook) => (items: readonly T[], prefix: string) => {
      const looks = items.map(lookOf)
      log.cardLooks.push(...looks)
      const line = sink.line++
      looks.forEach((look, col) => sink.nav.push({ href: look.href, key: `${prefix}-0`, line, col }))
      sink.keys.push(`${prefix}-0`)
      sink.starts.push(sink.cursor)
      sink.cursor += CARD_ROWS + 1
      return [{ el: 'cards', key: `${prefix}-0`, selected: sink.selected, count: looks.length }]
    },
    rows: <T,>(sink: PageNavSink, lookOf: (one: T) => PageItemLook) => (items: readonly T[], prefix: string) => {
      const looks = items.map(lookOf)
      log.rowLooks.push(...looks)
      for (const look of looks) sink.nav.push({ href: look.href, key: `${prefix}-0`, line: sink.line++, col: 0 })
      sink.keys.push(`${prefix}-0`)
      sink.starts.push(sink.cursor)
      sink.cursor += looks.length
      return [{ el: 'rows', key: `${prefix}-0`, count: looks.length }]
    },
    isStarred: href => href === STARRED,
    picture: url => (url.endsWith('.png') ? 'pppppp' : undefined),
    pick: index => log.picked.push(index),
    open: href => log.opened.push(href),
    copy: text => log.copied.push(text),
    notice: text => log.notices.push(text),
  }
  return { writers, log }
}

function textOf(node: unknown): string {
  if (typeof node === 'string' || typeof node === 'number') return String(node)
  if (Array.isArray(node)) return node.map(textOf).join('')
  if (node && typeof node === 'object') {
    const one = node as Node
    return [one.label, one.text, ...(one.children ?? [])].map(textOf).join('')
  }
  return ''
}

function findAll(node: unknown, match: (one: Node) => boolean, found: Node[] = []): Node[] {
  if (Array.isArray(node)) for (const one of node) findAll(one, match, found)
  else if (node && typeof node === 'object') {
    const one = node as Node
    if (match(one)) found.push(one)
    findAll(one.children, match, found)
  }
  return found
}

const sectionPage = (...blocks: Block[]): Page => ({ title: 'T', sections: blocks.map(block => ({ block })) })
const cards = (n: number): CardItem[] => Array.from({ length: n }, (_, i) => ({ title: `Card ${i}`, meta: `meta ${i}`, href: `https://figma.com/file/c${i}` }))
const draw = (page: Page, selected = 0) => {
  const { writers, log } = fakeWriters()
  return { drawn: drawPage(writers, page, { width: WIDTH, selected }), log }
}

describe('drawPage', () => {
  test('markdown, three cards, a two-row table and fields: focus is the cards then the rows, nothing else', () => {
    const page: Page = {
      title: 'Design review',
      sections: [
        { heading: 'Notes', block: { type: 'markdown', text: 'Some **notes**.' } },
        { heading: 'Frames', block: { type: 'cards', items: cards(3) } },
        { heading: 'Files', block: { type: 'table', columns: ['Name', 'Size'], rows: [{ cells: ['a.fig', '2 MB'], href: 'https://figma.com/file/a' }, { cells: ['b.fig', '1 MB'], href: 'https://figma.com/file/b' }] } },
        { heading: 'Facts', block: { type: 'fields', rows: [{ label: 'Status', value: 'Open' }] } },
      ],
    }
    const { drawn, log } = draw(page)
    expect(drawn.nav.map(one => one.href)).toEqual([
      'https://figma.com/file/c0',
      'https://figma.com/file/c1',
      'https://figma.com/file/c2',
      'https://figma.com/file/a',
      'https://figma.com/file/b',
    ])
    expect(drawn.nav.map(one => one.line)).toEqual([0, 0, 0, 1, 2])
    expect(drawn.nav.map(one => one.col)).toEqual([0, 1, 2, 0, 0])
    const buttons = findAll(drawn.parts, one => one.el === 'Button')
    expect(buttons.map(one => one.key)).toEqual(['item-3', 'item-4'])
    expect(log.markdown.map(one => one.text)).toEqual(['Some **notes**.'])
    expect(log.rules).toEqual(['Notes', 'Frames', 'Files', 'Facts'])
    expect(textOf(drawn.parts)).toContain('Open')
  })

  test('pressing a table row picks its place in the one focus order', () => {
    const { writers, log } = fakeWriters()
    const drawn = drawPage(writers, sectionPage({ type: 'list', items: [{ title: 'A', href: '/a' }] }, { type: 'table', columns: ['N'], rows: [{ cells: ['x'] }, { cells: ['y'], href: '/y' }] }), { width: WIDTH, selected: 0 })
    const buttons = findAll(drawn.parts, one => one.el === 'Button')
    ;(buttons[1]?.onPress as () => void)()
    expect(log.picked).toEqual([2])
  })

  test('the selected table row is highlighted and takes focus; the cards see the same cursor', () => {
    const page = sectionPage({ type: 'cards', items: cards(1) }, { type: 'table', columns: ['N'], rows: [{ cells: ['x'] }, { cells: ['y'] }] })
    const { drawn } = draw(page, 2)
    const buttons = findAll(drawn.parts, one => one.el === 'Button')
    expect(buttons.map(one => one.autoFocus)).toEqual([undefined, true])
    const rows = findAll(drawn.parts, one => one.el === 'Box' && typeof one.key === 'string' && one.key.startsWith('section-1-row-'))
    expect(rows.map(one => one.backgroundColor)).toEqual([undefined, 'surface0'])
    expect(findAll(drawn.parts, one => one.el === 'cards')[0]?.selected).toBe(2)
  })

  test('table cells are fitted with columnWidths and fitCell from lib', () => {
    const columns = ['Name', 'Size']
    const rows = [{ cells: ['a-very-long-file-name-that-will-not-fit-in-the-pane-at-all.fig', '2 MB'] }]
    const { drawn } = draw(sectionPage({ type: 'table', columns, rows }))
    const widths = columnWidths([columns, ...rows.map(one => one.cells)], WIDTH - 2)
    const text = textOf(drawn.parts)
    expect(text).toContain(widths.map((w, c) => fitCell(columns[c] ?? '', w)).join('  '))
    expect(text).toContain(widths.map((w, c) => fitCell(rows[0]?.cells[c] ?? '', w)).join('  '))
  })

  test('actions become Keys with hotkeys 1 and 2, listed in the menu', () => {
    const page: Page = { ...sectionPage(), actions: [{ label: 'Open in Figma', open: 'https://figma.com/file/a' }, { label: 'Copy link', copy: 'https://figma.com/file/a' }] }
    const { drawn } = draw(page)
    expect(drawn.keys.map(({ key, label, hotkey, menu }) => ({ key, label, hotkey, menu }))).toEqual([
      { key: 'action-0', label: 'Open in Figma', hotkey: '1', menu: 'Open in Figma' },
      { key: 'action-1', label: 'Copy link', hotkey: '2', menu: 'Copy link' },
    ])
  })

  test('an open action opens its link; a copy action copies its text and says what it copied', () => {
    const { writers, log } = fakeWriters()
    const page: Page = { ...sectionPage(), actions: [{ label: 'Open', open: '/Users/x/plan.md' }, { label: 'Copy id', copy: 'abc123' }] }
    const drawn = drawPage(writers, page, { width: WIDTH, selected: 0 })
    drawn.keys[0]?.onPress()
    expect(log.opened).toEqual(['/Users/x/plan.md'])
    expect(log.copied).toEqual([])
    drawn.keys[1]?.onPress()
    expect(log.copied).toEqual(['abc123'])
    expect(log.notices).toEqual(['Copied abc123'])
  })

  test('a long copied text is shortened in the notice but copied whole', () => {
    const { writers, log } = fakeWriters()
    const long = 'x'.repeat(500)
    const drawn = drawPage(writers, { ...sectionPage(), actions: [{ label: 'Copy', copy: long }] }, { width: WIDTH, selected: 0 })
    drawn.keys[0]?.onPress()
    expect(log.copied).toEqual([long])
    expect(log.notices[0]?.length).toBeLessThan(100)
    expect(log.notices[0]?.startsWith('Copied xxx')).toBe(true)
  })

  test('a tenth action never reaches the renderer: the validator rejects it', () => {
    const actions = Array.from({ length: 10 }, (_, i) => ({ label: `A${i}`, copy: `${i}` }))
    const result = validatePage({ title: 'T', sections: [], actions })
    expect(result.ok).toBe(false)
    expect(result.ok ? [] : result.problems.map(one => one.path)).toEqual(['actions'])
  })

  test('an empty cards section and a page with no sections each draw their one empty line', () => {
    const empty = draw(sectionPage({ type: 'cards', items: [] }))
    expect(findAll(empty.drawn.parts, one => textOf(one) === EMPTY_SECTION && one.el === 'Text')).toHaveLength(1)
    expect(empty.drawn.nav).toEqual([])
    const bare = draw({ title: 'Nothing here', sections: [] })
    expect(findAll(bare.drawn.parts, one => textOf(one) === EMPTY_PAGE && one.el === 'Text')).toHaveLength(1)
    expect(textOf(bare.drawn.parts)).not.toContain(EMPTY_SECTION)
  })

  test('every empty block type draws the empty line instead of calling its writer', () => {
    const { drawn, log } = draw(
      sectionPage(
        { type: 'list', items: [] },
        { type: 'table', columns: ['A'], rows: [] },
        { type: 'media', items: [] },
        { type: 'fields', rows: [] },
        { type: 'markdown', text: '   ' },
      ),
    )
    expect(findAll(drawn.parts, one => one.el === 'Text' && textOf(one) === EMPTY_SECTION)).toHaveLength(5)
    expect(log.rowLooks).toEqual([])
    expect(log.media).toEqual([])
    expect(log.markdown).toEqual([])
    expect(textOf(drawn.parts)).not.toContain(EMPTY_PAGE)
  })

  test('three images across two sections go through one block-writer set, in order, clear of markdown media keys', () => {
    const page = sectionPage(
      { type: 'media', items: [{ url: 'https://cdn.example.com/1.png', alt: 'one', kind: 'image' }, { url: 'https://cdn.example.com/2.png', kind: 'image' }] },
      { type: 'markdown', text: '![inline](https://cdn.example.com/in.png)' },
      { type: 'media', items: [{ url: 'https://cdn.example.com/3.png', kind: 'image' }] },
    )
    const { log } = draw(page)
    expect(log.blockSets).toBe(1)
    expect(log.media.map(one => [one.index, one.alt, one.url])).toEqual([
      [PAGE_MEDIA_BASE, 'one', 'https://cdn.example.com/1.png'],
      [PAGE_MEDIA_BASE + 1, '', 'https://cdn.example.com/2.png'],
      [PAGE_MEDIA_BASE + 2, '', 'https://cdn.example.com/3.png'],
    ])
  })

  test('items without a link still take focus, with an empty href and no star', () => {
    const { drawn, log } = draw(sectionPage({ type: 'list', items: [{ title: 'Bare' }, { title: 'Starred', href: STARRED }] }, { type: 'table', columns: ['N'], rows: [{ cells: ['x'] }] }))
    expect(drawn.nav.map(one => one.href)).toEqual(['', STARRED, ''])
    expect(log.rowLooks.map(one => [one.isStarred, one.name])).toEqual([[false, 'Bare'], [true, 'Starred']])
  })

  test('card and list looks carry title, host or path, meta and an icon by link kind', () => {
    const items: ListItem[] = [{ title: 'Web', meta: 'today', href: 'https://figma.com/file/a' }, { title: 'Local', href: '/Users/x/plan.md' }]
    const { log } = draw(sectionPage({ type: 'cards', items }, { type: 'list', items }))
    expect(log.cardLooks.map(({ name, folder, detail }) => ({ name, folder, detail }))).toEqual([
      { name: 'Web', folder: 'figma.com', detail: 'today' },
      { name: 'Local', folder: '/Users/x/plan.md', detail: '' },
    ])
    expect(log.cardLooks[0]?.icon).not.toBe(log.cardLooks[1]?.icon)
    expect(log.rowLooks).toEqual(log.cardLooks)
  })

  test('card pictures share the page image budget: one past it draws no picture', () => {
    const items: CardItem[] = [
      { title: 'A', image: 'https://cdn.example.com/a.png' },
      { title: 'B', image: 'https://cdn.example.com/b.png' },
      { title: 'C', image: 'https://cdn.example.com/c.gif' },
      { title: 'D' },
    ]
    const { log } = draw(sectionPage({ type: 'cards', items }))
    expect(log.cardLooks.map(one => one.favicon)).toEqual(['pppppp', undefined, undefined, undefined])
  })

  test('parts, row estimates and headings line up for settleBlocks, headed by their section', () => {
    const page: Page = {
      title: 'Design review',
      details: [{ label: 'Owner', value: 'Shawn' }, { label: 'Team', value: 'Design' }],
      sections: [
        { heading: 'Frames', block: { type: 'cards', items: cards(2) } },
        { block: { type: 'list', items: [{ title: 'A' }, { title: 'B' }, { title: 'C' }] } },
      ],
    }
    const { drawn, log } = draw(page)
    expect(drawn.rows).toHaveLength(drawn.parts.length)
    expect(drawn.headings).toHaveLength(drawn.parts.length)
    const at = (el: string) => drawn.parts.findIndex(one => findAll(one, node => node.el === el).length > 0)
    expect(drawn.rows[at('cards')]).toBe(CARD_ROWS + 1)
    expect(drawn.headings[at('cards')]).toBe('Frames')
    expect(drawn.rows[at('rows')]).toBe(3)
    expect(log.rules).toEqual(['Frames'])
    expect(textOf(drawn.parts[0])).toContain('Design review')
    expect(textOf(drawn.parts[1])).toContain('Owner')
    expect(textOf(drawn.parts[1])).toContain('Shawn')
    expect(drawn.rows[1]).toBe(2)
  })

  test('a page the validator accepted draws every block type, focusing cards, list items and table rows only', () => {
    const raw = {
      title: 'Everything',
      details: [{ label: 'Owner', value: 'Shawn' }],
      sections: [
        { heading: 'Notes', block: { type: 'markdown', text: '# Plan' } },
        { block: { type: 'media', items: [{ url: 'https://cdn.example.com/a.png', kind: 'image' }] } },
        { block: { type: 'table', columns: ['Name'], rows: [{ cells: ['a'], href: 'https://figma.com/file/a' }] } },
        { block: { type: 'cards', items: [{ title: 'Frame', href: 'https://figma.com/file/b' }] } },
        { block: { type: 'list', items: [{ title: 'Plan', href: '/Users/x/plan.md' }, { title: 'Bare' }] } },
        { block: { type: 'fields', rows: [{ label: 'Status', value: 'Open' }] } },
      ],
      actions: [{ label: 'Copy id', copy: 'abc' }],
    }
    const checked = validatePage(raw)
    if (!checked.ok) throw new Error('fixture did not validate')
    const { drawn, log } = draw(checked.page)
    expect(drawn.nav.map(one => one.href)).toEqual(['https://figma.com/file/a', 'https://figma.com/file/b', '/Users/x/plan.md', ''])
    expect(log.media).toHaveLength(1)
    expect(log.markdown).toHaveLength(1)
    expect(drawn.keys.map(one => one.hotkey)).toEqual(['1'])
    expect(textOf(drawn.parts)).not.toContain(EMPTY_SECTION)
  })
})
