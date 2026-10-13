import { expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'
import { C } from '../hooks/theme'
import { hoverLayers } from './fixtures/overlay'
import { exited } from './fixtures/results'
import { PANE_PROPS, baseWorld, fakeHttp, fakeProcess } from './fixtures/world'

const WORKTREE = '/Users/shawnroos/projects/herdr-linear-board/worktrees/tui-design'
const FILES: Record<string, string> = {
  [`${WORKTREE}/docs/handoff.md`]: '# Handoff\n\nIntro.\n\n## Goals\n\nShip it.\n\n## Risks\n\nNone.\n',
  [`${WORKTREE}/crates/board-tui/src/app/board.rs`]: 'fn main() {\n    println!("hi");\n}\n',
}

function fakeDisk(on: On) {
  baseWorld(on)
  fakeHttp(on)
  on('clock.now', () => ({ value: 10 * 3600_000 }))
  fakeProcess(on, argv => {
    if (argv[0] === 'git' && argv.includes('rev-parse')) return exited(0, '/repo\n/repo/.git\n/repo/.git\n')
    if (argv[0] === 'sh') return exited(0, '1700000000 1200 docs/plan.md\n1700000500 90 src/a.rs\n1700000100 5000 shots/x.png\n')
    return exited(1, '', 'unexpected')
  })
  on('fs.list', (_$, e) => {
    const prefix = `${e.path}/`
    const names = new Map<string, boolean>()
    for (const path of Object.keys(FILES)) {
      if (!path.startsWith(prefix)) continue
      const rest = path.slice(prefix.length)
      const [first = '', ...more] = rest.split('/')
      names.set(first, more.length > 0 || names.get(first) === true)
    }
    return {
      value: [...names].map(([name, isDir]) => ({
        name,
        kind: isDir ? ('dir' as const) : ('file' as const),
        size: isDir ? 0 : (FILES[`${prefix}${name}`] ?? '').length,
        mtimeMs: 8 * 3600_000,
        isLink: false,
      })),
    }
  })
  on('fs.stat', (_$, e) => {
    if (Object.keys(FILES).some(path => path.startsWith(`${e.path}/`))) {
      return { value: { kind: 'dir' as const, size: 0, mtimeMs: 8 * 3600_000, isLink: false } }
    }
    const text = FILES[e.path]
    if (text === undefined) throw new Error(`ENOENT ${e.path}`)
    return { value: { kind: 'file' as const, size: text.length, mtimeMs: 8 * 3600_000, isLink: false } }
  })
  on('fs.write', (_$, e) => {
    FILES[e.path] = e.text
    return { value: undefined }
  })
  on('fs.read', (_$, e) => {
    const text = FILES[e.path]
    if (text === undefined) throw new Error(`ENOENT ${e.path}`)
    return { value: text }
  })
}

async function itemNamed(ui: { find: (q: { key: string }) => Promise<{ props: Record<string, unknown>; text: string } | undefined> }, name: string) {
  for (let i = 0; i < 40; i++) if ((await ui.find({ key: `name-${i}` }))?.text.trim() === name) return `item-${i}`
  return undefined
}

async function focusedItem(ui: { find: (q: { key: string }) => Promise<{ props: Record<string, unknown> } | undefined> }) {
  for (let i = 0; i < 40; i++) if ((await ui.find({ key: `item-${i}` }))?.props.autoFocus === true) return i
  return -1
}


// Crumbs that link somewhere are drawn by a Client module, so their words live in its props.
async function trailHas(ui: { find: (q: { key: string }) => Promise<{ props: unknown } | undefined> }, pattern: RegExp) {
  const crumbs = await ui.find({ key: 'crumbs' })
  const segments = (crumbs?.props as { props?: { segments?: { text: string }[] } } | undefined)?.props?.segments ?? []
  return segments.some(one => pattern.test(one.text))
}

const props = PANE_PROPS

test('header, paged content and footer draw for a doc and a code file; Recent lists and reopens them', async ($, on) => {
  fakeDisk(on)
  for (const surface of ['terminal', 'desktop'] as const) {
    await $.command.run({ command: 'peek', args: `${WORKTREE}/docs/handoff.md` } as never)
    await $.command.run({ command: 'peek', args: `${WORKTREE}/crates/board-tui/src/app/board.rs:2` } as never)
    await $.command.run({ command: 'peek', args: `${WORKTREE}/docs/handoff.md` } as never)
    const ui = await $.ui.mount({ plugin: 'peek', surface, component: 'Pane', props, requestId: 'peek' })
    expect(await ui.find({ key: 'tabs-left' })).toBeDefined()
    expect(await ui.find({ key: 'tabs-right' })).toBeDefined()
    expect(await ui.find({ key: 'open' })).toBeDefined()
    expect(await ui.find({ text: /100% · § Handoff/ })).toBeDefined()
    expect(await trailHas(ui, /handoff\.md/)).toBe(true)
    expect(await trailHas(ui, /docs $/)).toBe(true)
    await ui.press({ key: 'mode-recent' })
    expect(await ui.find({ key: 'scope' })).toBeDefined()
    expect(await ui.find({ text: /2 files · session/ })).toBeDefined()
    expect(await itemNamed(ui, 'handoff.md')).toBe('item-0')
    expect(await itemNamed(ui, 'board.rs')).toBe('item-1')
    await ui.press({ key: 'item-1' })
    expect(await ui.find({ text: /line 1 of/ })).toBeDefined()
    expect(await trailHas(ui, /app/)).toBe(true)
    await ui.unmount()
  }
})

test('a long doc is one tall page: every block is drawn, keyed for j and k, with the header and footer pinned to the view', async ($, on) => {
  fakeDisk(on)
  const long = Array.from({ length: 30 }, (_, i) => `## Part ${i}\n\n${'word '.repeat(40)}`).join('\n\n')
  FILES['/repo/long.md'] = long
  await $.command.run({ command: 'peek', args: '/repo/long.md' } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ text: /^PART 0 $/ })).toBeDefined()
  expect(await ui.find({ text: /^PART 29 $/ })).toBeDefined()
  expect(await ui.find({ key: 'block-0' })).toBeDefined()
  expect(await ui.find({ key: 'block-59' })).toBeDefined()
  const tree = (await ui.drawn()) as unknown as { children: { props: { position?: string; top?: number } }[] }
  const pinned = tree.children.filter(child => child.props.position === 'absolute').map(child => child.props.top)
  expect(pinned).toEqual([0, props.scroll.bodyRows - 3])
  expect(await ui.find({ key: 'next' })).toBeDefined()
  expect(await ui.find({ key: 'prev' })).toBeDefined()
  await ui.unmount()
})

