import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'
import { groupsDir } from '../hooks/groups'
import { resetRefresh } from '../hooks/refresh'
import { pullView } from './fixtures/github/items'

const HOME = '/home'
const PR = 'https://github.com/acme/widgets/pull/42'
const LINEAR = 'https://linear.app/acme/issue/WEB-12'
const PAGE = 'https://example.test/page'

type World = {
  files: Record<string, string>
  dirs: Map<string, number>
  log: string[][]
  now: number
  root: string
  commonDirs: Record<string, string>
  invalidated: number
  toasts: string[]
  isMvBroken: boolean
  onLockBusy?: (lock: string) => void
  onRun?: (argv: string[]) => Promise<RunAnswer | undefined> | RunAnswer | undefined
  onFetch?: (url: string) => { status: number; text?: string } | Error | undefined
}

type RunAnswer = { exitCode: number; stdout?: string; stderr?: string }

function groupsWorld(on: On, files: Record<string, string> = {}, options: { isClockMocked?: boolean } = {}): World {
  resetRefresh()
  const w: World = {
    files: { '/repo/docs/plan.md': '# Plan\n', '/repo/notes/todo.md': 'todo\n', '/home/notes.md': 'mine\n', ...files },
    dirs: new Map(),
    log: [],
    now: 10 * 3600_000,
    root: '/repo',
    commonDirs: { '/repo': '/repo/.git', '/wt/feature': '/repo/.git', '/other': '/other/.git' },
    invalidated: 0,
    toasts: [],
    isMvBroken: false,
  }
  const done = (exitCode: number, stdout = '') => ({ value: { exitCode, stdout, stderr: exitCode ? 'failed' : '', isStdoutTruncated: false, isStderrTruncated: false } })
  const isDir = (path: string) => w.dirs.has(path) || Object.keys(w.files).some(one => one.startsWith(`${path}/`))
  on('session.id', () => ({ value: 'groups-pane' }))
  on('session.cwd', () => ({ value: w.root }))
  on('session.root', () => ({ value: w.root }))
  on('env.get', (_$, e) => ({ value: e.name === 'HOME' ? HOME : undefined }))
  if (!options.isClockMocked) {
    on('clock.now', () => ({ value: w.now }))
    on('clock.sleep', (_$, e) => {
      w.now += (e as { ms?: number }).ms ?? 0
      return { value: undefined }
    })
  }
  on('ui.open', () => ({ value: { isPlaced: true as const } }))
  on('ui.toast', (_$, e) => {
    w.toasts.push(e.text)
    return { value: undefined }
  })
  on('ui.invalidate', () => {
    w.invalidated++
    return { value: undefined }
  })
  on('http.fetch', (_$, e) => {
    const answer = w.onFetch?.(e.url) ?? { status: 404 }
    if (answer instanceof Error) throw answer
    return { value: { status: answer.status, ok: answer.status < 300, headers: {}, text: answer.text ?? '' } }
  })
  on('process.run', async (_$, e) => {
    const argv = [...e.argv]
    w.log.push(['run', ...argv])
    const custom = await w.onRun?.(argv)
    if (custom) return { value: { stdout: '', stderr: '', ...custom, isStdoutTruncated: false, isStderrTruncated: false } }
    const [bin = '', ...rest] = argv
    if (bin === 'git' && argv.includes('--git-common-dir') && !argv.includes('--show-toplevel')) {
      const dir = rest[rest.indexOf('-C') + 1] ?? ''
      const common = w.commonDirs[dir]
      return common ? done(0, `${common}\n`) : done(128)
    }
    if (bin === 'git' && argv.includes('--show-toplevel')) {
      const dir = rest[rest.indexOf('-C') + 1] ?? ''
      const top = Object.keys(w.commonDirs).find(one => dir === one || dir.startsWith(`${one}/`))
      return top ? done(0, `${top}\n${top}/.git\n${w.commonDirs[top]}\n`) : done(128)
    }
    if (bin === 'mkdir' && rest[0] === '-p') {
      w.dirs.set(rest[1] ?? '', w.now)
      return done(0)
    }
    if (bin === 'mkdir') {
      const lock = rest[0] ?? ''
      if (w.dirs.has(lock)) {
        w.onLockBusy?.(lock)
        return done(1)
      }
      w.dirs.set(lock, w.now)
      return done(0)
    }
    if (bin === 'rmdir') {
      w.dirs.delete(rest[0] ?? '')
      return done(0)
    }
    if (bin === 'mv' && rest[0] === '-f') {
      const [, from = '', to = ''] = rest
      if (w.isMvBroken || w.files[from] === undefined) return done(1)
      w.files[to] = w.files[from]
      delete w.files[from]
      return done(0)
    }
    if (bin === 'rm' && rest[0] === '-f') {
      delete w.files[rest[1] ?? '']
      return done(0)
    }
    return done(1)
  })
  on('fs.read', (_$, e) => {
    const text = w.files[e.path]
    if (text === undefined) throw new Error(`ENOENT ${e.path}`)
    return { value: text }
  })
  on('fs.write', (_$, e) => {
    w.log.push(['write', e.path])
    w.files[e.path] = e.text
    return { value: undefined }
  })
  on('fs.exists', (_$, e) => ({ value: w.files[e.path] !== undefined || isDir(e.path) }))
  on('fs.stat', (_$, e) => {
    if (w.files[e.path] !== undefined) return { value: { kind: 'file' as const, size: w.files[e.path]?.length ?? 0, mtimeMs: 8 * 3600_000, isLink: false } }
    if (isDir(e.path)) return { value: { kind: 'dir' as const, size: 0, mtimeMs: w.dirs.get(e.path) ?? 8 * 3600_000, isLink: false } }
    throw new Error(`ENOENT ${e.path}`)
  })
  on('fs.list', (_$, e) => {
    if (!isDir(e.path)) throw new Error(`ENOENT ${e.path}`)
    const prefix = `${e.path}/`
    const names = new Map<string, boolean>()
    for (const path of [...Object.keys(w.files), ...w.dirs.keys()]) {
      if (!path.startsWith(prefix)) continue
      const [first = '', ...more] = path.slice(prefix.length).split('/')
      names.set(first, more.length > 0 || w.dirs.has(`${prefix}${first}`) || names.get(first) === true)
    }
    return { value: [...names].map(([name, isFolder]) => ({ name, kind: isFolder ? ('dir' as const) : ('file' as const), size: 0, mtimeMs: 0, isLink: false })) }
  })
  return w
}

