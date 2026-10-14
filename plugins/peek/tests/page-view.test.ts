import { describe, expect, test } from 'claude-code/testing'

import { pixels } from '../hooks/images'
import { EMPTY_PAGE, EMPTY_SECTION, PAGE_MEDIA_BASE, recipePageBody } from '../hooks/pane/screens/view/recipe'
import { validatePage } from '../hooks/recipes/page'
import type { CardItem, Page, PageBlock, PageListItem, RecipePage } from '../types/recipes'
import { columnWidths, fitCell } from '../hooks/tabular'
import { ICON } from '../hooks/theme'

type Node = { type: string; props: Record<string, unknown>; children: unknown[] }

// Three cards to a row, as the fake card writer the source test used put them; at 60 columns the grid holds two.
const WIDTH = 100
const CARD_ROWS = 5
const STARRED = 'https://figma.com/file/starred'

const el = (type: string) => (props: Record<string, unknown>) => {
  const { children, ...rest } = props
  return { type, props: rest, children: [children].flat(Infinity).filter(one => one !== undefined && one !== null && one !== false && one !== true) }
}

// Each colour reads as its own name, so a test can tell the selected background from the card's.
const palette = new Proxy({}, { get: (_, name) => String(name) })

function fakeCtx() {
  return {
    Box: el('Box'),
    Text: el('Text'),
    Button: el('Button'),
    Markdown: el('Markdown'),
    Code: el('Code'),
    Image: el('Image'),
    C: palette,
    isMenuOpen: false,
    textWidth: WIDTH,
    current: { href: 'https://figma.com/file/abc', title: 'T', location: 'https://figma.com/file/abc' },
    layout: () => ({ nav: [], blockStarts: [], blockHeadings: [], estimatedRows: 1 }),
    scale: 1,
    offset: 0,
    bodyRows: 40,
    contentRows: 0,
  } as never
}

type Cell = { read: () => Promise<unknown>; update: (change: (old: unknown) => unknown) => Promise<unknown> }

function fakeWorld(stars: string[] = []) {
  const log = { picked: [] as number[], copied: [] as string[], toasts: [] as string[], calls: [] as string[] }
  const cell = (start: unknown): Cell => {
    let value = start
    return {
      read: async () => value,
      update: async change => {
        value = change(value)
        return value
      },
    }
  }
  const io = {
    cursor: cell(0),
    view: cell(null),
    mode: cell('view'),
    mentions: cell([]),
    page: cell(0),
    openGroup: cell(null),
    stars: cell(stars),
    now: async () => 0,
    scroll: async () => undefined,
    open: async () => undefined,
    focus: async () => undefined,
    invalidate: () => undefined,
    run: async () => ({ exitCode: 0, stdout: '', stderr: '' }),
    copy: async ({ text }: { text: string }) => {
      log.copied.push(text)
    },
    toast: (text: string) => log.toasts.push(text),
    loadFile: async (href: string) => {
      log.calls.push(`loadFile ${href}`)
      return { href, title: 'x', location: href }
    },
    loadUrl: async (href: string) => {
      log.calls.push(`loadUrl ${href}`)
      return { href, title: 'x', location: href }
    },
  }
  const actions = {
    io,
    selectAndOpen: async (index: number) => {
      log.picked.push(index)
    },
  }
  return { actions: actions as never, log }
}

const ready = (page: Page, extra: Partial<Extract<RecipePage, { phase: 'ready' }>> = {}): RecipePage => ({
  phase: 'ready',
  id: 'figma-files',
  name: 'Figma files',
  link: 'https://figma.com/file/abc',
  isDraft: false,
  digest: 'd',
  refreshMinutes: 0,
  fetchedAt: 0,
  page,
  ...extra,
})

async function draw(page: Page, selected = 0, options: { stars?: string[]; extra?: Partial<Extract<RecipePage, { phase: 'ready' }>> } = {}) {
  const { actions, log } = fakeWorld(options.stars)
  const ctx = fakeCtx()
  const drawn = await recipePageBody(ctx, actions, (ctx as { current: never }).current, ready(page, options.extra), selected)
  return { drawn, log }
}

function textOf(node: unknown): string {
  if (typeof node === 'string' || typeof node === 'number') return String(node)
  if (Array.isArray(node)) return node.map(textOf).join('')
  if (node && typeof node === 'object') {
    const one = node as Node
    return [one.props?.label, one.props?.text, ...(one.children ?? [])].map(textOf).join('')
  }
  return ''
}

function findAll(node: unknown, match: (one: Node) => boolean, found: Node[] = []): Node[] {
  if (Array.isArray(node)) for (const one of node) findAll(one, match, found)
  else if (node && typeof node === 'object') {
    const one = node as Node
    if (one.props && match(one)) found.push(one)
    findAll(one.children, match, found)
  }
  return found
}