test('on the terminal, tasks are a mouse-driven list: hover lights a row, a click ticks the file', async ($, on) => {
  fakeDisk(on)
  FILES['/repo/todo.md'] = '# Todo\n\n- [ ] write it\n- [x] plan it\n\n![shot](missing.png)\n'
  await $.command.run({ command: 'peek', args: '/repo/todo.md' } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ text: /1\/2 tasks/ })).toBeDefined()
  expect(await ui.find({ text: /missing\.png/ })).toBeDefined()
  const client = 'tasks-2'
  await ui.resize({ columns: 60, rows: 2, in: client })
  expect(await ui.find({ text: 'write it', in: client })).toBeDefined()
  expect(await ui.find({ text: /^- /, in: client })).toBeUndefined()
  await ui.pointer({ type: 'enter', x: 4, y: 0, in: client })
  await ui.pointer({ type: 'move', x: 4, y: 0, in: client })
  const hot = '"color":"#d79921","strikethrough":true},"children":["write it"]'
  expect(JSON.stringify(await ui.drawn({ in: client }))).toContain(hot)
  await ui.pointer({ type: 'leave', x: 4, y: 0, in: client })
  expect(JSON.stringify(await ui.drawn({ in: client }))).not.toContain(hot)
  await ui.pointer({ type: 'down', button: 'left', x: 4, y: 0, in: client })
  expect(FILES['/repo/todo.md']).toContain('- [x] write it')
  expect(await ui.find({ text: /2\/2 tasks/ })).toBeDefined()
  await ui.unmount()
})

test('the desktop app draws tasks with the same mouse-driven list', async ($, on) => {
  fakeDisk(on)
  FILES['/repo/todo2.md'] = '- [ ] write it\n- [x] plan it\n'
  await $.command.run({ command: 'peek', args: '/repo/todo2.md' } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'desktop', component: 'Pane', props, requestId: 'peek' })
  await ui.resize({ columns: 60, rows: 2, in: 'tasks-1' })
  await ui.pointer({ type: 'down', button: 'left', x: 2, y: 1, in: 'tasks-1' })
  expect(FILES['/repo/todo2.md']).toContain('- [ ] plan it')
  await ui.unmount()
})

test('code, diagrams and images share one embed frame', async ($, on) => {
  fakeDisk(on)
  FILES['/repo/embeds.md'] = '# Embeds\n\n```rust\nfn main() {}\n```\n\n```mermaid\npie title Time\n  "a" : 1\n```\n\n![Logo](gone.png)\n'
  await $.command.run({ command: 'peek', args: '/repo/embeds.md' } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ text: /^CODE$/ })).toBeDefined()
  expect(await ui.find({ text: /^ rust$/ })).toBeDefined()
  expect(await ui.find({ text: /^DIAGRAM$/ })).toBeDefined()
  expect(await ui.find({ text: /pie · press o to see it rendered/ })).toBeDefined()
  expect(await ui.find({ text: /^IMAGE$/ })).toBeDefined()
  expect(await ui.find({ text: /^ Logo$/ })).toBeDefined()
  await ui.unmount()
})