type ToolAnswer = { result?: unknown; deny?: string }

async function call($: { tool: { call: (input: never) => Promise<unknown> } }, tool: string, input: Record<string, unknown>): Promise<string> {
  const answer = (await $.tool.call({ tool: `mcp__peek__${tool}`, tool_use_id: `${tool}-${Math.random()}`, ...input } as never)) as ToolAnswer
  return String(answer.result ?? answer.deny ?? '')
}

function jsonOf(text: string): Record<string, unknown> {
  return JSON.parse(text.slice(text.indexOf('\n') + 1)) as Record<string, unknown>
}

const dirOf = (projectKey: string) => groupsDir(HOME, projectKey)

function savedGroup(w: World, id: string, projectKey = '/repo/.git') {
  const text = w.files[`${dirOf(projectKey)}/${id}.json`]
  return text === undefined ? undefined : (JSON.parse(text) as { items: { ref: string; addedBy: string }[]; starred: boolean; title: string })
}

async function create($: Parameters<typeof call>[0], add: unknown[], title = 'Launch') {
  const text = await call($, 'save_group', { title, add })
  const id = String(jsonOf(text).id)
  return { text, id }
}

test('save_group with mixed targets creates a group; read_group returns every item, the repo files repo-relative', async ($, on) => {
  const w = groupsWorld(on)
  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc
  on('tool.call', async () => ({ result: [{ type: 'text', text: '{"identifier":"WEB-12","url":"https://linear.app/acme/issue/WEB-12/fix-login"}' }] }) as never)
  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc
  await $.tool.call({ tool: 'mcp__claude_ai_Linear__get_issue', tool_use_id: 'l1', id: 'WEB-12' } as never)
  const { text, id } = await create($, [
    { target: '/repo/docs/plan.md' },
    { target: 'notes/todo.md' },
    { target: `${PR}/files` },
    { target: 'WEB-12' },
    { target: PAGE },
    { target: '/home/notes.md' },
  ])
  expect(text.split('\n')[0]).toMatch(/^Created group "Launch" \([0-9a-z]{8}\)/)
  expect(id).toMatch(/^[0-9a-z]{8}$/)
  const read = jsonOf(await call($, 'read_group', { id })) as { items: Record<string, unknown>[] }
  expect(read.items.map(one => one.ref)).toEqual(['docs/plan.md', 'notes/todo.md', PR, LINEAR, PAGE, 'file:///home/notes.md'])
  expect(read.items.every(one => one.addedBy === 'agent' && one.state === 'ok' && one.title === null)).toBe(true)
  expect(savedGroup(w, id)?.items.map(one => one.ref)).toEqual(['docs/plan.md', 'notes/todo.md', PR, LINEAR, PAGE, 'file:///home/notes.md'])
  expect(JSON.parse(w.files[`${dirOf('/repo/.git')}/${id}.json`] ?? '{}').projectKey).toBe('/repo/.git')
})

test('a batch with one nonexistent file adds the others and rejects that one with its reason', async ($, on) => {
  const w = groupsWorld(on)
  const { text, id } = await create($, [{ target: 'docs/plan.md' }, { target: 'docs/gone.md' }, { target: PAGE }])
  const outcomes = jsonOf(text).outcomes as { op: string; status: string; reason: string; ref?: string }[]
  const gone = outcomes.find(one => one.ref === 'docs/gone.md')
  expect(gone?.status).toBe('refused')
  expect(gone?.reason).toMatch(/No file or URL at docs\/gone\.md/)
  expect(savedGroup(w, id)?.items.map(one => one.ref)).toEqual(['docs/plan.md', PAGE])
  expect(text.split('\n')[0]).toMatch(/1 refused/)
})

test('each write takes the lock, writes a staged file, moves it over the group file, then releases the lock', async ($, on) => {
  const w = groupsWorld(on)
  const { id } = await create($, [{ target: PAGE }])
  const file = `${dirOf('/repo/.git')}/${id}.json`
  w.log = []
  await call($, 'save_group', { id, add: [{ target: 'docs/plan.md' }] })
  const steps = w.log
    .map(one => one.join(' '))
    .filter(one => one.includes(`${id}.json`))
  expect(steps).toEqual([
    `run mkdir ${file}.lock`,
    `write ${file}.staged`,
    `run mv -f ${file}.staged ${file}`,
    `run rmdir ${file}.lock`,
  ])
})

