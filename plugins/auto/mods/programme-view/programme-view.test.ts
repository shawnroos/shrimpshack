import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'

const DATA = '/data'
const HOME = `${DATA}/programmes/prog-1`
const VIEW = `${HOME}/views/view.json`
const LEASES = `${DATA}/programmes/leases`

function viewText(rows: { style: string; text: string }[], format = 1) {
  return JSON.stringify({ view_format: format, run: 'prog-1', generated_at: '2026-10-07T00:00:00Z', model: {}, rows })
}

function world(on: On, files: Record<string, string>, mtimes: Record<string, number>) {
  mock.env(on, { CLAUDE_AUTO_DATA_DIR: DATA })
  on('session.id', () => ({ value: 'sess-pm' }))
  on('command.register', () => ({ value: { command: 'programme-view' } }))
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  on('fs.list', (_$, e) => ({
    value: Object.keys(files)
      .filter(path => path.startsWith(`${e.path}/`))
      .map(path => ({ name: path.slice(e.path.length + 1), kind: 'file' as const, size: 1, mtimeMs: 1, isLink: false })),
  }))
  on('fs.read', (_$, e) => {
    if (!(e.path in files)) throw new Error('ENOENT')
    return { value: files[e.path] ?? '' }
  })
  on('fs.stat', (_$, e) => {
    if (!(e.path in files)) throw new Error('ENOENT')
    return { value: { kind: 'file' as const, size: 1, mtimeMs: mtimes[e.path] ?? 1, isLink: false } }
  })
}

async function mountPane($: Engine) {
  return $.ui.mount({
    plugin: 'auto',
    surface: 'terminal',
    component: 'Pane',
    requestId: 'programme-view',
    props: { title: 'Programme', isFocused: false },
  } as never)
}

test('a session that drives no programme gets no pane', async ($, on) => {
  world(on, { [`${LEASES}/default__w2.json`]: JSON.stringify({ session_id: 'sess-other', run: 'prog-1', home: HOME }) }, {})
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  const ran = await $.command.run({ command: 'programme-view' } as never)
  expect(ran.text).toContain('drives no auto programme')
})

test("the pane draws the view rows from this session's programme and redraws on change", async ($, on) => {
  const clock = mock.clock(on)
  const files: Record<string, string> = {
    [`${LEASES}/default__w2.json`]: JSON.stringify({ session_id: 'sess-pm', run: 'prog-1', home: HOME }),
    [VIEW]: viewText([
      { style: 'head', text: 'Who waits on whom' },
      { style: 'warn', text: '  herdr:w2-p3 waits on ci (unwatched)' },
    ]),
  }
  const mtimes: Record<string, number> = { [VIEW]: 1000 }
  world(on, files, mtimes)
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  const ran = await $.command.run({ command: 'programme-view' } as never)
  expect(ran.text).toContain('opened')

  const pane = await mountPane($)
  expect(await pane.find({ type: 'Text', text: /waits on ci \(unwatched\)/ })).toBeDefined()

  files[VIEW] = viewText([
    { style: 'head', text: 'Who waits on whom' },
    { style: 'text', text: '  herdr:w2-p3 waits on ci (watched)' },
  ])
  mtimes[VIEW] = 2000
  await clock.advance(2000)
  expect(await pane.find({ type: 'Text', text: /waits on ci \(watched\)/ })).toBeDefined()
})

test('a view of another format is reported, not drawn', async ($, on) => {
  world(on, {
    [`${LEASES}/default__w2.json`]: JSON.stringify({ session_id: 'sess-pm', run: 'prog-1', home: HOME }),
    [VIEW]: viewText([{ style: 'text', text: 'old row' }], 99),
  }, {})
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  await $.command.run({ command: 'programme-view' } as never)
  const pane = await mountPane($)
  expect(await pane.find({ type: 'Text', text: /view format 99/ })).toBeDefined()
  expect(await pane.find({ type: 'Text', text: 'old row' })).toBeUndefined()
})

test('a lease whose home does not match its run is ignored', async ($, on) => {
  world(on, { [`${LEASES}/default__w2.json`]: JSON.stringify({ session_id: 'sess-pm', run: 'prog-1', home: '/elsewhere' }) }, {})
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  const ran = await $.command.run({ command: 'programme-view' } as never)
  expect(ran.text).toContain('drives no auto programme')
})