test('a narrow pane drops the tabs and the side spacing but keeps the hidden keys; the footer keeps the doc info', async ($, on) => {
  fakeDisk(on)
  await $.command.run({ command: 'peek', args: `${WORKTREE}/docs/handoff.md` } as never)
  const narrow = { ...props, bodyColumns: 44 }
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: narrow, requestId: 'peek' })
  expect(await ui.find({ key: 'tabs-left' })).toBeUndefined()
  expect(await ui.find({ key: 'tabs-right' })).toBeUndefined()
  expect(await ui.find({ key: 'open' })).toBeDefined()
  expect(await trailHas(ui, /handoff\.md/)).toBe(true)
  expect(await ui.find({ text: /100% · § Handoff/ })).toBeDefined()
  await ui.unmount()
  const wide = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: { ...props, bodyColumns: 200 }, requestId: 'peek' })
  const page = (await wide.drawn()) as unknown as { children: { props: { width?: number; paddingX?: number }; children?: { props: { width?: number } }[] }[] }
  const card = page.children.find(child => child.props.paddingX === 2)
  expect(card?.props.width).toBe(199)
  expect(card?.children?.[0]?.props.width).toBe(104)
  await wide.unmount()
})

type Drawn = { type?: string; props?: Record<string, unknown>; children?: unknown[] }

function footerOf(tree: Drawn, bodyRows: number) {
  const pinned = (tree.children ?? []) as Drawn[]
  return pinned.find(child => child.props?.position === 'absolute' && child.props?.top === bodyRows - 3)
}

function shown(node: unknown): { buttons: string[]; texts: string[] } {
  if (typeof node === 'string') return { buttons: [], texts: [node] }
  const one = node as Drawn
  if (!one || one.props?.display === 'none') return { buttons: [], texts: [] }
  const inner = (one.children ?? []).map(shown)
  return {
    buttons: [...(one.type === 'Button' ? [String(one.props?.key)] : []), ...inner.flatMap(part => part.buttons)],
    texts: inner.flatMap(part => part.texts),
  }
}

test('every view shows only its status text and ⌃k menu in the footer, and the keys still press', async ($, on) => {
  fakeDisk(on)
  await $.command.run({ command: 'peek', args: `${WORKTREE}/docs/handoff.md` } as never)
  for (const bodyColumns of [100, 44]) {
    const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: { ...props, bodyColumns }, requestId: 'peek' })
    const footers: { buttons: string[]; texts: string[] }[] = []
    const look = async () => footers.push(shown(footerOf((await ui.drawn()) as unknown as Drawn, props.scroll.bodyRows)))
    await look()
    expect(await ui.find({ key: 'open' })).toBeDefined()
    await ui.press({ key: 'mode-recent' })
    expect(await ui.find({ text: /files · session/ })).toBeDefined()
    await look()
    await ui.press({ key: 'mode-gallery' })
    const before = (await ui.find({ text: / · session$/ }))?.text
    expect(before).toMatch(/ · session$/)
    await ui.press({ key: 'type' })
    await look()
    expect(footers.at(-1)?.texts[0]).toMatch(/ · session$/)
    expect(footers.at(-1)?.texts[0]).not.toBe(before)
    await ui.press({ key: 'mode-view' })
    expect(await ui.find({ text: /100% · § Handoff/ })).toBeDefined()
    expect(footers.length).toBe(3)
    for (const footer of footers) {
      expect(footer.buttons).toEqual([])
      expect(footer.texts.at(-1)).toBe('⌃k menu')
      expect(footer.texts.filter(text => text !== '│').length).toBe(2)
    }
    expect(footers[0]?.texts[0]).toMatch(/100% · § Handoff/)
    expect((await ui.find({ text: /^⌃k menu$/ }))?.props.color).toBe(C.accent)
    await ui.unmount()
  }
})

