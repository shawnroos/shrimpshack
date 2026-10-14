import { expect, test } from 'claude-code/testing'

import { cycleLayoutOfRow, getPlace, toggleFoldOfRow } from '../hooks/pane/blocks/common'
import { fitRow } from '../hooks/measure'
import { newBlocks, settleBlocks } from '../hooks/pane/screens/view/blocks'
import { drawProse, proseParts } from '../hooks/pane/screens/view/prose'
import type { ProseOptions } from '../hooks/pane/screens/view/prose'
import { readDefinition } from '../hooks/views/definition'
import type { Item } from '../hooks/views/items'
import type { Rule } from '../hooks/views/select'

type Node = { type: string; props: Record<string, unknown>; children: unknown[] }

const el = (type: string) => (props: Record<string, unknown>) => {
  const { children, ...rest } = props
  return { type, props: rest, children: [children].flat(Infinity).filter(one => one !== undefined && one !== null && one !== false && one !== true) }
}

const palette = new Proxy({}, { get: () => '#888888' })

function fakeCtx(width: number, href = 'file:///repo/page.md') {
  return {
    Box: el('Box'),
    Text: el('Text'),
    Button: el('Button'),
    Markdown: el('Markdown'),
    Code: el('Code'),
    C: palette,
    isMenuOpen: false,
    textWidth: width,
    current: { href, title: 'page.md', location: '/repo/page.md' },
    layout: () => ({ nav: [], blockStarts: [], blockHeadings: [], estimatedRows: 1 }),
    scale: 1,
    offset: 0,
    bodyRows: 40,
    contentRows: 0,
  } as never
}

type Cell = { read: () => Promise<unknown>; update: (change: (old: unknown) => unknown) => Promise<unknown> }

function fakeIo(cursor = 0) {
  const calls: string[] = []
  const cell = (name: string, start: unknown): Cell => {
    let value = start
    return {
      read: async () => value,
      update: async change => {
        value = change(value)
        calls.push(`${name}`)
        return value
      },
    }
  }
  const io = {
    calls,
    cursor: cell('cursor', cursor),
    view: cell('view', null),
    mode: cell('mode', 'view'),
    mentions: cell('mentions', []),
    page: cell('page', 0),
    openGroup: cell('openGroup', null),
    now: async () => 0,
    scroll: async () => undefined,
    open: async () => undefined,
    focus: async () => undefined,
    invalidate: () => undefined,
    loadFile: async (href: string) => {
      calls.push(`loadFile ${href}`)
      return { href, title: 'x', location: href }
    },
    loadUrl: async (href: string) => {
      calls.push(`loadUrl ${href}`)
      return { href, title: 'x', location: href }
    },
  }
  return io
}

const task = (id: string, name: string, props: Record<string, unknown> = {}, missing?: string[]): Item => ({
  id,
  href: `/repo/tasks/${id}.md`,
  type: 'task',
  name,
  props: { id, status: 'todo', creator: 'Shawn', ...props } as Item['props'],
  source: 'task-folder',
  ...(missing ? { missing } : {}),
})

const ITEMS: Item[] = [
  task('a', 'Write plan', { status: 'doing', due: '2026-10-20' }),
  task('b', 'Draft intro'),
  task('c', 'Collect refs'),
  task('d', 'Sketch board'),
  task('e', 'Tidy notes'),
  task('f', 'Book review'),
  task('g', 'Ship draft'),
  task('w', 'Wait on plan', { sequence: { after: 'a' } }),
  task('p', 'Parent task'),
  task('c1', 'Child one', { parent: 'p' }),
  task('c2', 'Child two', { parent: 'p' }),
  task('z', 'Finished thing', { status: 'done' }),
]

const provider = (items: readonly Item[]): ProseOptions['items'] => (rule: Rule) => items.filter(item => Object.entries(rule).every(([key, value]) => item.props[key] === value || (item as unknown as Record<string, unknown>)[key] === value))

const options = (items: readonly Item[] | undefined, extra: Partial<ProseOptions> = {}): ProseOptions => ({
  picture: () => null,
  ...(items ? { items: provider(items) } : {}),
  ...extra,
})

const fence = (lang: string, info = '', body = '') => ['```' + `${lang}${info ? ` ${info}` : ''}`, ...(body ? [body] : []), '```'].join('\n')

function flat(list: unknown[]): string {
  return list.map(one => (typeof one === 'string' ? one : typeof one === 'number' ? String(one) : flat((one as Node).children ?? []))).join('')
}