test('a save started while another session holds the lock waits, re-reads, and both changes land', async ($, on) => {
  const w = groupsWorld(on)
  const { id } = await create($, [{ target: PAGE }])
  const file = `${dirOf('/repo/.git')}/${id}.json`
  w.dirs.set(`${file}.lock`, w.now)
  w.onLockBusy = lock => {
    const group = JSON.parse(w.files[file] ?? '{}')
    group.items.push({ ref: 'notes/todo.md', addedBy: 'person', addedAt: w.now })
    w.files[file] = JSON.stringify(group)
    w.dirs.delete(lock)
    w.onLockBusy = undefined
  }
  w.log = []
  const text = await call($, 'save_group', { id, add: [{ target: 'docs/plan.md' }] })
  expect(text).not.toMatch(/busy/)
  expect(w.log.filter(one => one.join(' ') === `run mkdir ${file}.lock`).length).toBe(2)
  expect(savedGroup(w, id)?.items.map(one => `${one.ref}:${one.addedBy}`)).toEqual([`${PAGE}:agent`, 'notes/todo.md:person', 'docs/plan.md:agent'])
})

test('two saves from this session to one group queue in process, so neither waits on the lock and both land', async ($, on) => {
  const w = groupsWorld(on)
  const { id } = await create($, [{ target: PAGE }])
  const file = `${dirOf('/repo/.git')}/${id}.json`
  w.log = []
  await Promise.all([call($, 'save_group', { id, add: [{ target: 'docs/plan.md' }] }), call($, 'save_group', { id, add: [{ target: 'notes/todo.md' }] })])
  expect(w.log.filter(one => one.join(' ') === `run mkdir ${file}.lock`).length).toBe(2)
  expect(savedGroup(w, id)?.items.map(one => one.ref).sort()).toEqual(['docs/plan.md', 'notes/todo.md', PAGE].sort())
})

test('a lock older than 10 s is broken and the write proceeds', async ($, on) => {
  const w = groupsWorld(on)
  const { id } = await create($, [{ target: PAGE }])
  const file = `${dirOf('/repo/.git')}/${id}.json`
  w.dirs.set(`${file}.lock`, w.now - 11_000)
  const text = await call($, 'save_group', { id, add: [{ target: 'docs/plan.md' }] })
  expect(text).not.toMatch(/busy/)
  expect(savedGroup(w, id)?.items.map(one => one.ref)).toEqual([PAGE, 'docs/plan.md'])
  expect(w.dirs.has(`${file}.lock`)).toBe(false)
})

test('a fresh lock held past 2 s refuses the save as busy, and nothing reports the item as added', async ($, on) => {
  const w = groupsWorld(on)
  const { id } = await create($, [{ target: PAGE }])
  const file = `${dirOf('/repo/.git')}/${id}.json`
  w.dirs.set(`${file}.lock`, w.now)
  const started = w.now
  const text = await call($, 'save_group', { id, add: [{ target: 'docs/plan.md' }] })
  expect(text).toMatch(/busy, try again/)
  expect(text).not.toMatch(/added|applied/i)
  expect(w.now - started).toBeGreaterThanOrEqual(2000)
  expect(savedGroup(w, id)?.items.map(one => one.ref)).toEqual([PAGE])
  expect(w.dirs.has(`${file}.lock`)).toBe(true)
})

test('a failing mv makes save_group return an error, and nothing reports the item as added', async ($, on) => {
  const w = groupsWorld(on)
  const { id } = await create($, [{ target: PAGE }])
  const file = `${dirOf('/repo/.git')}/${id}.json`
  w.isMvBroken = true
  const text = await call($, 'save_group', { id, add: [{ target: 'docs/plan.md' }] })
  expect(text).toMatch(/^Could not save/)
  expect(text).not.toMatch(/added|applied/i)
  expect(savedGroup(w, id)?.items.map(one => one.ref)).toEqual([PAGE])
  expect(w.files[`${file}.staged`]).toBeUndefined()
  expect(w.dirs.has(`${file}.lock`)).toBe(false)
})

test('a main checkout and a linked worktree share a project key; another project does not see the group', async ($, on) => {
  const w = groupsWorld(on)
  const { id } = await create($, [{ target: PAGE }])
  expect(w.log.some(one => one.join(' ') === 'run git -C /repo rev-parse --path-format=absolute --git-common-dir')).toBe(true)
  w.root = '/wt/feature'
  const fromWorktree = jsonOf(await call($, 'list_groups', {})) as unknown as { id: string }[]
  expect(fromWorktree.map(one => one.id)).toEqual([id])
  w.root = '/other'
  const fromOther = await call($, 'list_groups', {})
  expect(fromOther.split('\n')[0]).toMatch(/No groups/)
  expect(jsonOf(fromOther)).toEqual([])
})

test('a group file recording another project key is skipped even in the same folder', async ($, on) => {
  const w = groupsWorld(on)
  const { id } = await create($, [{ target: PAGE }])
  const dir = dirOf('/repo/.git')
  const other = JSON.parse(w.files[`${dir}/${id}.json`] ?? '{}')
  w.files[`${dir}/zzzzzzzz.json`] = JSON.stringify({ ...other, id: 'zzzzzzzz', title: 'Elsewhere', projectKey: '/elsewhere/.git' })
  w.files[`${dir}/${id}.json.staged`] = '{}'
  const listed = jsonOf(await call($, 'list_groups', {})) as unknown as { id: string }[]
  expect(listed.map(one => one.id)).toEqual([id])
  expect(await call($, 'read_group', { id: 'zzzzzzzz' })).toMatch(/^No group zzzzzzzz/)
})