test('the ctrl+k menu lists the keys the footer no longer shows, each with its hotkey, only where they apply', async ($, on) => {
  fakeDisk(on)
  await $.command.run({ command: 'peek', args: `${WORKTREE}/docs/handoff.md` } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  await ui.press({ key: 'mode-gallery' })
  await $.command.run({ command: 'peek-menu' } as never)
  await ui.redraw()
  expect(await ui.find({ key: 'menu-key-type' })).toBeDefined()
  expect(await ui.find({ key: 'menu-key-sort' })).toBeDefined()
  expect(await ui.find({ key: 'menu-key-open-selected' })).toBeDefined()
  expect(await ui.find({ key: 'menu-key-star-selected' })).toBeDefined()
  expect(await ui.find({ key: 'menu-key-back' })).toBeUndefined()
  expect(await ui.find({ text: /^j k h l move$/ })).toBeDefined()
  expect((await ui.find({ key: 'menu-row-open' }))?.text).toMatch(/app$/)
  expect((await ui.find({ key: 'menu-row-key-open-selected' }))?.text).toMatch(/file ?o$/)
  await ui.press({ key: 'menu-key-type' })
  expect(await ui.find({ key: 'menu-filter' })).toBeUndefined()
  expect(await ui.find({ text: /markdown · session/ })).toBeDefined()
  await ui.press({ key: 'mode-view' })
  await $.command.run({ command: 'peek-menu' } as never)
  await ui.redraw()
  expect(await ui.find({ key: 'menu-key-type' })).toBeUndefined()
  expect(await ui.find({ key: 'menu-key-open-selected' })).toBeUndefined()
  expect(await ui.find({ key: 'menu-open' })).toBeDefined()
  expect(await ui.find({ text: /^j k move$/ })).toBeDefined()
  expect((await ui.find({ key: 'menu-row-open' }))?.text).toMatch(/app ?o$/)
  await $.command.run({ command: 'peek-menu' } as never)
  await ui.unmount()
})

test('ctrl+k opens a menu that filters and runs commands', async ($, on) => {
  fakeDisk(on)
  await $.command.run({ command: 'peek', args: `${WORKTREE}/docs/handoff.md` } as never)
  await $.command.run({ command: 'peek-menu' } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ key: 'menu-filter' })).toBeDefined()
  expect(await ui.find({ key: 'menu-recent' })).toBeDefined()
  await ui.input({ key: 'menu-filter', text: 'recent', kind: 'change' })
  expect(await ui.find({ key: 'menu-open' })).toBeUndefined()
  expect(await ui.find({ key: 'menu-recent' })).toBeDefined()
  await ui.input({ key: 'menu-filter', text: 'recent' })
  expect(await ui.find({ key: 'menu-filter' })).toBeUndefined()
  expect(await ui.find({ text: /files · session/ })).toBeDefined()
  await ui.unmount()
})

test('ctrl+k marks the closest match, which Enter runs', async ($, on) => {
  fakeDisk(on)
  await $.command.run({ command: 'peek', args: `${WORKTREE}/docs/handoff.md` } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  await $.command.run({ command: 'peek-menu' } as never)
  await ui.redraw()
  await ui.input({ key: 'menu-filter', text: 'gallery', kind: 'change' })
  await ui.redraw()
  expect((await ui.find({ key: 'menu-row-gallery' }))?.props.backgroundColor).toBeDefined()
  expect((await ui.find({ key: 'menu-row-recent' }))?.props.backgroundColor).toBeUndefined()
  await ui.input({ key: 'menu-filter', text: 'gallery' })
  await ui.redraw()
  expect(await ui.find({ key: 'menu-filter' })).toBeUndefined()
  await ui.unmount()
})

test('the scope switch lists the worktree, and the gallery shows its files as cards by type', async ($, on) => {
  fakeDisk(on)
  FILES['/repo/docs/plan.md'] = '# Plan\n'
  await $.command.run({ command: 'peek', args: '/repo/docs/plan.md' } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  await ui.press({ key: 'mode-recent' })
  expect(await ui.find({ text: /1 files · session/ })).toBeDefined()
  await ui.press({ key: 'scope' })
  await ui.redraw()
  expect(await ui.find({ text: /3 files · worktree/ })).toBeDefined()
  await ui.press({ key: 'mode-gallery' })
  expect(await ui.find({ text: /3 files · worktree/ })).toBeDefined()
  expect(await ui.find({ key: 'files-0' })).toBeDefined()
  await ui.press({ key: 'type' })
  expect(await ui.find({ text: /1 markdown · worktree/ })).toBeDefined()
  await ui.press({ key: 'type' })
  expect(await ui.find({ text: /1 code · worktree/ })).toBeDefined()
  await ui.press({ key: 'type' })
  expect(await ui.find({ text: /0 data · worktree/ })).toBeDefined()
  await ui.press({ key: 'type' })
  const png = await itemNamed(ui, 'x.png')
  expect(png).toBeDefined()
  expect(await ui.find({ key: 'open' })).toBeUndefined()
  await ui.press({ key: png ?? '' })
  expect(await ui.find({ key: 'open' })).toBeDefined()
  await ui.unmount()
})

test('cards are keyboard-navigable: h and l move along a row and stop at its ends, j and k move between rows, o opens', async ($, on) => {
  fakeDisk(on)
  FILES['/repo/docs/plan.md'] = '# Plan\n'
  await $.command.run({ command: 'peek', args: '/repo/docs/plan.md' } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: { ...props, bodyColumns: 70 }, requestId: 'peek' })
  await ui.press({ key: 'mode-recent' })
  await ui.press({ key: 'scope' })
  await ui.redraw()
  await ui.press({ key: 'mode-gallery' })
  expect(await focusedItem(ui)).toBe(0)
  await ui.press({ key: 'next' })
  expect(await focusedItem(ui)).toBe(1)
  expect(JSON.stringify(await ui.find({ key: 'name-1' }))).toContain('"color":"#d79921","bold":true')
  expect(JSON.stringify(await ui.find({ key: 'name-0' }))).toContain('"color":"#ebdbb2","bold":true')
  await ui.press({ key: 'right' })
  expect(await focusedItem(ui)).toBe(2)
  await ui.press({ key: 'right' })
  expect(await focusedItem(ui)).toBe(2)
  await ui.press({ key: 'next' })
  expect(await focusedItem(ui)).toBe(2)
  await ui.press({ key: 'prev' })
  expect(await focusedItem(ui)).toBe(0)
  await ui.press({ key: 'next' })
  expect(await focusedItem(ui)).toBe(1)
  await ui.press({ key: 'left' })
  expect(await focusedItem(ui)).toBe(1)
  await ui.press({ key: 'open-selected' })
  expect(await ui.find({ key: 'open' })).toBeDefined()
  await ui.unmount()
})

test('the header tabs switch between Peek, Recent and Gallery by mouse', async ($, on) => {
  fakeDisk(on)
  FILES['/repo/docs/plan.md'] = '# Plan\n'
  await $.command.run({ command: 'peek', args: '/repo/docs/plan.md' } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ key: 'open' })).toBeDefined()
  await ui.resize({ columns: 22, rows: 1, in: 'tabs-right' })
  await ui.pointer({ type: 'down', button: 'left', x: 2, y: 0, in: 'tabs-right' })
  expect(await ui.find({ text: /files · session/ })).toBeDefined()
  await ui.pointer({ type: 'down', button: 'left', x: 15, y: 0, in: 'tabs-right' })
  expect(await ui.find({ key: 'type' })).toBeDefined()
  await ui.resize({ columns: 8, rows: 1, in: 'tabs-left' })
  await ui.pointer({ type: 'down', button: 'left', x: 2, y: 0, in: 'tabs-left' })
  expect(await ui.find({ key: 'open' })).toBeDefined()
  await ui.unmount()
})