// The lines a node draws: a column stacks its children, a row lays them side by side, Text and Button are one
// line, a fixed height pads or cuts, padding and margins add blank lines.
function linesOf(node: unknown): string[] {
  if (typeof node === 'string') return [node]
  if (!node || typeof node !== 'object') return []
  const { type, props, children } = node as Node
  if (type === 'Text') return [flat(children)]
  if (type === 'Button') return [String(props.label ?? '')]
  if (type === 'Markdown') return String(props.text ?? '').split('\n')
  if (type === 'Code') return String(props.source ?? '').split('\n')
  const parts = children.map(linesOf)
  let lines: string[]
  if (props.flexDirection === 'column') lines = parts.flat()
  else {
    const tall = Math.max(0, ...parts.map(one => one.length))
    lines = Array.from({ length: tall }, (_, i) => parts.map(one => one[i] ?? '').join(''))
  }
  const padY = Number(props.paddingY ?? 0)
  if (padY) lines = [...Array(padY).fill(''), ...lines, ...Array(padY).fill('')]
  if (typeof props.height === 'number') lines = Array.from({ length: props.height }, (_, i) => lines[i] ?? '')
  const below = Number(props.marginBottom ?? 0)
  if (below) lines = [...lines, ...Array(below).fill('')]
  return lines
}

function walk(node: unknown, visit: (one: Node) => void) {
  if (!node || typeof node !== 'object') return
  visit(node as Node)
  for (const child of (node as Node).children ?? []) walk(child, visit)
}

async function drawOne(text: string, opts: ProseOptions, width = 80, href?: string, cursor = 0) {
  const io = fakeIo(cursor)
  const parts = await proseParts(fakeCtx(width, href), io as never, 'body', text, opts)
  return { io, parts, part: parts[0] as (typeof parts)[number] }
}

const LAYOUTS = ['cards', 'list', 'tree', 'sections', 'board', 'focus'] as const

test('a peek-list fence draws its items as rows, not as a code block', async () => {
  const { part } = await drawOne(fence('peek-list', 'status=todo'), options(ITEMS))
  const lines = linesOf(part.node)
  expect(lines.some(line => line.includes('CODE'))).toBe(false)
  expect(lines.some(line => line.includes('Draft intro'))).toBe(true)
  expect(lines.some(line => line.includes('Write plan'))).toBe(false)
})

test('layout options are stripped before the rule selects: split does not filter', async () => {
  const { part } = await drawOne(fence('peek-list', 'split=status status=todo'), options(ITEMS))
  const lines = linesOf(part.node)
  expect(lines.some(line => line.includes('Draft intro'))).toBe(true)
  expect(lines.some(line => line.includes('no items'))).toBe(false)
})

test('a rule in the block body selects too', async () => {
  const { part } = await drawOne(fence('peek-list', '', 'status=doing'), options(ITEMS))
  const lines = linesOf(part.node).filter(Boolean)
  expect(lines.length).toBe(1)
  expect(lines[0]).toContain('Write plan')
})

test('each collection layout draws the same items on a file page, in a group description and in a remote body', async () => {
  for (const layout of LAYOUTS) {
    const text = fence(`peek-${layout}`)
    const names = async (ctxWidth: number, extra: Partial<ProseOptions>, href: string) => {
      const parts = await proseParts(fakeCtx(ctxWidth, href), fakeIo() as never, 'body', text, options(ITEMS, extra))
      const drawn = parts.flatMap(one => linesOf(one.node)).join('\n')
      return ITEMS.map(item => item.name).filter(name => drawn.includes(name))
    }
    const onFile = await names(100, { canTickTasks: true }, `file:///repo/${layout}.md`)
    const inDescription = await names(102, { indent: 2 }, `file:///repo/${layout}-group.md`)
    const inRemote = await names(100, {}, `https://github.com/acme/widgets/pull/${layout.length}`)
    expect(onFile.length).toBeGreaterThan(3)
    expect(inDescription).toEqual(onFile)
    expect(inRemote).toEqual(onFile)
  }
})

test('focus draws doing in Now, at most five unblocked todos in Next and the rest in Later', async () => {
  const { part } = await drawOne(fence('peek-focus'), options(ITEMS), 100, 'file:///repo/focus.md')
  const lines = linesOf(part.node)
  const at = (label: string) => lines.findIndex(line => line.startsWith(label))
  const between = (from: string, to: string) => lines.slice(at(from) + 1, to ? at(to) : undefined).join('\n')
  expect(at('NOW')).toBeGreaterThanOrEqual(0)
  expect(at('NEXT')).toBeGreaterThan(at('NOW'))
  expect(at('LATER')).toBeGreaterThan(at('NEXT'))
  expect(between('NOW', 'NEXT')).toContain('Write plan')
  const next = between('NEXT', 'LATER')
  expect(next.split('\n').filter(Boolean).length).toBe(5)
  expect(next).toContain('Parent task › ')
  expect(next).not.toContain('Wait on plan')
  const later = between('LATER', '')
  expect(later).toContain('Wait on plan')
  expect(later).not.toContain('Finished thing')
})