test('outside git the project key is the session root', async ($, on) => {
  const w = groupsWorld(on, { '/plain/a.md': 'a\n' })
  w.root = '/plain'
  const { id } = await create($, [{ target: 'a.md' }])
  expect(savedGroup(w, id, '/plain')?.items.map(one => one.ref)).toEqual(['file:///plain/a.md'])
})

test('delete_group on a starred group without force is refused; with force the file is gone', async ($, on) => {
  const w = groupsWorld(on)
  const { id } = await create($, [{ target: PAGE }])
  const file = `${dirOf('/repo/.git')}/${id}.json`
  w.files[file] = JSON.stringify({ ...JSON.parse(w.files[file] ?? '{}'), starred: true })
  const refused = await call($, 'delete_group', { id })
  expect(refused).toMatch(/^Not deleted: the person starred it/)
  expect(w.files[file]).toBeDefined()
  const forced = await call($, 'delete_group', { id, force: true })
  expect(forced).toMatch(/^Deleted group "Launch"/)
  expect(w.files[file]).toBeUndefined()
})

test('read_group marks a local file that vanished as missing; a repo-relative ref removes it', async ($, on) => {
  const w = groupsWorld(on)
  const { id } = await create($, [{ target: 'docs/plan.md' }, { target: PAGE }])
  delete w.files['/repo/docs/plan.md']
  const read = jsonOf(await call($, 'read_group', { id })) as { items: { ref: string; state: string }[] }
  expect(read.items.map(one => `${one.ref}:${one.state}`)).toEqual(['docs/plan.md:missing', `${PAGE}:ok`])
  await call($, 'save_group', { id, remove: [{ target: 'docs/plan.md' }] })
  expect(savedGroup(w, id)?.items.map(one => one.ref)).toEqual([PAGE])
})

test('an agent remove of a person-added item is refused without force', async ($, on) => {
  const w = groupsWorld(on)
  const { id } = await create($, [{ target: PAGE }])
  const file = `${dirOf('/repo/.git')}/${id}.json`
  const group = JSON.parse(w.files[file] ?? '{}')
  group.items.push({ ref: 'notes/todo.md', addedBy: 'person', addedAt: w.now })
  w.files[file] = JSON.stringify(group)
  const text = await call($, 'save_group', { id, remove: [{ target: 'notes/todo.md' }] })
  const outcome = (jsonOf(text).outcomes as { status: string; needsForce?: boolean }[])[0]
  expect(outcome).toMatchObject({ status: 'refused', needsForce: true })
  expect(savedGroup(w, id)?.items.map(one => one.ref)).toEqual([PAGE, 'notes/todo.md'])
})

test('an id that is not a group id is refused before any file is touched', async ($, on) => {
  const w = groupsWorld(on)
  w.log = []
  expect(await call($, 'read_group', { id: '../../etc' })).toMatch(/not a group id/)
  expect(await call($, 'save_group', { id: '../x', title: 'y' })).toMatch(/not a group id/)
  expect(w.log.some(one => one[0] === 'write' || one.includes('mkdir'))).toBe(false)
})

test('a tool write in this session redraws the pane', async ($, on) => {
  const w = groupsWorld(on)
  const before = w.invalidated
  await create($, [{ target: PAGE }])
  expect(w.invalidated).toBeGreaterThan(before)
})

async function recentText($: Parameters<typeof call>[0] & { ui: { mount: (input: never) => Promise<{ press: (q: { key: string }) => Promise<unknown>; drawn: () => Promise<unknown>; unmount: () => Promise<void> }> } }) {
  const props = { title: 'Peek', isFocused: true, bodyColumns: 100, placement: 'dock', scroll: { offset: 0, bodyRows: 40 }, view: {} }
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' } as never)
  await ui.press({ key: 'mode-recent' })
  const text = JSON.stringify(await ui.drawn())
  await ui.unmount()
  return text
}

test('a peek group tool call is not recorded by the capture hook, while a GitHub read is', async ($, on) => {
  groupsWorld(on)
  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc
  on('tool.call', async () => ({ result: [{ type: 'text', text: `see ${PR}` }] }) as never)
  const { id } = await create($, [{ target: PR }])
  await call($, 'read_group', { id })
  await call($, 'list_groups', {})
  expect(await recentText($)).not.toContain('widgets')
  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc
  await $.tool.call({ tool: 'mcp__github__get_pull_request', tool_use_id: 'c1', number: 42 } as never)
  expect(await recentText($)).toContain('widgets')
})

const paneProps = {
  title: 'Peek',
  isFocused: true,
  bodyColumns: 100,
  placement: 'dock' as const,
  scroll: { offset: 0, bodyRows: 40 },
  view: {},
}

type Found = { props: Record<string, unknown>; text: string } | undefined

async function cardTitles(ui: { find: (q: { key: string }) => Promise<Found> }) {
  const titles: string[] = []
  for (let i = 0; i < 10; i++) {
    const one = await ui.find({ key: `group-name-${i}` })
    if (one) titles.push(one.text.trim())
  }
  return titles
}

function editGroup(w: World, id: string, change: (group: Record<string, unknown>) => void) {
  const file = `${dirOf('/repo/.git')}/${id}.json`
  const group = JSON.parse(w.files[file] ?? '{}') as Record<string, unknown>
  change(group)
  w.files[file] = JSON.stringify(group)
}