test('json is re-indented and summarised, csv is a table, toml is counted, and a folder lists its entries', async ($, on) => {
  fakeDisk(on)
  FILES['/repo/data/conf.json'] = '{"name":"peek","tags":["a","b"]}'
  FILES['/repo/data/people.csv'] = 'name,city\n"Lee, A",Cape Town\nB,Paris\n'
  FILES['/repo/data/app.toml'] = '[server]\nport = 1\n[[workers]]\n'
  FILES['/repo/data/sub/deep.md'] = '# Deep\n'
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })

  await $.command.run({ command: 'peek', args: '/repo/data/conf.json' } as never)
  await ui.redraw()
  expect(await ui.find({ text: /object · 2 keys/ })).toBeDefined()
  expect(JSON.stringify(await ui.drawn())).toContain('  \\"name\\": \\"peek\\"')

  await $.command.run({ command: 'peek', args: '/repo/data/people.csv' } as never)
  await ui.redraw()
  expect(await ui.find({ text: /2 rows × 2 columns/ })).toBeDefined()
  expect(await ui.find({ text: /^name +city *$/ })).toBeDefined()
  expect(await ui.find({ text: /^Lee, A +Cape Town *$/ })).toBeDefined()

  await $.command.run({ command: 'peek', args: '/repo/data/app.toml' } as never)
  await ui.redraw()
  expect(await ui.find({ text: /2 sections/ })).toBeDefined()

  await $.command.run({ command: 'peek', args: '/repo/data' } as never)
  await ui.redraw()
  expect(await ui.find({ text: /1 folders · 3 files/ })).toBeDefined()
  await ui.resize({ columns: 90, rows: 5, in: 'rows-0' })
  const listed = JSON.stringify(await ui.drawn({ in: 'rows-0' }))
  expect(listed.indexOf('..')).toBeLessThan(listed.indexOf('sub/'))
  expect(listed.indexOf('sub/')).toBeLessThan(listed.indexOf('app.toml'))
  await ui.pointer({ type: 'move', x: 1, y: 0, in: 'rows-0' })
  expect(JSON.stringify(await ui.drawn({ in: 'rows-0' }))).not.toContain('\u{f41e}')
  await ui.pointer({ type: 'move', x: 1, y: 2, in: 'rows-0' })
  expect(JSON.stringify(await ui.drawn({ in: 'rows-0' }))).toContain('\u{f41e}')
  await ui.pointer({ type: 'down', button: 'left', x: 4, y: 1, in: 'rows-0' })
  expect(await ui.find({ text: /0 folders · 1 files/ })).toBeDefined()
  await ui.resize({ columns: 90, rows: 2, in: 'rows-0' })
  await ui.pointer({ type: 'down', button: 'left', x: 0, y: 0, in: 'rows-0' })
  expect(await ui.find({ text: /1 folders · 3 files/ })).toBeDefined()
  await ui.unmount()
})