test('an empty Now, Next or Later shows a dim none row', async () => {
  const { part } = await drawOne(fence('peek-focus'), options([task('b', 'Draft intro')]), 100, 'file:///repo/focus-none.md')
  const lines = linesOf(part.node)
  const now = lines.findIndex(line => line.startsWith('NOW'))
  expect(lines[now + 1]).toContain('none')
  expect(lines.filter(line => line.trim() === 'none').length).toBe(2)
})

test('a four-column board in a 44-column pane draws as status sections; a wide pane draws columns', async () => {
  const items = [task('t', 'Todo one'), task('d', 'Doing one', { status: 'doing' }), task('x', 'Done one', { status: 'done' }), task('k', 'Cancelled one', { status: 'cancelled' })]
  const narrow = linesOf((await drawOne(fence('peek-board'), options(items), 44, 'file:///repo/board.md')).part.node)
  expect(narrow.filter(line => /^(TODO|DOING|DONE|CANCELLED) /.test(line)).length).toBe(4)
  expect(narrow.some(line => line.includes('Todo one') && line.includes('Doing one'))).toBe(false)
  const wide = linesOf((await drawOne(fence('peek-board'), options(items), 140, 'file:///repo/board-wide.md')).part.node)
  expect(wide.some(line => line.includes('DOING') && line.includes('TODO'))).toBe(true)
})

test('a folded tree parent shows its child count, and unfolding reveals the children', async () => {
  const href = 'file:///repo/tree.md'
  const draw = async () => (await drawOne(fence('peek-tree'), options(ITEMS), 80, href)).part
  const open = await draw()
  const openLines = linesOf(open.node)
  const parentLine = openLines.find(line => line.includes('Parent task')) ?? ''
  expect(parentLine).toContain('▾')
  expect(parentLine).toContain('2')
  expect(openLines.some(line => line.includes('Child one') && /[├└]/.test(line))).toBe(true)
  const parentRow = (open.nav ?? []).find(one => one.href.endsWith('/p.md'))
  expect(parentRow).toBeDefined()
  expect(toggleFoldOfRow(parentRow?.key ?? '')).toBe(true)
  const folded = linesOf((await draw()).node)
  expect(folded.find(line => line.includes('Parent task'))).toContain('▸')
  expect(folded.find(line => line.includes('Parent task'))).toContain('2')
  expect(folded.some(line => line.includes('Child one'))).toBe(false)
  toggleFoldOfRow(parentRow?.key ?? '')
  expect(linesOf((await draw()).node).some(line => line.includes('Child one'))).toBe(true)
})

test('tree rows stay one line each at a narrow width', async () => {
  const deep = [task('r', 'Root with a long long long name'), task('s', 'Second level with a very long name', { parent: 'r' }), task('t', 'Third level with an even longer name', { parent: 's' })]
  const { part } = await drawOne(fence('peek-tree'), options(deep), 20, 'file:///repo/narrow-tree.md')
  const lines = linesOf(part.node)
  expect(lines.length).toBe(3)
  expect(part.rows).toBe(3)
  for (const line of lines) expect(line.length).toBeLessThanOrEqual(20)
})

test('covers AE5: a tree block in a group description draws the group tasks as a tree', async () => {
  const description = ['Tasks under the parent:', '', fence('peek-tree', 'parent=p')].join('\n')
  const parts = await proseParts(fakeCtx(62, 'file:///repo/group'), fakeIo() as never, 'group-description', description, options(ITEMS, { indent: 2 }))
  const drawn = parts.flatMap(one => linesOf(one.node))
  expect(drawn.some(line => line.includes('Child one'))).toBe(true)
  expect(drawn.some(line => line.includes('Child two'))).toBe(true)
  expect(drawn.some(line => line.includes('Draft intro'))).toBe(false)
})