test('after the agent creates two groups, the Groups tab lists both as cards, starred first, then most recently updated', async ($, on) => {
  const w = groupsWorld(on)
  const alpha = await create($, [{ target: PAGE }, { target: 'docs/plan.md' }], 'Alpha')
  w.now += 60_000
  await call($, 'save_group', { title: 'Beta', description: 'Ship notes\nsecond line', add: [{ target: PR }] })
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: paneProps, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  expect(await cardTitles(ui)).toEqual(['Beta', 'Alpha'])
  expect(await ui.find({ text: /^2 groups · 0 starred$/ })).toBeDefined()
  expect(await ui.find({ text: /Ship notes/ })).toBeDefined()
  expect(await ui.find({ text: /second line/ })).toBeUndefined()
  expect(await ui.find({ text: /^2 items/ })).toBeDefined()
  editGroup(w, alpha.id, group => (group.starred = true))
  await ui.redraw()
  expect(await cardTitles(ui)).toEqual(['Alpha', 'Beta'])
  expect(await ui.find({ text: /^2 groups · 1 starred$/ })).toBeDefined()
  expect((await ui.find({ key: 'item-0' }))?.props.label).toBe('\u{f51a}')
  await ui.unmount()
})

test('the Groups tab re-reads group files on every render: another session\'s change shows on the next draw', async ($, on) => {
  const w = groupsWorld(on)
  const { id } = await create($, [{ target: PAGE }], 'Alpha')
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: paneProps, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  expect(await cardTitles(ui)).toEqual(['Alpha'])
  editGroup(w, id, group => (group.title = 'Renamed elsewhere'))
  await ui.redraw()
  expect(await cardTitles(ui)).toEqual(['Renamed elsewhere'])
  await ui.unmount()
})

test('clicking a group card opens its group page; e returns to the list; the hover star stars the group, not a file', async ($, on) => {
  const w = groupsWorld(on)
  const storeKeys: string[] = []
  on('store.set', (_$, e, next) => {
    storeKeys.push(e.key)
    return next(e)
  })
  const { id } = await create($, [{ target: PAGE }], 'Alpha')
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: paneProps, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  const layer = 'hover-groups-0'
  await ui.resize({ columns: 60, rows: 5, in: layer })
  await ui.pointer({ type: 'move', x: 10, y: 3, in: layer })
  expect(JSON.stringify(await ui.drawn({ in: layer }))).toContain('\u{f41e}')
  await ui.pointer({ type: 'down', button: 'left', x: 10, y: 3, in: layer })
  expect((await ui.find({ key: 'group-page-title' }))?.text).toMatch(/Alpha/)
  await ui.press({ key: 'mode-groups' })
  expect(await ui.find({ key: 'group-page-title' })).toBeUndefined()
  expect(await cardTitles(ui)).toEqual(['Alpha'])
  await ui.resize({ columns: 60, rows: 5, in: layer })
  const before = w.invalidated
  await ui.pointer({ type: 'down', button: 'left', x: 2, y: 1, in: layer })
  expect(savedGroup(w, id)?.starred).toBe(true)
  expect(w.invalidated).toBeGreaterThan(before)
  await ui.redraw()
  expect(await ui.find({ text: /^1 group · 1 starred$/ })).toBeDefined()
  expect(storeKeys).not.toContain('stars')
  await ui.press({ key: 'item-0' })
  expect((await ui.find({ key: 'group-page-title' }))?.text).toMatch(/Alpha/)
  await ui.unmount()
})

test('f on a selected group card toggles its star; o opens it; a deleted group is reported, never starred', async ($, on) => {
  const w = groupsWorld(on)
  await create($, [{ target: PAGE }], 'Alpha')
  w.now += 60_000
  const beta = await create($, [{ target: PR }], 'Beta')
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: paneProps, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  expect((await ui.find({ key: 'star-selected' }))?.props.hotkey).toBe('f')
  await ui.press({ key: 'star-selected' })
  expect(savedGroup(w, beta.id)?.starred).toBe(true)
  await ui.press({ key: 'star-selected' })
  expect(savedGroup(w, beta.id)?.starred).toBe(false)
  await ui.press({ key: 'right' })
  await ui.press({ key: 'open-selected' })
  expect((await ui.find({ key: 'group-page-title' }))?.text).toMatch(/Alpha/)
  await ui.press({ key: 'mode-groups' })
  await ui.press({ key: 'left' })
  delete w.files[`${dirOf('/repo/.git')}/${beta.id}.json`]
  await ui.press({ key: 'star-selected' })
  expect(w.toasts).toContain('That group was deleted.')
  expect(savedGroup(w, beta.id)).toBeUndefined()
  await ui.unmount()
})

test('with no groups the tab says the agent makes them', async ($, on) => {
  groupsWorld(on)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: paneProps, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  expect(await ui.find({ text: /^No groups yet\. The agent makes groups: ask it to group related files and links\.$/ })).toBeDefined()
  expect(await ui.find({ text: /^0 groups · 0 starred$/ })).toBeDefined()
  await ui.unmount()
})