const keyed = (body: unknown, pattern: RegExp) => findAll(body, one => pattern.test(String(one.props.key ?? '')))
const items = (body: unknown) => keyed(body, /^item-\d+$/)
const sectionPage = (...blocks: PageBlock[]): Page => ({ title: 'T', sections: blocks.map(block => ({ block })) })
const cards = (n: number): CardItem[] => Array.from({ length: n }, (_, i) => ({ title: `Card ${i}`, meta: `meta ${i}`, href: `https://figma.com/file/c${i}` }))
const ticks = async () => {
  for (let i = 0; i < 50; i++) await Promise.resolve()
}

describe('recipePageBody', () => {
  test('markdown, three cards, a two-row table and fields: focus is the cards then the rows, nothing else', async () => {
    const page: Page = {
      title: 'Design review',
      sections: [
        { heading: 'Notes', block: { type: 'markdown', text: 'Some **notes**.' } },
        { heading: 'Frames', block: { type: 'cards', items: cards(3) } },
        { heading: 'Files', block: { type: 'table', columns: ['Name', 'Size'], rows: [{ cells: ['a.fig', '2 MB'], href: 'https://figma.com/file/a' }, { cells: ['b.fig', '1 MB'], href: 'https://figma.com/file/b' }] } },
        { heading: 'Facts', block: { type: 'fields', rows: [{ label: 'Status', value: 'Open' }] } },
      ],
    }
    const { drawn } = await draw(page)
    const nav = drawn.layout.nav ?? []
    expect(nav.map(one => one.href)).toEqual([
      'https://figma.com/file/c0',
      'https://figma.com/file/c1',
      'https://figma.com/file/c2',
      'https://figma.com/file/a',
      'https://figma.com/file/b',
    ])
    expect(nav.map(one => one.line)).toEqual([0, 0, 0, 1, 2])
    expect(nav.map(one => one.col)).toEqual([0, 1, 2, 0, 0])
    expect(items(drawn.body).map(one => one.props.key)).toEqual(['item-0', 'item-1', 'item-2', 'item-3', 'item-4'])
    expect(findAll(drawn.body, one => one.type === 'Markdown').map(one => one.props.text)).toEqual(['Some **notes**.'])
    expect(keyed(drawn.body, /^section-\d+-rule$/).map(textOf)).toEqual([
      expect.stringMatching(/^NOTES ─+$/),
      expect.stringMatching(/^FRAMES ─+$/),
      expect.stringMatching(/^FILES ─+$/),
      expect.stringMatching(/^FACTS ─+$/),
    ])
    expect(textOf(drawn.body)).toContain('Open')
  })

  test('pressing a table row picks its place in the one focus order', async () => {
    const { drawn, log } = await draw(sectionPage({ type: 'list', items: [{ title: 'A', href: '/a' }] }, { type: 'table', columns: ['N'], rows: [{ cells: ['x'] }, { cells: ['y'], href: '/y' }] }))
    const row = items(drawn.body).find(one => one.props.key === 'item-2')
    ;(row?.props.onPress as () => void)()
    expect(log.picked).toEqual([2])
  })

  test('the selected table row is highlighted and takes focus; the cards see the same cursor', async () => {
    const page = sectionPage({ type: 'cards', items: cards(1) }, { type: 'table', columns: ['N'], rows: [{ cells: ['x'] }, { cells: ['y'] }] })
    const { drawn } = await draw(page, 2)
    expect(items(drawn.body).map(one => one.props.autoFocus)).toEqual([undefined, undefined, true])
    const rows = keyed(drawn.body, /^section-1-row-/)
    expect(rows.map(one => one.props.backgroundColor)).toEqual([undefined, 'surface0'])
    expect(keyed(drawn.body, /^section-0-0-0$/)[0]?.props.backgroundColor).toBe('cardBg')
  })

  test('table cells are fitted with columnWidths and fitCell', async () => {
    const columns = ['Name', 'Size']
    const rows = [{ cells: ['a-very-long-file-name-that-will-not-fit-in-the-pane-at-all.fig', '2 MB'] }]
    const { drawn } = await draw(sectionPage({ type: 'table', columns, rows }))
    const widths = columnWidths([columns, ...rows.map(one => one.cells)], WIDTH - 2)
    const text = textOf(drawn.body)
    expect(text).toContain(widths.map((w, c) => fitCell(columns[c] ?? '', w)).join('  '))
    expect(text).toContain(widths.map((w, c) => fitCell(rows[0]?.cells[c] ?? '', w)).join('  '))
  })

  test('actions become keys with hotkeys 1 and 2, listed in the menu', async () => {
    const page: Page = { ...sectionPage(), actions: [{ label: 'Open in Figma', open: 'https://figma.com/file/a' }, { label: 'Copy link', copy: 'https://figma.com/file/a' }] }
    const { drawn } = await draw(page)
    expect(drawn.keys.map(({ id, label, hotkey, menu }) => ({ id, label, hotkey, menu }))).toEqual([
      { id: 'action-0', label: 'Open in Figma', hotkey: '1', menu: 'Open in Figma' },
      { id: 'action-1', label: 'Copy link', hotkey: '2', menu: 'Copy link' },
    ])
  })

  test('an open action opens its link; a copy action copies its text and says what it copied', async () => {
    const page: Page = { ...sectionPage(), actions: [{ label: 'Open', open: '/Users/x/plan.md' }, { label: 'Copy id', copy: 'abc123' }] }
    const { drawn, log } = await draw(page)
    drawn.keys[0]?.run()
    await ticks()
    expect(log.calls).toEqual(['loadFile file:///Users/x/plan.md'])
    expect(log.copied).toEqual([])
    drawn.keys[1]?.run()
    await ticks()
    expect(log.copied).toEqual(['abc123'])
    expect(log.toasts).toEqual(['Copied abc123'])
  })

  test('a long copied text is shortened in the notice but copied whole', async () => {
    const long = 'x'.repeat(500)
    const { drawn, log } = await draw({ ...sectionPage(), actions: [{ label: 'Copy', copy: long }] })
    drawn.keys[0]?.run()
    await ticks()
    expect(log.copied).toEqual([long])
    expect(log.toasts[0]?.length).toBeLessThan(100)
    expect(log.toasts[0]?.startsWith('Copied xxx')).toBe(true)
  })

  test('a tenth action never reaches the renderer: the validator rejects it', () => {
    const actions = Array.from({ length: 10 }, (_, i) => ({ label: `A${i}`, copy: `${i}` }))
    const result = validatePage({ title: 'T', sections: [], actions })
    expect(result.ok).toBe(false)
    expect(result.ok ? [] : result.problems.map(one => one.path)).toEqual(['actions'])
  })

  test('an empty cards section and a page with no sections each draw their one empty line', async () => {
    const empty = await draw(sectionPage({ type: 'cards', items: [] }))
    expect(findAll(empty.drawn.body, one => one.type === 'Text' && textOf(one) === EMPTY_SECTION)).toHaveLength(1)
    expect(empty.drawn.layout.nav).toEqual([])
    const bare = await draw({ title: 'Nothing here', sections: [] })
    expect(findAll(bare.drawn.body, one => one.type === 'Text' && textOf(one) === EMPTY_PAGE)).toHaveLength(1)
    expect(textOf(bare.drawn.body)).not.toContain(EMPTY_SECTION)
  })

  test('every empty block type draws the empty line instead of its block', async () => {
    const { drawn } = await draw(
      sectionPage(
        { type: 'list', items: [] },
        { type: 'table', columns: ['A'], rows: [] },
        { type: 'media', items: [] },
        { type: 'fields', rows: [] },
        { type: 'markdown', text: '   ' },
      ),
    )
    expect(findAll(drawn.body, one => one.type === 'Text' && textOf(one) === EMPTY_SECTION)).toHaveLength(5)
    expect(items(drawn.body)).toEqual([])
    expect(keyed(drawn.body, /^media-/)).toEqual([])
    expect(findAll(drawn.body, one => one.type === 'Markdown')).toEqual([])
    expect(textOf(drawn.body)).not.toContain(EMPTY_PAGE)
  })

  test('three images across two sections draw in order, clear of markdown picture keys', async () => {
    const page = sectionPage(
      { type: 'media', items: [{ url: 'https://cdn.example.com/1.png', alt: 'one', kind: 'image' }, { url: 'https://cdn.example.com/2.png', kind: 'image' }] },
      { type: 'markdown', text: '![inline](https://cdn.example.com/in.png)' },
      { type: 'media', items: [{ url: 'https://cdn.example.com/3.png', kind: 'image' }] },
    )
    const media = Object.fromEntries(['1', '2', '3', 'in'].map(name => [`https://cdn.example.com/${name}.png`, {}]))
    const { drawn } = await draw(page, 0, { extra: { media } })
    const embeds = keyed(drawn.body, /^media-\d+$/)
    expect(embeds.map(one => one.props.key)).toEqual([`media-${PAGE_MEDIA_BASE}`, `media-${PAGE_MEDIA_BASE + 1}`, `media-${PAGE_MEDIA_BASE + 2}`])
    expect(embeds.map(textOf).map(text => text.includes('one') ? 'one' : text.includes('cdn.example.com') ? 'host' : text)).toEqual(['one', 'host', 'host'])
    expect(keyed(drawn.body, /^media-0-link$/).map(one => one.props.text)).toEqual(['[open image](https://cdn.example.com/in.png)'])
  })

  test('items without a link still take focus, with an empty href and no star', async () => {
    const { drawn } = await draw(sectionPage({ type: 'list', items: [{ title: 'Bare' }, { title: 'Starred', href: STARRED }] }, { type: 'table', columns: ['N'], rows: [{ cells: ['x'] }] }), 0, { stars: [STARRED] })
    expect((drawn.layout.nav ?? []).map(one => one.href)).toEqual(['', STARRED, ''])
    expect(items(drawn.body).slice(0, 2).map(one => one.props.label)).toEqual([ICON.text, ICON.star])
  })

  test('card and list items carry title, host or path, meta and an icon by link kind', async () => {
    const list: PageListItem[] = [{ title: 'Web', meta: 'today', href: 'https://figma.com/file/a' }, { title: 'Local', href: '/Users/x/plan.md' }]
    const { drawn } = await draw(sectionPage({ type: 'cards', items: list }, { type: 'list', items: list }))
    for (const prefix of ['section-0-0-', 'section-1-0-']) {
      const [web, local] = keyed(drawn.body, new RegExp(`^${prefix}\\d+$`)).map(textOf)
      expect(web).toContain('Web')
      expect(web).toContain('figma.com')
      expect(web).toContain('today')
      expect(local).toContain('Local')
      expect(local).toContain('/Users/x/plan.md')
    }
    const labels = items(drawn.body).map(one => one.props.label)
    expect(labels).toEqual([ICON.web, ICON.file, ICON.web, ICON.file])
  })

  test('card pictures share the page image budget: one past it draws no picture', async () => {
    const big = 'p'.repeat(1_000_000)
    const pictures = Object.fromEntries(['a', 'b'].map(name => [`https://cdn.example.com/${name}.png`, { file: `/tmp/test-${name}.png`, width: 10, height: 10 }]))
    pixels.set('/tmp/test-a.png', big)
    pixels.set('/tmp/test-b.png', big)
    try {
      const list: CardItem[] = [
        { title: 'A', image: 'https://cdn.example.com/a.png' },
        { title: 'B', image: 'https://cdn.example.com/b.png' },
        { title: 'C', image: 'https://cdn.example.com/c.gif' },
        { title: 'D' },
      ]
      const { drawn } = await draw(sectionPage({ type: 'cards', items: list }), 0, { extra: { pictures } })
      expect(keyed(drawn.body, /^favicon-\d+$/).map(one => one.props.key)).toEqual(['favicon-0'])
    } finally {
      pixels.delete('/tmp/test-a.png')
      pixels.delete('/tmp/test-b.png')
    }
  })

  test('blocks, row estimates and headings line up, headed by their section', async () => {
    const page: Page = {
      title: 'Design review',
      details: [{ label: 'Owner', value: 'Shawn' }, { label: 'Team', value: 'Design' }],
      sections: [
        { heading: 'Frames', block: { type: 'cards', items: cards(2) } },
        { block: { type: 'list', items: [{ title: 'A' }, { title: 'B' }, { title: 'C' }] } },
      ],
    }
    const { drawn } = await draw(page)
    const starts = drawn.layout.blockStarts ?? []
    const rowsOf = (i: number) => (starts[i + 1] ?? (drawn.layout.estimatedRows ?? 0)) - (starts[i] ?? 0) - 1
    expect(drawn.layout.blockHeadings).toEqual(['Design review', 'Details', 'Frames', 'Frames', 'Frames'])
    expect(rowsOf(1)).toBe(2)
    expect(rowsOf(3)).toBe(CARD_ROWS + 1)
    expect(rowsOf(4)).toBe(3)
    const blocks = keyed(drawn.body, /^block-\d+$/)
    expect(textOf(blocks[0])).toContain('Design review')
    expect(textOf(blocks[1])).toContain('Owner')
    expect(textOf(blocks[1])).toContain('Shawn')
    expect(keyed(drawn.body, /^section-\d+-rule$/).map(textOf)).toEqual([expect.stringMatching(/^FRAMES /)])
  })

  test('a page the validator accepted draws every block type, focusing cards, list items and table rows only', async () => {
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
    const { drawn } = await draw(checked.page)
    expect((drawn.layout.nav ?? []).map(one => one.href)).toEqual(['https://figma.com/file/a', 'https://figma.com/file/b', 'file:///Users/x/plan.md', ''])
    expect(keyed(drawn.body, /^media-\d+$/)).toHaveLength(1)
    expect(textOf(drawn.body)).toContain('PLAN')
    expect(drawn.keys.map(one => one.hotkey)).toEqual(['1'])
    expect(textOf(drawn.body)).not.toContain(EMPTY_SECTION)
  })
})