test('the role filter in Recent: a peeked file counts as touched, and each filter shows its own', async ($, on) => {
  fakeDisk(on)
  FILES['/repo/src/main.rs'] = 'fn main() {}\n'
  await $.command.run({ command: 'peek', args: '/repo/src/main.rs' } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  await ui.press({ key: 'mode-recent' })
  expect(await ui.find({ text: /1 files · session$/ })).toBeDefined()
  expect(await ui.find({ text: /^TOUCHED $/ })).toBeDefined()
  await ui.press({ key: 'role' })
  expect(await ui.find({ text: /0 files · session · artifacts/ })).toBeDefined()
  await ui.press({ key: 'role' })
  expect(await ui.find({ text: /1 files · session · touched/ })).toBeDefined()
  await ui.press({ key: 'role' })
  expect(await ui.find({ text: /1 files · session$/ })).toBeDefined()
  await ui.unmount()
})

test('stars: the agent tool and f on the selection or the open file all star; Recent shows favourites as cards above the list', async ($, on) => {
  fakeDisk(on)
  FILES['/repo/a.md'] = '# A\n'
  FILES['/repo/b.md'] = '# B\n'
  await $.command.run({ command: 'peek', args: '/repo/a.md' } as never)
  await $.command.run({ command: 'peek', args: '/repo/b.md' } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  await ui.press({ key: 'mode-recent' })
  expect(await ui.find({ key: 'favs-0' })).toBeUndefined()
  expect(await ui.find({ text: /0 favourites · 2 files/ })).toBeDefined()

  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc
  const answer = await $.tool.call({ tool: 'mcp__peek__star', target: '/repo/a.md' } as never)
  expect(JSON.stringify(answer)).toContain('Starred /repo/a.md')
  await ui.redraw()
  expect(await ui.find({ text: /1 favourites · 1 files/ })).toBeDefined()
  expect(await ui.find({ text: /^FAVOURITES $/ })).toBeDefined()
  expect(await itemNamed(ui, 'a.md')).toBe('item-0')
  expect(await itemNamed(ui, 'b.md')).toBe('item-1')
  expect(await ui.find({ key: 'item-2' })).toBeUndefined()

  expect(await focusedItem(ui)).toBe(0)
  await ui.press({ key: 'star-selected' })
  expect(await ui.find({ text: /0 favourites · 2 files/ })).toBeDefined()

  expect(await itemNamed(ui, 'b.md')).toBe('item-0')
  await ui.press({ key: 'star-selected' })
  expect(await ui.find({ text: /1 favourites · 1 files/ })).toBeDefined()

  await ui.press({ key: 'mode-view' })
  expect(await ui.find({ text: /\u{f51a} starred/u })).toBeDefined()
  await ui.press({ key: 'star' })
  expect(await ui.find({ text: /\u{f51a} starred/u })).toBeUndefined()
  await ui.press({ key: 'star' })
  expect(await ui.find({ text: /\u{f51a} starred/u })).toBeDefined()
  await ui.unmount()
})

test('ctrl+k draws the menu as a modal over a dimmed page', async ($, on) => {
  fakeDisk(on)
  await $.command.run({ command: 'peek', args: `${WORKTREE}/docs/handoff.md` } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  const before = JSON.stringify(await ui.drawn())
  expect(before).toContain('"key":"body-md-0","dimColor":false')
  await $.command.run({ command: 'peek-menu' } as never)
  const after = JSON.stringify(await ui.drawn())
  expect(await ui.find({ key: 'menu-filter' })).toBeDefined()
  expect(after).toContain('"key":"body-md-0","dimColor":true')
  expect(after).toContain('"position":"absolute"')
  expect(after).toContain('handoff')
  expect(after).not.toContain('"backgroundColor":"#262626"')
  await ui.unmount()
})

test('the gallery draws every element and its controls work', async ($, on) => {
  fakeDisk(on)
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ plugin: 'peek', surface, component: 'Pane', props, requestId: 'peek-ui' })
    for (const key of ['g-press', 'g-input', 'g-select', 'border-round']) {
      expect(await ui.find({ key })).toBeDefined()
    }
    await ui.press({ key: 'g-press' })
    expect((await ui.find({ key: 'g-press' }))?.props.label).toContain('1×')
    await ui.press({ key: 'g-reset' })
    await ui.input({ key: 'g-input', text: 'hello' })
    expect(await ui.find({ text: /Last submitted: hello/ })).toBeDefined()
    await ui.select({ key: 'g-select', value: 'double' })
    expect((await ui.find({ key: 'border-double' }))?.props.borderColor).toBe('green')
    if (surface === 'terminal') {
      expect(await ui.find({ key: 'g-raster' })).toBeDefined()
      expect(await ui.find({ key: 'g-client' })).toBeDefined()
    }
    await ui.unmount()
  }
})