test('the Groups tab is reachable from the header tab, the e key and the ctrl+k menu', async ($, on) => {
  groupsWorld(on)
  await create($, [{ target: PAGE }], 'Alpha')
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: paneProps, requestId: 'peek' })
  expect((await ui.find({ key: 'mode-groups' }))?.props.hotkey).toBe('e')
  const right = await ui.find({ key: 'tabs-right' })
  const tabs = (right?.props.props as { tabs: { id: string; label: string }[] }).tabs
  expect(tabs.map(one => one.id)).toEqual(['recent', 'gallery', 'groups'])
  const before = tabs.slice(0, 2).reduce((sum, one) => sum + one.label.length, 0)
  await ui.resize({ columns: Number(right?.props.width), rows: 1, in: 'tabs-right' })
  await ui.pointer({ type: 'down', button: 'left', x: before + 2, y: 0, in: 'tabs-right' })
  expect(await cardTitles(ui)).toEqual(['Alpha'])
  await ui.press({ key: 'mode-recent' })
  expect(await cardTitles(ui)).toEqual([])
  await ui.press({ key: 'mode-groups' })
  expect(await cardTitles(ui)).toEqual(['Alpha'])
  await ui.press({ key: 'mode-recent' })
  await $.command.run({ command: 'peek-menu' } as never)
  await ui.redraw()
  expect((await ui.find({ key: 'menu-row-groups' }))?.text).toMatch(/e$/)
  await ui.press({ key: 'menu-groups' })
  expect(await cardTitles(ui)).toEqual(['Alpha'])
  await $.command.run({ command: 'peek-menu' } as never)
  await ui.redraw()
  expect((await ui.find({ key: 'menu-row-key-star-selected' }))?.text).toMatch(/group ?f$/)
  expect((await ui.find({ key: 'menu-row-key-open-selected' }))?.text).toMatch(/group ?o$/)
  await ui.unmount()
})

type Node = { type?: string; props?: Record<string, unknown>; children?: unknown[] }

function textOfNode(node: unknown): string {
  if (typeof node === 'string') return node
  return ((node as Node)?.children ?? []).map(textOfNode).join('')
}

async function headerFit(ui: { drawn: () => Promise<unknown> }, bodyColumns: number) {
  const tree = (await ui.drawn()) as Node
  const pinned = (tree.children ?? []) as Node[]
  const header = (pinned.find(one => one.props?.position === 'absolute' && one.props?.top === 0)?.children?.[0] ?? {}) as Node
  const parts = (header.children ?? []) as Node[]
  const tabs = parts.filter(one => String(one.props?.key ?? '').startsWith('tabs-'))
  const tabIds = tabs.flatMap(one => ((one.props?.props as { tabs?: { id: string }[] })?.tabs ?? []).map(tab => tab.id))
  const used = parts.reduce((sum, one) => sum + (tabs.includes(one) ? Number(one.props?.width) : [...textOfNode(one)].length), 0)
  return { tabIds, used, bodyColumns }
}

test('at 60, 70 and 100 columns the header draws all four tabs and the crumb shortens so nothing overflows', async ($, on) => {
  const deep = '/repo/a-rather-long-folder-name/another-deeply-nested-folder/a-file-with-quite-a-long-name.md'
  groupsWorld(on, { [deep]: '# Deep\n' })
  await $.command.run({ command: 'peek', args: deep } as never)
  for (const bodyColumns of [60, 70, 100]) {
    const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: { ...paneProps, bodyColumns }, requestId: 'peek' })
    for (const key of ['mode-view', 'mode-groups', 'mode-recent']) {
      await ui.press({ key })
      const fit = await headerFit(ui, bodyColumns)
      expect(fit.tabIds).toEqual(['view', 'recent', 'gallery', 'groups'])
      expect(fit.used).toBeLessThanOrEqual(bodyColumns - 5)
    }
    await ui.unmount()
  }
  const narrow = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: { ...paneProps, bodyColumns: 59 }, requestId: 'peek' })
  expect((await headerFit(narrow, 59)).tabIds).toEqual([])
  expect((await narrow.find({ key: 'mode-groups' }))?.props.hotkey).toBe('e')
  await narrow.unmount()
})

type PageUi = Awaited<ReturnType<typeof openFirstGroup>>

async function openFirstGroup($: { ui: { mount: (input: never) => Promise<MountedUi> } }) {
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: paneProps, requestId: 'peek' } as never)
  await ui.press({ key: 'mode-groups' })
  await ui.press({ key: 'item-0' })
  return ui
}

type MountedUi = {
  press: (q: { key: string }) => Promise<unknown>
  find: (q: { key?: string; text?: RegExp | string }) => Promise<Found>
  drawn: () => Promise<unknown>
  redraw: () => Promise<unknown>
  unmount: () => Promise<void>
}

async function rowTexts(ui: PageUi) {
  const texts: string[] = []
  for (let i = 0; i < 20; i++) {
    const one = await ui.find({ key: `group-item-${i}` })
    if (one) texts.push(one.text.trim())
  }
  return texts
}

const selectedRow = async (ui: PageUi) => {
  for (let i = 0; i < 20; i++) if ((await ui.find({ key: `item-${i}` }))?.props.autoFocus === true) return i
  return -1
}

// Remote loads run in the background of a render, so a test redraws until they land.
async function settle(ui: PageUi, isDone: () => Promise<boolean>) {
  for (let i = 0; i < 20 && !(await isDone()); i++) await ui.redraw()
}

const statusShown = (ui: PageUi, status: string) => async () => (await ui.find({ text: status })) !== undefined

function ghWorld(w: World, answer: (line: string) => Promise<RunAnswer | undefined> | RunAnswer | undefined) {
  w.onRun = argv => {
    const line = argv.join(' ')
    if (argv[0] === 'sh') return { exitCode: 0, stdout: 'gh\n' }
    if (line === 'gh auth status') return { exitCode: 0 }
    return argv[0] === 'gh' ? answer(line) : undefined
  }
}