test('every layout reports the rows it draws, so block starts land on block starts', async () => {
  const sets: [string, readonly Item[]][] = [['full', ITEMS], ['empty', []], ['one', [task('b', 'Draft intro')]]]
  for (const layout of LAYOUTS) {
    for (const width of [44, 140]) {
      for (const [name, items] of sets) {
        const { part } = await drawOne(fence(`peek-${layout}`), options(items), width, `file:///repo/rows-${layout}-${width}-${name}.md`)
        expect({ layout, width, name, rows: linesOf(part.node).length }).toEqual({ layout, width, name, rows: part.rows })
      }
    }
  }
  const blocks = newBlocks()
  const ctx = fakeCtx(80, 'file:///repo/starts.md')
  await drawProse(ctx, fakeIo() as never, blocks, 'body', [fence('peek-focus'), '', 'after the block'].join('\n'), options(ITEMS))
  const settled = settleBlocks(ctx, fakeIo() as never, blocks)
  const focusRows = blocks.partRows[0] ?? 0
  expect(settled.layout.blockStarts).toEqual([0, focusRows + 1])
})

test('y switches a block layout, and the choice holds for that place across draws but not for another page', async () => {
  const href = 'file:///repo/switch.md'
  const first = await drawOne(fence('peek-list'), options(ITEMS), 100, href)
  const rowKey = first.part.nav?.[0]?.key ?? ''
  expect(cycleLayoutOfRow(rowKey)).toBe('tree')
  const again = linesOf((await drawOne(fence('peek-list'), options(ITEMS), 100, href)).part.node)
  expect(again.some(line => /[├└]/.test(line))).toBe(true)
  const other = linesOf((await drawOne(fence('peek-list'), options(ITEMS), 100, 'file:///repo/other.md')).part.node)
  expect(other.some(line => /[├└]/.test(line))).toBe(false)
  expect(getPlace(`${href}#body-0`)?.layout).toBe('tree')
})

test('z folds the selected tree parent', async () => {
  const href = 'file:///repo/z.md'
  const first = await drawOne(fence('peek-tree'), options(ITEMS), 80, href)
  const childRow = first.part.nav?.find(one => one.href.endsWith('/c1.md'))
  expect(toggleFoldOfRow(childRow?.key ?? '')).toBe(false)
  const parentRow = first.part.nav?.find(one => one.href.endsWith('/p.md'))
  expect(toggleFoldOfRow(parentRow?.key ?? '')).toBe(true)
  const lines = linesOf((await drawOne(fence('peek-tree'), options(ITEMS), 80, href)).part.node)
  expect(lines.some(line => line.includes('Child one'))).toBe(false)
})

test('j and k rows: a focus block puts one nav row per drawn task, the cursor row holds the focus, Enter opens it', async () => {
  const href = 'file:///repo/keys.md'
  const blocks = newBlocks()
  const ctx = fakeCtx(100, href)
  const io = fakeIo(1)
  await drawProse(ctx, io as never, blocks, 'body', ['intro', '', fence('peek-focus')].join('\n'), options(ITEMS))
  const settled = settleBlocks(ctx, io as never, blocks)
  const nav = settled.layout.nav ?? []
  const drawnTasks = linesOf(blocks.drawnParts[1]).filter(line => ITEMS.some(item => line.includes(item.name)))
  expect(nav.length).toBe(drawnTasks.length)
  expect(nav.map(one => one.line)).toEqual(nav.map((_, i) => i))
  const focused: Node[] = []
  walk(blocks.drawnParts[1], one => {
    if (one.type === 'Button' && one.props.autoFocus === true) focused.push(one)
  })
  expect(focused.length).toBe(1)
  expect(focused[0]?.props.key).toBe('item-1')
  const selected = nav[1]
  expect(drawnTasks[1]).toContain(ITEMS.find(item => item.href === selected?.href)?.name ?? '?')
  await (focused[0]?.props.onPress as () => Promise<void>)()
  for (let i = 0; i < 50; i++) await Promise.resolve()
  expect(io.calls).toContain(`loadFile file://${selected?.href}`)
})

test('keyboard rows count across blocks and across prose drawn in pieces, as on a pull request with comments', async () => {
  const href = 'file:///repo/pieces.md'
  const blocks = newBlocks()
  const ctx = fakeCtx(100, href)
  const io = fakeIo(2)
  await drawProse(ctx, io as never, blocks, 'body', fence('peek-list', 'status=doing'), options(ITEMS))
  await drawProse(ctx, io as never, blocks, 'comment-0-body', [fence('peek-list', 'status=done'), '', fence('peek-list', 'parent=p')].join('\n'), options(ITEMS))
  const nav = settleBlocks(ctx, io as never, blocks).layout.nav ?? []
  expect(nav.map(one => one.href.split('/').pop())).toEqual(['a.md', 'z.md', 'c1.md', 'c2.md'])
  const focused: string[] = []
  blocks.drawnParts.forEach((part, index) =>
    walk(part, one => {
      if (one.type === 'Button' && one.props.autoFocus === true) focused.push(`${index} ${String(one.props.key)} ${String(one.props.label)}`)
    }),
  )
  expect(focused).toEqual(['2 item-2 Child one'])
})