test('Recent rows and Gallery cards: hover shows an accent star, a click anywhere opens, a click on the star stars', async ($, on) => {
  fakeDisk(on)
  FILES['/repo/a.md'] = '# A\n'
  FILES['/repo/b.md'] = '# B\n'
  await $.command.run({ command: 'peek', args: '/repo/a.md' } as never)
  await $.command.run({ command: 'peek', args: '/repo/b.md' } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  await ui.press({ key: 'mode-recent' })
  const layer = 'hover-touched-0'
  await ui.resize({ columns: 80, rows: 2, in: layer })
  expect(JSON.stringify(await ui.drawn({ in: layer }))).not.toContain('\u{f41e}')
  await ui.pointer({ type: 'move', x: 20, y: 1, in: layer })
  const hovered = JSON.stringify(await ui.drawn({ in: layer }))
  expect(hovered).toContain('\u{f41e}')
  expect(hovered).toContain(C.accent)
  await ui.pointer({ type: 'down', button: 'left', x: 30, y: 1, in: layer })
  expect(await ui.find({ text: /^# ?A$|^A$/ })).toBeDefined()

  await ui.press({ key: 'mode-gallery' })
  const cards = 'hover-touched-0'
  await ui.resize({ columns: 60, rows: 5, in: cards })
  await ui.pointer({ type: 'move', x: 10, y: 3, in: cards })
  expect(JSON.stringify(await ui.drawn({ in: cards }))).toContain('\u{f41e}')
  await ui.pointer({ type: 'down', button: 'left', x: 2, y: 1, in: cards })
  expect(JSON.stringify(await ui.drawn())).toContain('\u{f51a}')
  await ui.unmount()
})

test('the hover star paints over Recent rows and every row of Gallery cards, and its click stars that item', async ($, on) => {
  fakeDisk(on)
  const names = ['c1', 'c2', 'c3', 'c4', 'c5', 'c6', 'c7']
  for (const name of names) FILES[`/repo/${name}.md`] = `# ${name}\n`
  for (const name of names) await $.command.run({ command: 'peek', args: `/repo/${name}.md` } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  await ui.press({ key: 'mode-recent' })
  const recent = hoverLayers(await ui.drawn())
  expect(recent.onTop).toContain('hover-touched-0')
  expect(recent.buried).toEqual([])

  await ui.press({ key: 'mode-gallery' })
  const gallery = hoverLayers(await ui.drawn())
  expect(gallery.onTop).toEqual(expect.arrayContaining(['hover-touched-0', 'hover-touched-1']))
  expect(gallery.buried).toEqual([])
  const second = 'hover-touched-1'
  await ui.resize({ columns: 60, rows: 5, in: second })
  await ui.pointer({ type: 'move', x: 3, y: 2, in: second })
  const hovered = JSON.stringify(await ui.drawn({ in: second }))
  expect(hovered).toContain('\u{f41e}')
  expect(hovered).toContain(C.accent)
  expect(hovered).toContain('"top":1,"left":2')
  await ui.pointer({ type: 'down', button: 'left', x: 2, y: 1, in: second })
  expect(JSON.stringify(await ui.drawn())).toContain('\u{f51a}')
  await ui.unmount()
})

test('a markdown table draws as aligned columns under an accent header', async ($, on) => {
  fakeDisk(on)
  FILES['/repo/notes/table.md'] = ['# Plan', '', '| Step | Owner | Days |', '|------|-------|-----:|', '| Build | **Ana** | 3 |', '| Ship | Bo | 12 |'].join('\n')
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })

  await $.command.run({ command: 'peek', args: '/repo/notes/table.md' } as never)
  await ui.redraw()
  const page = JSON.stringify(await ui.drawn())
  expect(page).toMatch(/\["Step +Owner +Days"\]/)
  expect(page).toMatch(/\["Build +Ana +   3"\]/)
  expect(page).toMatch(/\["Ship +Bo +  12"\]/)
  expect(page).not.toContain('|------|')
  await ui.unmount()
})

test('a table too wide for the pane stacks each row as label and value lines; a wide pane keeps the grid', async ($, on) => {
  fakeDisk(on)
  FILES['/repo/notes/wide.md'] = ['| Step | Owner | Notes |', '|---|---|---|', '| Build | Ana | wire the parser into the remote view and the file view |', '| Ship | Bo | tag it |'].join('\n')
  await $.command.run({ command: 'peek', args: '/repo/notes/wide.md' } as never)
  const narrow = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: { ...props, bodyColumns: 44 }, requestId: 'peek' })
  const stacked = JSON.stringify(await narrow.drawn())
  expect(stacked).not.toMatch(/Step +Owner +Notes/)
  expect(stacked).toContain('["Notes"]')
  expect(stacked).toContain('["wire the parser into the remote view and the file view"]')
  expect(stacked).toContain('["Bo"]')
  await narrow.unmount()

  const wide = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: { ...props, bodyColumns: 140 }, requestId: 'peek' })
  expect(JSON.stringify(await wide.drawn())).toMatch(/\["Step +Owner +Notes +"\]/)
  await wide.unmount()
})