const pull = (n: number) => `https://github.com/acme/widgets/pull/${n}`

test('a group page shows the description, the top block first, then each section header over its items; an empty section says so', async ($, on) => {
  groupsWorld(on)
  await call($, 'save_group', {
    title: 'Launch',
    description: 'Everything for the launch',
    sections: [{ action: 'add', title: 'Docs' }, { action: 'add', title: 'Links' }, { action: 'add', title: 'Later' }],
    add: [
      { target: 'docs/plan.md', section: 'Docs' },
      { target: 'https://example.test/launch', section: 'Links', label: 'The launch page' },
      { target: '/home/notes.md' },
      { target: 'notes/todo.md', section: 'Docs' },
    ],
  })
  const ui = await openFirstGroup($)
  expect((await ui.find({ key: 'group-page-title' }))?.text).toMatch(/Launch/)
  expect(await ui.find({ text: /^Everything for the launch$/ })).toBeDefined()
  expect(await rowTexts(ui)).toEqual(['notes.md', 'plan.md', 'todo.md', 'The launch page'])
  expect((await ui.find({ key: 'group-section-0' }))?.text).toMatch(/DOCS/)
  expect((await ui.find({ key: 'group-section-1' }))?.text).toMatch(/LINKS/)
  expect((await ui.find({ key: 'group-section-2' }))?.text).toMatch(/LATER/)
  expect((await ui.find({ key: 'group-empty-2' }))?.text).toMatch(/empty/)
  const tree = JSON.stringify(await ui.drawn())
  const order = ['group-item-0', 'group-section-0', 'group-item-1', 'group-item-2', 'group-section-1', 'group-item-3', 'group-section-2'].map(key => tree.indexOf(`"${key}"`))
  expect(order.every(at => at >= 0)).toBe(true)
  expect([...order].sort((a, b) => a - b)).toEqual(order)
  await settle(ui, statusShown(ui, 'Launch · 4 items · 1 missing'))
  expect(await ui.find({ text: 'Launch · 4 items · 1 missing' })).toBeDefined()
  await ui.unmount()
})

test('an empty group says No items', async ($, on) => {
  groupsWorld(on)
  await call($, 'save_group', { title: 'Nothing yet' })
  const ui = await openFirstGroup($)
  expect(await ui.find({ text: /^No items$/ })).toBeDefined()
  expect(await ui.find({ text: 'Nothing yet · 0 items · 0 missing' })).toBeDefined()
  await ui.unmount()
})

test('an item whose file was deleted shows as missing, stays selectable, says the file is gone when opened, and can be removed', async ($, on) => {
  const w = groupsWorld(on)
  const { id } = await create($, [{ target: 'docs/plan.md' }, { target: 'notes/todo.md' }])
  delete w.files['/repo/docs/plan.md']
  const ui = await openFirstGroup($)
  expect(await ui.find({ text: 'Launch · 2 items · 1 missing' })).toBeDefined()
  expect((await ui.find({ key: 'group-meta-0' }))?.text).toMatch(/missing/)
  expect((await ui.find({ key: 'group-meta-1' }))?.text ?? '').not.toMatch(/missing/)
  expect(await selectedRow(ui)).toBe(0)
  await ui.press({ key: 'next' })
  expect(await selectedRow(ui)).toBe(1)
  await ui.press({ key: 'prev' })
  expect(await selectedRow(ui)).toBe(0)
  await ui.press({ key: 'open-selected' })
  expect(w.toasts.some(one => /gone/.test(one) && one.includes('plan.md'))).toBe(true)
  expect(await ui.find({ key: 'group-page-title' })).toBeDefined()
  const read = jsonOf(await call($, 'read_group', { id })) as { items: { ref: string; state: string }[] }
  expect(read.items.map(one => `${one.ref}:${one.state}`)).toEqual(['docs/plan.md:missing', 'notes/todo.md:ok'])
  await call($, 'save_group', { id, remove: [{ target: 'docs/plan.md' }] })
  await ui.redraw()
  expect(await rowTexts(ui)).toEqual(['todo.md'])
  expect(await ui.find({ text: 'Launch · 1 item · 0 missing' })).toBeDefined()
  await ui.unmount()
})

test('a remote item whose refresh says not found is missing; one that times out is unavailable and not counted as missing', async ($, on) => {
  const w = groupsWorld(on)
  ghWorld(w, line => {
    if (/\b142\b/.test(line)) return { exitCode: 1, stderr: 'GraphQL: Could not resolve to a PullRequest with the number of 142.' }
    if (/\b143\b/.test(line)) return { exitCode: 1, stderr: 'Post "https://api.github.com/graphql": dial tcp 140.82.112.6:443: i/o timeout' }
    return undefined
  })
  const { id } = await create($, [{ target: pull(142) }, { target: pull(143) }])
  const ui = await openFirstGroup($)
  await settle(ui, async () => /unavailable/.test((await ui.find({ key: 'group-meta-1' }))?.text ?? ''))
  expect((await ui.find({ key: 'group-meta-0' }))?.text).toMatch(/missing/)
  expect((await ui.find({ key: 'group-meta-1' }))?.text).toMatch(/unavailable/)
  expect(await ui.find({ text: 'Launch · 2 items · 1 missing' })).toBeDefined()
  const read = jsonOf(await call($, 'read_group', { id })) as { items: { ref: string; state: string }[] }
  expect(read.items.map(one => one.state)).toEqual(['missing', 'unavailable'])
  await ui.unmount()
})

