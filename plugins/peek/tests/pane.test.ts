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
  on('fs.stat', (_$, e) => {
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
    expect(await ui.find({ text: /PEEK/ })).toBeDefined()
    expect(await ui.find({ text: /RECENT/ })).toBeDefined()
    expect(await ui.find({ key: 'open' })).toBeDefined()
    expect(await ui.find({ text: /100% · § Handoff/ })).toBeDefined()
    expect(await ui.find({ text: /handoff\.md/ })).toBeDefined()
    expect(await ui.find({ text: /docs $/ })).toBeDefined()
    await ui.press({ key: 'mode-recent' })
    expect(await ui.find({ text: /RECENT 2/ })).toBeDefined()
    expect(String((await ui.find({ key: 'recent-0' }))?.props.label)).toBe('handoff.md')
    expect(String((await ui.find({ key: 'recent-1' }))?.props.label)).toBe('board.rs')
    await ui.press({ key: 'recent-1' })
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
  expect(await ui.find({ text: /PEEK/ })).toBeUndefined()
  expect(await ui.find({ text: /RECENT/ })).toBeUndefined()
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
  expect(await ui.find({ text: /files mentioned|RECENT/ })).toBeDefined()
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