test('a bullet list in a markdown file draws with an accent arrow instead of a dash', async ($, on) => {
  fakeDisk(on)
  FILES['/repo/notes/list.md'] = ['# List', '', '- alpha', '- beta with `code`', '  - inner'].join('\n')
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  await $.command.run({ command: 'peek', args: '/repo/notes/list.md' } as never)
  await ui.redraw()
  const page = JSON.stringify(await ui.drawn())
  expect(page).toContain(`"color":"${C.accent}"},"children":["\u23f5 "]`)
  expect(page).toContain('"text":"alpha"')
  expect(page).toContain('"text":"beta with `code`"')
  expect(page).toContain('"text":"inner"')
  expect(page).not.toContain('- alpha')
  await ui.unmount()
})

test('the header trail is clickable: a click on the folder crumb opens that folder, and b comes back to the file', async ($, on) => {
  fakeDisk(on)
  FILES['/repo/notes/trail.md'] = '# Trail\n\nBody.'
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  await $.command.run({ command: 'peek', args: '/repo/notes/trail.md' } as never)
  await ui.redraw()
  const crumbs = await ui.find({ key: 'crumbs' })
  const segments = (crumbs?.props as { props: { segments: { text: string; crumb: number }[]; presses: unknown[] } }).props
  expect(segments.presses).toEqual([{ go: 'file:///repo' }, { go: 'file:///repo/notes' }, null])
  let x = 0
  for (const one of segments.segments) {
    if (one.crumb === 1) break
    x += [...one.text].length
  }
  await ui.pointer({ type: 'down', button: 'left', x: x + 1, y: 0, in: 'crumbs' } as never)
  await ui.redraw()
  expect(JSON.stringify(await ui.drawn())).toMatch(/notes/)
  expect(JSON.stringify(await ui.drawn())).not.toContain('TRAIL')
  await ui.press({ key: 'back' })
  await ui.redraw()
  expect(JSON.stringify(await ui.drawn())).toContain('TRAIL')
  await ui.unmount()
})

test('while peek has the keyboard and a page to go back to, the pane arms Esc; unfocused, or with nothing to go back to, it does not', async ($, on) => {
  FILES['/repo/notes/first.md'] = '# First\n\nOne.'
  FILES['/repo/notes/second.md'] = '# Second\n\nTwo.'
  const opens: { title?: string; closeOnEscape?: boolean }[] = []
  on('ui.open', { id: 'peek' }, ($, e, next) => {
    opens.push(e as { title?: string; closeOnEscape?: boolean })
    return next(e)
  })
  fakeDisk(on)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  await $.command.run({ command: 'peek', args: '/repo/notes/first.md' } as never)
  await ui.redraw()
  expect(opens.at(-1)?.closeOnEscape).toBeUndefined()

  await ui.post({ go: 'file:///repo/notes/second.md' } as never, { in: 'crumbs' } as never)
  await ui.redraw()
  expect(JSON.stringify(await ui.drawn())).toContain('SECOND')
  expect(opens.at(-1)).toEqual({ id: 'peek', title: 'second.md', closeOnEscape: true })

  await ui.redraw({ ...props, isFocused: false } as never)
  expect(opens.at(-1)).toEqual({ id: 'peek', title: 'second.md' })

  await ui.redraw(props as never)
  expect(opens.at(-1)?.closeOnEscape).toBe(true)
  await ui.press({ key: 'back' })
  await ui.redraw()
  expect(JSON.stringify(await ui.drawn())).toContain('FIRST')
  expect(opens.at(-1)?.closeOnEscape).toBeUndefined()
  await ui.unmount()
})

test('an html file reads as markdown, and a code file opened at a line starts ten lines above it', async ($, on) => {
  fakeDisk(on)
  FILES['/repo/site/page.html'] = '<html><body><h1>Hello page</h1><p>Some <b>bold</b> words</p></body></html>'
  FILES['/repo/src/long.ts'] = Array.from({ length: 40 }, (_, i) => `const line${i + 1} = ${i + 1}`).join('\n')
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })

  await $.command.run({ command: 'peek', args: '/repo/site/page.html' } as never)
  await ui.redraw()
  const page = JSON.stringify(await ui.drawn())
  expect(page).toContain('HELLO PAGE')
  expect(page).toContain('"text":"Some bold words"')

  await $.command.run({ command: 'peek', args: '/repo/src/long.ts:15' } as never)
  await ui.redraw()
  const code = JSON.stringify(await ui.drawn())
  expect(code).toContain('"startLine":5')
  expect(code).toContain('const line5 = 5')
  expect(code).not.toContain('const line4 = 4')
  expect(code).toContain('line 5 of 40')
  await ui.unmount()
})
