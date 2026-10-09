import { expect, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const WORKTREE = '/Users/shawnroos/projects/herdr-linear-board/worktrees/tui-design'
const FILES: Record<string, string> = {
  [`${WORKTREE}/docs/handoff.md`]: '# Handoff\n\nIntro.\n\n## Goals\n\nShip it.\n\n## Risks\n\nNone.\n',
  [`${WORKTREE}/crates/board-tui/src/app/board.rs`]: 'fn main() {\n    println!("hi");\n}\n',
}

function fakeDisk(on: On) {
  on('session.cwd', () => ({ value: '/repo' }))
  on('env.get', () => ({ value: '/home' }))
  on('clock.now', () => ({ value: 10 * 3600_000 }))
  on('ui.open', () => ({ value: { isPlaced: true as const } }))
  on('ui.toast', () => ({ value: undefined }))
  on('process.run', (_$, e) => {
    const ok = (stdout: string) => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } })
    if (e.argv[0] === 'git' && e.argv.includes('rev-parse')) return ok('/repo\n/repo/.git\n/repo/.git\n')
    if (e.argv[0] === 'sh') return ok('1700000000 1200 docs/plan.md\n1700000500 90 src/a.rs\n1700000100 5000 shots/x.png\n')
    return { value: { exitCode: 1, stdout: '', stderr: 'unexpected', isStdoutTruncated: false, isStderrTruncated: false } }
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

const props = {
  title: 'Peek',
  isFocused: true,
  bodyColumns: 100,
  placement: 'dock' as const,
  scroll: { offset: 0, bodyRows: 40 },
  view: {},
}

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
    expect(await ui.find({ text: /handoff\.md/ })).toBeDefined()
    expect(await ui.find({ text: /docs $/ })).toBeDefined()
    await ui.press({ key: 'mode-recent' })
    expect(await ui.find({ key: 'scope' })).toBeDefined()
    expect(await ui.find({ text: /2 files · session/ })).toBeDefined()
    expect(await itemNamed(ui, 'handoff.md')).toBe('item-0')
    expect(await itemNamed(ui, 'board.rs')).toBe('item-1')
    await ui.press({ key: 'item-1' })
    expect(await ui.find({ text: /line 1 of/ })).toBeDefined()
    expect(await ui.find({ text: /app/ })).toBeDefined()
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

test('a narrow pane drops the tabs, the keys and the side spacing; the footer keeps the doc info', async ($, on) => {
  fakeDisk(on)
  await $.command.run({ command: 'peek', args: `${WORKTREE}/docs/handoff.md` } as never)
  const narrow = { ...props, bodyColumns: 44 }
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: narrow, requestId: 'peek' })
  expect(await ui.find({ key: 'tabs-left' })).toBeUndefined()
  expect(await ui.find({ key: 'tabs-right' })).toBeUndefined()
  expect(await ui.find({ key: 'open' })).toBeUndefined()
  expect(await ui.find({ text: /handoff\.md/ })).toBeDefined()
  expect(await ui.find({ text: /100% · § Handoff/ })).toBeDefined()
  await ui.unmount()
  const wide = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: { ...props, bodyColumns: 200 }, requestId: 'peek' })
  const page = (await wide.drawn()) as unknown as { children: { props: { width?: number; paddingX?: number } }[] }
  const card = page.children.find(child => child.props.paddingX === 2)
  expect(card?.props.width).toBe(104 + 4)
  await wide.unmount()
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
  expect(before).toContain('"key":"body-2-0","dimColor":false')
  await $.command.run({ command: 'peek-menu' } as never)
  const after = JSON.stringify(await ui.drawn())
  expect(await ui.find({ key: 'menu-filter' })).toBeDefined()
  expect(after).toContain('"key":"body-2-0","dimColor":true')
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