test('a narrow row truncates the name and keeps the missing-prop flag and creator', async () => {
  const items = [task('n', 'A task with a rather long descriptive name', { creator: 'Shawn', due: '2026-10-20' }, ['due', 'parent'])]
  const { part } = await drawOne(fence('peek-list'), options(items), 32, 'file:///repo/narrow.md')
  const line = linesOf(part.node)[0] ?? ''
  expect(line).toContain('⚑')
  expect(line).toContain('Shawn')
  expect(line).toContain('…')
  expect(line.length).toBeLessThanOrEqual(32)
})

test('fitRow drops the due date, then the creator, and never the flag', () => {
  expect(fitRow('Short', [{ text: 'Shawn' }, { text: '10-20' }, { text: '⚑', keep: true }], 40)).toEqual({ name: 'Short', right: ['Shawn', '10-20', '⚑'] })
  const tight = fitRow('A long name that must give way', [{ text: 'Shawn' }, { text: '10-20' }, { text: '⚑', keep: true }], 22)
  expect(tight.right).toEqual(['Shawn', '10-20', '⚑'])
  expect(tight.name.endsWith('…')).toBe(true)
  const tighter = fitRow('A long name that must give way', [{ text: 'Shawn' }, { text: '10-20' }, { text: '⚑', keep: true }], 16)
  expect(tighter.right).toEqual(['Shawn', '⚑'])
  const tightest = fitRow('A long name that must give way', [{ text: 'Shawn' }, { text: '10-20' }, { text: '⚑', keep: true }], 9)
  expect(tightest.right).toEqual(['⚑'])
  expect(tightest.name.length).toBeGreaterThan(0)
})

test('session ended and the parent prefix draw dim', async () => {
  const items = [task('p', 'Parent task'), task('k', 'Kid', { parent: 'p', status: 'doing', session_ended: true })]
  const { part } = await drawOne(fence('peek-sections'), options(items), 100, 'file:///repo/dim.md')
  const dim: string[] = []
  walk(part.node, one => {
    if (one.type === 'Text' && one.props.dimColor === true) dim.push(flat(one.children))
  })
  expect(dim.some(text => text.includes('session ended'))).toBe(true)
  expect(dim.some(text => text.includes('Parent task'))).toBe(true)
})

test('an empty block draws one dim row naming what it selected, with or without an item source', async () => {
  for (const opts of [options([]), options(undefined)]) {
    const { part } = await drawOne(fence('peek-list', 'status=todo'), opts, 80, 'file:///repo/empty.md')
    expect(part.rows).toBe(1)
    expect(linesOf(part.node)).toEqual(['no items · status=todo'])
  }
})

test('a fixed record block draws one line, not a code block', async () => {
  const { part } = await drawOne(fence('peek-header'), options(ITEMS), 80, 'file:///repo/header.md')
  expect(part.rows).toBe(1)
  expect(linesOf(part.node).join('')).not.toContain('CODE')
})

test('a row status glyph takes the color its definition maps the status to, and keeps the built-in one otherwise', async () => {
  const check = readDefinition('task.md', ['---', 'type: task', 'match: { folder: tasks }', 'props:', '  status: { kind: choice, values: [todo, doing] }', 'colors:', '  status: { todo: red }', '---'].join('\n'))
  if (!check.ok) throw new Error('the probe definition must load')
  const ctx = { ...(fakeCtx(80, 'file:///repo/colors.md') as object), C: new Proxy({}, { get: (_t, key) => `#${String(key)}` }) }
  const glyphColors = async (opts: ProseOptions) => {
    const parts = await proseParts(ctx as never, fakeIo() as never, 'body', fence('peek-list'), opts)
    const colors: string[] = []
    walk(parts[0]?.node, one => {
      if (one.type === 'Text' && /^[○◐●⊘·] $/.test(flat(one.children))) colors.push(`${flat(one.children).trim()} ${String(one.props.color)}`)
    })
    return colors
  }
  const items = [task('t', 'Todo one'), task('d', 'Doing one', { status: 'doing' })]
  expect(await glyphColors(options(items, { definitions: () => [check.definition] }))).toEqual(['◐ #yellow', '○ #red'])
  expect(await glyphColors(options(items))).toEqual(['◐ #yellow', '○ #overlay1'])
})