test('a repo-relative item added in worktree A opens worktree B\'s copy when the session runs in B', async ($, on) => {
  const w = groupsWorld(on, { '/repo/docs/plan.md': '# Plan from A\n', '/wt/feature/docs/plan.md': '# Plan from B\n' })
  await create($, [{ target: 'docs/plan.md' }])
  w.root = '/wt/feature'
  const ui = await openFirstGroup($)
  expect(await rowTexts(ui)).toEqual(['plan.md'])
  await ui.press({ key: 'open-selected' })
  expect(await ui.find({ text: /Plan from B/ })).toBeDefined()
  expect(await ui.find({ text: /Plan from A/ })).toBeUndefined()
  await ui.unmount()
})

test('back from an opened item returns to the page with that item selected; if it was removed meanwhile, the nearest row', async ($, on) => {
  const w = groupsWorld(on)
  const stored: unknown[] = []
  on('store.set', (_$, e, next) => {
    if (e.key === 'stars') stored.push(e.value)
    return next(e)
  })
  const { id } = await create($, [{ target: 'docs/plan.md' }, { target: 'notes/todo.md' }, { target: '/home/notes.md' }])
  const ui = await openFirstGroup($)
  await ui.press({ key: 'next' })
  await ui.press({ key: 'open-selected' })
  expect(await ui.find({ key: 'group-page-title' })).toBeUndefined()
  expect(await ui.find({ text: /todo\.md/ })).toBeDefined()
  await $.command.run({ command: 'peek-menu' } as never)
  await ui.redraw()
  expect((await ui.find({ key: 'menu-row-key-back' }))?.text).toMatch(/Back to Launch ?b$/)
  await $.command.run({ command: 'peek-menu' } as never)
  await ui.press({ key: 'back' })
  expect(await ui.find({ key: 'group-page-title' })).toBeDefined()
  expect(await selectedRow(ui)).toBe(1)
  await ui.press({ key: 'open-selected' })
  await call($, 'save_group', { id, remove: [{ target: 'notes/todo.md' }] })
  await ui.press({ key: 'back' })
  expect(await rowTexts(ui)).toEqual(['plan.md', 'notes.md'])
  expect(await selectedRow(ui)).toBe(1)
  await ui.press({ key: 'star-selected' })
  expect(stored.at(-1)).toEqual(['file:///home/notes.md'])
  expect(w.toasts).toEqual([])
  await ui.unmount()
})

test('a remote item with no cached title shows the agent\'s label, then its title after the refresh', async ($, on) => {
  const w = groupsWorld(on)
  let release = () => {}
  const held = new Promise<void>(resolve => (release = resolve))
  ghWorld(w, async line => {
    if (line.startsWith('gh pr view 144')) {
      await held
      return { exitCode: 0, stdout: JSON.stringify(pullView({ number: 144, title: 'Teach the parser trailing commas' })) }
    }
    if (line.startsWith('gh api repos/acme/widgets/pulls/144')) return { exitCode: 0, stdout: '0' }
    return undefined
  })
  const { id } = await create($, [{ target: pull(144), label: 'Review this first' }])
  const ui = await openFirstGroup($)
  expect(await rowTexts(ui)).toEqual(['Review this first'])
  expect((jsonOf(await call($, 'read_group', { id })).items as { title: unknown }[])[0]?.title).toBeNull()
  release()
  await settle(ui, async () => (await rowTexts(ui))[0] !== 'Review this first')
  expect(await rowTexts(ui)).toEqual(['#144 Teach the parser trailing commas'])
  expect((jsonOf(await call($, 'read_group', { id })).items as { title: unknown }[])[0]?.title).toBe('#144 Teach the parser trailing commas')
  await ui.unmount()
})

test('when the open group\'s file is gone at the next render, the pane returns to the Groups tab with a toast', async ($, on) => {
  const w = groupsWorld(on)
  const { id } = await create($, [{ target: 'docs/plan.md' }])
  const ui = await openFirstGroup($)
  expect(await ui.find({ key: 'group-page-title' })).toBeDefined()
  delete w.files[`${dirOf('/repo/.git')}/${id}.json`]
  await ui.redraw()
  await ui.redraw()
  expect(await ui.find({ key: 'group-page-title' })).toBeUndefined()
  expect(await ui.find({ text: /^No groups yet/ })).toBeDefined()
  expect(w.toasts.filter(one => one === 'That group was deleted.')).toHaveLength(1)
  await ui.unmount()
})

test('the open group\'s remote items join the background refresh', async ($, on) => {
  const clock = mock.clock(on, { now: 10 * 3600_000 })
  const w = groupsWorld(on, {}, { isClockMocked: true })
  let views = 0
  ghWorld(w, line => {
    if (line.startsWith('gh pr view 145')) {
      views++
      return { exitCode: 0, stdout: JSON.stringify(pullView({ number: 145 })) }
    }
    if (line.startsWith('gh api repos/acme/widgets/pulls/145')) return { exitCode: 0, stdout: '0' }
    return undefined
  })
  await create($, [{ target: pull(145) }])
  const ui = await openFirstGroup($)
  await settle(ui, async () => views > 0 && /Teach/.test((await rowTexts(ui))[0] ?? ''))
  expect(views).toBe(1)
  await $.session.append({ message: { type: 'user', content: [{ type: 'text', text: 'still here' }] } } as never).catch(() => undefined)
  await clock.advance(5 * 60_000 + 15_000)
  expect(views).toBe(2)
  await ui.unmount()
})
