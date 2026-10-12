import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'
import { groupsDir } from '../hooks/groups'
import { itemKey } from '../hooks/refs'
import { resetRefresh } from '../hooks/refresh'
import { pullView } from './fixtures/github/items'

const HOME = '/home'
const PR = 'https://github.com/acme/widgets/pull/42'
const LINEAR = 'https://linear.app/acme/issue/WEB-12'
const PAGE = 'https://example.test/page'

type World = {
  files: Record<string, string>
  dirs: Map<string, number>
  mtimes: Map<string, number>
  reads: string[]
  dirStats: string[]
  touch: (path: string) => void
  isHomeBroken: boolean
  log: string[][]
  now: number
  root: string
  commonDirs: Record<string, string>
  invalidated: number
  toasts: string[]
  isMvBroken: boolean
  onLockBusy?: (lock: string) => void
  onWrite?: (path: string) => void
  onRun?: (argv: string[]) => Promise<RunAnswer | undefined> | RunAnswer | undefined
  onFetch?: (url: string) => { status: number; text?: string } | Error | undefined
}

type RunAnswer = { exitCode: number; stdout?: string; stderr?: string }

// Shared by every world, so an mtime never repeats across tests while the plugin's module state lives on.
let lastMtime = 9 * 3600_000

function groupsWorld(on: On, files: Record<string, string> = {}, options: { isClockMocked?: boolean } = {}): World {
  resetRefresh()
  const w: World = {
    files: { '/repo/docs/plan.md': '# Plan\n', '/repo/notes/todo.md': 'todo\n', '/home/notes.md': 'mine\n', ...files },
    dirs: new Map(),
    mtimes: new Map(),
    reads: [],
    dirStats: [],
    touch: path => {
      lastMtime++
      w.mtimes.set(path, lastMtime)
      w.dirs.set(path.slice(0, path.lastIndexOf('/')), lastMtime)
    },
    isHomeBroken: false,
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
  on('env.get', (_$, e) => {
    if (e.name === 'HOME' && w.isHomeBroken) {
      w.isHomeBroken = false
      throw new Error('env unavailable')
    }
    return { value: e.name === 'HOME' ? HOME : undefined }
  })
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
      if (!w.dirs.has(rest[1] ?? '')) w.dirs.set(rest[1] ?? '', w.now)
      return done(0)
    }
    if (bin === 'mkdir') {
      const lock = rest[0] ?? ''
      if (isDir(lock)) {
        w.onLockBusy?.(lock)
        return done(1)
      }
      w.dirs.set(lock, w.now)
      return done(0)
    }
    if (bin === 'rmdir') {
      const dir = rest[0] ?? ''
      if (Object.keys(w.files).some(one => one.startsWith(`${dir}/`))) return done(1)
      w.dirs.delete(dir)
      return done(0)
    }
    if (bin === 'mv' && rest[0] === '-f') {
      const [, from = '', to = ''] = rest
      if (w.isMvBroken || w.files[from] === undefined) return done(1)
      w.files[to] = w.files[from]
      delete w.files[from]
      w.touch(to)
      return done(0)
    }
    if (bin === 'rm' && rest[0] === '-f') {
      delete w.files[rest[1] ?? '']
      w.touch(rest[1] ?? '')
      return done(0)
    }
    return done(1)
  })
  on('fs.read', (_$, e) => {
    const text = w.files[e.path]
    w.reads.push(e.path)
    if (text === undefined) throw new Error(`ENOENT ${e.path}`)
    return { value: text }
  })
  on('fs.write', (_$, e) => {
    w.log.push(['write', e.path])
    w.files[e.path] = e.text
    w.touch(e.path)
    w.onWrite?.(e.path)
    return { value: undefined }
  })
  on('fs.exists', (_$, e) => ({ value: w.files[e.path] !== undefined || isDir(e.path) }))
  on('fs.stat', (_$, e) => {
    if (w.files[e.path] !== undefined) return { value: { kind: 'file' as const, size: w.files[e.path]?.length ?? 0, mtimeMs: w.mtimes.get(e.path) ?? 8 * 3600_000, isLink: false } }
    if (isDir(e.path)) {
      w.dirStats.push(e.path)
      return { value: { kind: 'dir' as const, size: 0, mtimeMs: w.dirs.get(e.path) ?? 8 * 3600_000, isLink: false } }
    }
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
  const staged = /^write (.*\.staged)$/.exec(steps[2] ?? '')?.[1] ?? ''
  expect(staged).toMatch(new RegExp(`^${file}\\.[0-9a-z]+\\.staged$`))
  expect(steps).toEqual([
    `run mkdir ${file}.lock`,
    `write ${file}.lock/owner`,
    `write ${staged}`,
    `run mv -f ${staged} ${file}`,
    `run rm -f ${file}.lock/owner`,
    `run rmdir ${file}.lock`,
  ])
  expect(Object.keys(w.files).some(one => one.startsWith(`${file}.`))).toBe(false)
})

test('two writers never share a staged path', async ($, on) => {
  const w = groupsWorld(on)
  const { id } = await create($, [{ target: PAGE }])
  w.log = []
  await call($, 'save_group', { id, add: [{ target: 'docs/plan.md' }] })
  await call($, 'save_group', { id, add: [{ target: 'notes/todo.md' }] })
  const staged = w.log.filter(one => one[0] === 'write' && one[1]?.endsWith('.staged')).map(one => one[1])
  expect(staged.length).toBe(2)
  expect(new Set(staged).size).toBe(2)
})

test('a holder whose lock is broken and retaken mid-write commits nothing, the newer edit survives, and the new holder keeps its lock', async ($, on) => {
  const w = groupsWorld(on)
  const { id } = await create($, [{ target: PAGE }])
  const file = `${dirOf('/repo/.git')}/${id}.json`
  const lock = `${file}.lock`
  w.onWrite = path => {
    if (!path.endsWith('.staged')) return
    w.onWrite = undefined
    delete w.files[`${lock}/owner`]
    w.dirs.delete(lock)
    w.dirs.set(lock, w.now)
    w.files[`${lock}/owner`] = 'the-other-session'
    const group = JSON.parse(w.files[file] ?? '{}')
    group.items.push({ ref: 'notes/todo.md', addedBy: 'person', addedAt: w.now })
    w.files[file] = JSON.stringify(group)
  }
  w.log = []
  const text = await call($, 'save_group', { id, add: [{ target: 'docs/plan.md' }] })
  expect(text).toMatch(/busy, try again/)
  expect(text).not.toMatch(/added|applied/i)
  expect(w.log.some(one => one[0] === 'run' && one[1] === 'mv')).toBe(false)
  expect(savedGroup(w, id)?.items.map(one => `${one.ref}:${one.addedBy}`)).toEqual([`${PAGE}:agent`, 'notes/todo.md:person'])
  expect(w.files[`${lock}/owner`]).toBe('the-other-session')
  expect(w.dirs.has(lock)).toBe(true)
  expect(Object.keys(w.files).some(one => one.endsWith('.staged'))).toBe(false)
})

test('a holder whose lock vanished before its mv commits nothing', async ($, on) => {
  const w = groupsWorld(on)
  const { id } = await create($, [{ target: PAGE }])
  const file = `${dirOf('/repo/.git')}/${id}.json`
  w.onWrite = path => {
    if (!path.endsWith('.staged')) return
    w.onWrite = undefined
    delete w.files[`${file}.lock/owner`]
    w.dirs.delete(`${file}.lock`)
  }
  const text = await call($, 'save_group', { id, add: [{ target: 'docs/plan.md' }] })
  expect(text).toMatch(/busy, try again/)
  expect(savedGroup(w, id)?.items.map(one => one.ref)).toEqual([PAGE])
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
  w.files[`${file}.lock/owner`] = 'a-stalled-session'
  w.mtimes.set(`${file}.lock/owner`, w.now - 11_000)
  const text = await call($, 'save_group', { id, add: [{ target: 'docs/plan.md' }] })
  expect(text).not.toMatch(/busy/)
  expect(savedGroup(w, id)?.items.map(one => one.ref)).toEqual([PAGE, 'docs/plan.md'])
  expect(w.dirs.has(`${file}.lock`)).toBe(false)
  expect(w.files[`${file}.lock/owner`]).toBeUndefined()
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
  expect(Object.keys(w.files).some(one => one.startsWith(`${file}.`))).toBe(false)
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

test('a damaged group file with a null item, a numeric ref, bad sections and non-text tombstones still reads, saves and draws', async ($, on) => {
  const w = groupsWorld(on)
  const { id } = await create($, [{ target: PAGE }])
  editGroup(w, id, group => {
    group.items = [null, { ref: 42, addedBy: 'agent', addedAt: 1 }, ...(group.items as unknown[]), 'docs/plan.md', { ref: 'notes/todo.md', section: 'abcdefgh', addedBy: 'agent', addedAt: 1 }]
    group.sections = [null, { id: 5, title: 'Numeric' }, { id: 'abcdefgh', title: 7 }, { id: 'keptsect', title: 'Kept' }]
    group.removed = [7, null, 'gone.md']
  })
  const read = jsonOf(await call($, 'read_group', { id })) as { items: { ref: string; section: string | null }[]; sections: { title: string }[]; removed: string[] }
  expect(read.items.map(one => `${one.ref}:${one.section}`)).toEqual([`${PAGE}:null`, 'notes/todo.md:null'])
  expect(read.sections.map(one => one.title)).toEqual(['Kept'])
  expect(read.removed).toEqual(['gone.md'])
  const saved = await call($, 'save_group', { id, add: [{ target: 'docs/plan.md', section: 'Kept' }] })
  expect(saved.split('\n')[0]).toMatch(/1 applied/)
  expect(savedGroup(w, id)?.items.map(one => one.ref)).toEqual([PAGE, 'notes/todo.md', 'docs/plan.md'])
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: paneProps, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  expect(await cardTitles(ui)).toEqual(['LAUNCH'])
  await ui.press({ key: 'item-0' })
  expect((await ui.find({ key: 'group-page-title' }))?.text).toMatch(/Launch/)
  await ui.unmount()
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

test('save_group refuses unreadable input with its exact message and writes no group file', async ($, on) => {
  const w = groupsWorld(on)
  const cases: [Record<string, unknown>, string][] = [
    [{ title: 5 }, 'title must be text.'],
    [{ title: 'Launch', description: 5 }, 'description must be text.'],
    [{}, 'Give a title to create a group, or an id to change one.'],
    [{ title: 'Launch', sections: [{ action: 'explode', section: 'a' }] }, 'Unreadable section change {"action":"explode","section":"a"}'],
    [{ title: 'Launch', sections: 'Design' }, 'sections must be a list of { action, section, title }'],
    [{ title: 'Launch', order: ['a', 3] }, 'order must be a list of section ids or titles.'],
    [{ title: 'Launch', add: [{}] }, 'add, move and remove are lists of objects, each with a target.'],
    [{ title: 'Launch', add: [null] }, 'add, move and remove are lists of objects, each with a target.'],
    [{ id: 'BAD', title: 'Launch' }, 'BAD is not a group id. Use an id from list_groups.'],
    [{ title: 'Launch', sections: [{ action: 'add', title: 'Links', layout: 'grid' }] }, 'A section layout is cards or list, not "grid"'],
    [{ title: 'Launch', sections: [{ action: 'layout', section: 'Links' }] }, 'A section layout is cards or list, not "undefined"'],
  ]
  for (const [input, message] of cases) {
    expect([input, await call($, 'save_group', input)]).toEqual([input, message])
  }
  expect(Object.keys(w.files).filter(one => one.startsWith(`${dirOf('/repo/.git')}/`))).toEqual([])
})

test('save_group sets a section layout on add and with a layout change; read_group reads a missing or unknown layout as cards', async ($, on) => {
  const w = groupsWorld(on)
  const text = await call($, 'save_group', {
    title: 'Launch',
    sections: [{ action: 'add', title: 'Links', layout: 'list' }, { action: 'add', title: 'Docs' }],
  })
  const id = String(jsonOf(text).id)
  const layouts = async () => ((jsonOf(await call($, 'read_group', { id })) as { sections: { layout: string }[] }).sections).map(one => one.layout)
  expect(await layouts()).toEqual(['list', 'cards'])
  const changed = await call($, 'save_group', { id, sections: [{ action: 'layout', section: 'Docs', layout: 'list' }] })
  expect(changed.split('\n')[0]).toMatch(/1 applied/)
  expect(await layouts()).toEqual(['list', 'list'])
  editGroup(w, id, group => {
    const sections = group.sections as Record<string, unknown>[]
    if (sections[0]) delete sections[0].layout
    if (sections[1]) sections[1].layout = 'mosaic'
  })
  expect(await layouts()).toEqual(['cards', 'cards'])
  await call($, 'save_group', { id, description: 'resaved' })
  const stored = JSON.parse(w.files[`${dirOf('/repo/.git')}/${id}.json`] ?? '{}') as { sections: { layout?: string }[] }
  expect(stored.sections.map(one => one.layout)).toEqual(['cards', 'cards'])
})

test('save_group moves items, reorders, renames and removes sections, and force overrides a person tombstone and a person add', async ($, on) => {
  const w = groupsWorld(on)
  const text = await call($, 'save_group', {
    title: 'Launch',
    sections: [
      { action: 'add', title: 'Design' },
      { action: 'add', title: 'Build' },
    ],
    add: [{ target: 'docs/plan.md', section: 'Design' }, { target: PAGE }],
  })
  const id = String(jsonOf(text).id)
  const file = `${dirOf('/repo/.git')}/${id}.json`
  const stored = () => JSON.parse(w.files[file] ?? '{}') as { sections: { id: string; title: string }[]; items: { ref: string; section?: string; addedBy: string }[]; removed: string[] }
  const sectionId = (title: string) => stored().sections.find(one => one.title === title)?.id
  const placeOf = (ref: string) => stored().items.find(one => one.ref === ref)?.section

  await call($, 'save_group', { id, move: [{ target: 'docs/plan.md', section: 'Build' }, { target: PAGE, section: 'Design' }] })
  expect([placeOf('docs/plan.md'), placeOf(PAGE)]).toEqual([sectionId('Build'), sectionId('Design')])

  await call($, 'save_group', { id, order: ['Build', 'Design'] })
  expect(stored().sections.map(one => one.title)).toEqual(['Build', 'Design'])

  await call($, 'save_group', { id, sections: [{ action: 'rename', section: 'Design', title: 'Specs' }, { action: 'remove', section: 'Build' }] })
  expect(stored().sections.map(one => one.title)).toEqual(['Specs'])
  expect([placeOf('docs/plan.md'), placeOf(PAGE)]).toEqual([undefined, sectionId('Specs')])

  editGroup(w, id, group => {
    group.removed = [itemKey('notes/todo.md')]
    ;(group.items as unknown[]).push({ ref: LINEAR, addedBy: 'person', addedAt: w.now })
  })
  const blocked = jsonOf(await call($, 'save_group', { id, add: [{ target: 'notes/todo.md' }], remove: [{ target: LINEAR }] }))
  expect((blocked.outcomes as { status: string; needsForce?: boolean }[]).map(one => `${one.status}:${one.needsForce}`)).toEqual(['refused:true', 'refused:true'])
  expect(stored().items.map(one => one.ref)).toEqual(['docs/plan.md', PAGE, LINEAR])

  const forced = jsonOf(await call($, 'save_group', { id, add: [{ target: 'notes/todo.md', force: true }], remove: [{ target: LINEAR, force: true }] }))
  expect((forced.outcomes as { status: string }[]).map(one => one.status)).toEqual(['applied', 'applied'])
  expect(stored().items.map(one => `${one.ref}:${one.addedBy}`)).toEqual(['docs/plan.md:agent', `${PAGE}:agent`, 'notes/todo.md:agent'])
  expect(stored().removed).toEqual([])
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
  w.touch(file)
}

test('after the agent creates two groups, the Groups tab lists both as cards, starred first, then most recently updated', async ($, on) => {
  const w = groupsWorld(on)
  const alpha = await create($, [{ target: PAGE }, { target: 'docs/plan.md' }], 'Alpha')
  w.now += 60_000
  await call($, 'save_group', { title: 'Beta', description: 'Ship notes\nsecond line', add: [{ target: PR }] })
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: paneProps, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  expect(await cardTitles(ui)).toEqual(['BETA', 'ALPHA'])
  expect(await ui.find({ text: /^2 groups · 0 starred$/ })).toBeDefined()
  expect(await ui.find({ text: /Ship notes/ })).toBeDefined()
  expect(await ui.find({ text: /second line/ })).toBeDefined()
  expect(await ui.find({ text: /^2 items/ })).toBeDefined()
  editGroup(w, alpha.id, group => (group.starred = true))
  await ui.redraw()
  expect(await cardTitles(ui)).toEqual(['ALPHA', 'BETA'])
  expect(await ui.find({ text: /^2 groups · 1 starred$/ })).toBeDefined()
  expect((await ui.find({ key: 'item-0' }))?.props.label).toBe('\u{f51a}')
  await ui.unmount()
})

test('the Groups tab checks the folder on every render: another session\'s change shows on the next draw', async ($, on) => {
  const w = groupsWorld(on)
  const { id } = await create($, [{ target: PAGE }], 'Alpha')
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: paneProps, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  expect(await cardTitles(ui)).toEqual(['ALPHA'])
  editGroup(w, id, group => (group.title = 'Renamed elsewhere'))
  await ui.redraw()
  expect(await cardTitles(ui)).toEqual(['RENAMED ELSEWHERE'])
  await ui.unmount()
})

test('a render over an unchanged groups folder stats it but reads no group file again', async ($, on) => {
  const w = groupsWorld(on)
  await create($, [{ target: PAGE }], 'Alpha')
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: paneProps, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  expect(await cardTitles(ui)).toEqual(['ALPHA'])
  const dir = dirOf('/repo/.git')
  const groupReads = () => w.reads.filter(one => one.startsWith(`${dir}/`)).length
  const dirStats = () => w.dirStats.filter(one => one === dir).length
  const [readsBefore, statsBefore] = [groupReads(), dirStats()]
  await ui.redraw()
  await ui.redraw()
  expect(await cardTitles(ui)).toEqual(['ALPHA'])
  expect(groupReads()).toBe(readsBefore)
  expect(dirStats()).toBeGreaterThan(statsBefore)
  await ui.unmount()
})

test('a group home that failed to resolve is tried again on the next call', async ($, on) => {
  const w = groupsWorld(on)
  w.root = '/solo'
  w.isHomeBroken = true
  const first = await call($, 'list_groups', {}).catch((error: unknown) => `threw: ${String(error)}`)
  expect(first).not.toMatch(/^No groups in this project yet\./)
  expect(await call($, 'list_groups', {})).toMatch(/^No groups in this project yet\./)
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
  await ui.resize({ columns: 60, rows: 1, in: layer })
  await ui.pointer({ type: 'move', x: 10, y: 0, in: layer })
  expect(JSON.stringify(await ui.drawn({ in: layer }))).toContain('\u{f41e}')
  await ui.pointer({ type: 'down', button: 'left', x: 10, y: 0, in: layer })
  expect((await ui.find({ key: 'group-page-title' }))?.text).toMatch(/Alpha/)
  await ui.press({ key: 'mode-groups' })
  expect(await ui.find({ key: 'group-page-title' })).toBeUndefined()
  expect(await cardTitles(ui)).toEqual(['ALPHA'])
  await ui.resize({ columns: 60, rows: 1, in: layer })
  const before = w.invalidated
  await ui.pointer({ type: 'down', button: 'left', x: 0, y: 0, in: layer })
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
  await ui.press({ key: 'next' })
  await ui.press({ key: 'open-selected' })
  expect((await ui.find({ key: 'group-page-title' }))?.text).toMatch(/Alpha/)
  await ui.press({ key: 'mode-groups' })
  await ui.press({ key: 'prev' })
  delete w.files[`${dirOf('/repo/.git')}/${beta.id}.json`]
  w.touch(`${dirOf('/repo/.git')}/${beta.id}.json`)
  await ui.press({ key: 'star-selected' })
  expect(w.toasts).toContain('That group was deleted.')
  expect(savedGroup(w, beta.id)).toBeUndefined()
  await ui.unmount()
})

test('starring a card in the Groups tab keeps that group selected as the list re-sorts, so f again unstars it', async ($, on) => {
  const w = groupsWorld(on)
  const alpha = await create($, [{ target: PAGE }], 'Alpha')
  w.now += 60_000
  const beta = await create($, [{ target: PR }], 'Beta')
  w.now += 60_000
  const gamma = await create($, [{ target: LINEAR }], 'Gamma')
  editGroup(w, alpha.id, group => (group.starred = true))
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: paneProps, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  expect(await cardTitles(ui)).toEqual(['ALPHA', 'GAMMA', 'BETA'])
  await ui.press({ key: 'next' })
  await ui.press({ key: 'star-selected' })
  expect(savedGroup(w, gamma.id)?.starred).toBe(true)
  await ui.redraw()
  expect(await cardTitles(ui)).toEqual(['GAMMA', 'ALPHA', 'BETA'])
  await ui.press({ key: 'star-selected' })
  expect(savedGroup(w, gamma.id)?.starred).toBe(false)
  expect(savedGroup(w, alpha.id)?.starred).toBe(true)
  expect(savedGroup(w, beta.id)?.starred).toBe(false)
  await ui.unmount()
})

test('a mouse star on another card in the Groups tab keeps the cursor on the group it was on', async ($, on) => {
  const w = groupsWorld(on)
  const alpha = await create($, [{ target: PAGE }], 'Alpha')
  w.now += 60_000
  const beta = await create($, [{ target: PR }], 'Beta')
  w.now += 60_000
  const gamma = await create($, [{ target: LINEAR }], 'Gamma')
  editGroup(w, alpha.id, group => (group.starred = true))
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: paneProps, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  await ui.press({ key: 'next' })
  const layer = 'hover-groups-0'
  await ui.resize({ columns: 60, rows: 1, in: layer })
  await ui.pointer({ type: 'down', button: 'left', x: 0, y: 0, in: layer })
  expect(savedGroup(w, alpha.id)?.starred).toBe(false)
  await ui.redraw()
  expect(await cardTitles(ui)).toEqual(['GAMMA', 'BETA', 'ALPHA'])
  await ui.press({ key: 'star-selected' })
  expect(savedGroup(w, gamma.id)?.starred).toBe(true)
  expect(savedGroup(w, beta.id)?.starred).toBe(false)
  await ui.unmount()
})

async function launchGroup($: Parameters<typeof call>[0]) {
  return call($, 'save_group', {
    title: 'Launch',
    description: 'Ship it this week\nwith the notes',
    sections: [{ action: 'add', title: 'Docs' }, { action: 'add', title: 'Links', layout: 'list' }],
    add: [
      { target: 'docs/plan.md', section: 'Docs' },
      { target: 'notes/todo.md', section: 'Docs' },
      { target: '/home/notes.md', section: 'Docs' },
      { target: PAGE, section: 'Links', label: 'The page' },
    ],
  })
}

async function itemNames(ui: { find: (q: { key: string }) => Promise<Found> }, prefix: string, card: number) {
  const names: string[] = []
  for (let n = 0; n < 12; n++) {
    const one = await ui.find({ key: `${prefix}-itname-${card}-${n}` })
    if (one) names.push(one.text.trim())
  }
  return names
}

test('a compact group card shows the title, the description, the first section header and only its first row of items, then MORE', async ($, on) => {
  groupsWorld(on)
  await launchGroup($)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: paneProps, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  expect((await ui.find({ key: 'group-name-0' }))?.text.trim()).toBe('LAUNCH')
  expect(await ui.find({ text: /Ship it this week/ })).toBeDefined()
  expect(await ui.find({ text: /with the notes/ })).toBeDefined()
  expect((await ui.find({ key: 'groups-sec-0-0' }))?.text).toMatch(/Docs/)
  expect(await itemNames(ui, 'groups', 0)).toEqual(['plan.md', 'todo.md'])
  expect(await ui.find({ key: 'groups-sec-0-1' })).toBeUndefined()
  expect((await ui.find({ key: 'groups-more-0' }))?.props.label).toMatch(/MORE ▼/)
  await ui.unmount()
})

test('MORE expands a card in place to every section, cards as item cards and list as lines; m and LESS collapse it', async ($, on) => {
  groupsWorld(on)
  await launchGroup($)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: paneProps, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  await ui.press({ key: 'groups-more-0' })
  await ui.redraw()
  expect(await itemNames(ui, 'groups', 0)).toEqual(['plan.md', 'todo.md', 'notes.md', 'The page'])
  expect((await ui.find({ key: 'groups-sec-0-1' }))?.text).toMatch(/Links/)
  expect((await ui.find({ key: 'groups-more-0' }))?.props.label).toMatch(/LESS ▲/)
  expect(await ui.find({ key: 'groups-card-0-2' })).toBeDefined()
  expect(await ui.find({ key: 'groups-line-0-2' })).toBeUndefined()
  expect(await ui.find({ key: 'groups-line-0-3' })).toBeDefined()
  expect(await ui.find({ key: 'groups-card-0-3' })).toBeUndefined()
  expect((await ui.find({ key: 'expand-selected' }))?.props.hotkey).toBe('m')
  await $.command.run({ command: 'peek-menu' } as never)
  await ui.redraw()
  expect((await ui.find({ key: 'menu-row-key-expand-selected' }))?.text).toMatch(/Expand\/Collapse group ?m$/)
  await $.command.run({ command: 'peek-menu' } as never)
  await ui.press({ key: 'expand-selected' })
  await ui.redraw()
  expect(await itemNames(ui, 'groups', 0)).toEqual(['plan.md', 'todo.md'])
  expect((await ui.find({ key: 'groups-more-0' }))?.props.label).toMatch(/MORE ▼/)
  await ui.press({ key: 'expand-selected' })
  await ui.redraw()
  await ui.press({ key: 'groups-more-0' })
  await ui.redraw()
  expect(await itemNames(ui, 'groups', 0)).toEqual(['plan.md', 'todo.md'])
  await ui.unmount()
})

test('a group card with nothing more to show draws no MORE bar', async ($, on) => {
  groupsWorld(on)
  await create($, [{ target: PAGE }], 'Alpha')
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: paneProps, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  expect(await itemNames(ui, 'groups', 0)).toEqual(['example.test/page'])
  expect(await ui.find({ key: 'groups-more-0' })).toBeUndefined()
  await ui.unmount()
})

test('clicking an item on a card opens it and Back returns to its group page with that item selected', async ($, on) => {
  groupsWorld(on)
  await launchGroup($)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: paneProps, requestId: 'peek' })
  await ui.press({ key: 'mode-groups' })
  await ui.press({ key: 'groups-it-0-1' })
  expect(await ui.find({ key: 'group-page-title' })).toBeUndefined()
  expect(await ui.find({ text: /todo\.md/ })).toBeDefined()
  await ui.press({ key: 'back' })
  expect((await ui.find({ key: 'group-page-title' }))?.text).toMatch(/Launch/)
  expect(await selectedRow(ui)).toBe(1)
  await ui.press({ key: 'mode-groups' })
  const layer = 'hover-groups-items-0-0'
  await ui.resize({ columns: paneProps.bodyColumns - 11, rows: 5, in: layer })
  await ui.pointer({ type: 'down', button: 'left', x: 2, y: 2, in: layer })
  expect(await ui.find({ text: /plan\.md/ })).toBeDefined()
  await ui.press({ key: 'back' })
  expect(await selectedRow(ui)).toBe(0)
  await ui.unmount()
})

test('a group card spans the full text width at 60 and 100 columns', async ($, on) => {
  groupsWorld(on)
  await launchGroup($)
  for (const bodyColumns of [60, 100]) {
    const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: { ...paneProps, bodyColumns }, requestId: 'peek' })
    await ui.press({ key: 'mode-groups' })
    expect((await ui.find({ key: 'groups-0' }))?.props.width).toBe(bodyColumns - 7)
    expect((await ui.find({ key: 'groups-morebar-0' }))?.props.width).toBe(bodyColumns - 11)
    await ui.unmount()
  }
})

test('a pinned card in Recent is compact and expands with MORE or m', async ($, on) => {
  const w = groupsWorld(on)
  const id = String(jsonOf(await launchGroup($)).id)
  editGroup(w, id, group => (group.starred = true))
  const ui = await mountPane($)
  await ui.press({ key: 'mode-recent' })
  expect((await ui.find({ key: 'starred-sec-0-0' }))?.text).toMatch(/Docs/)
  expect(await itemNames(ui, 'starred', 0)).toEqual(['plan.md', 'todo.md'])
  await ui.press({ key: 'starred-more-0' })
  await ui.redraw()
  expect(await itemNames(ui, 'starred', 0)).toEqual(['plan.md', 'todo.md', 'notes.md', 'The page'])
  expect((await ui.find({ key: 'starred-more-0' }))?.props.label).toMatch(/LESS ▲/)
  await ui.press({ key: 'expand-selected' })
  await ui.redraw()
  expect(await itemNames(ui, 'starred', 0)).toEqual(['plan.md', 'todo.md'])
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
  expect(await cardTitles(ui)).toEqual(['ALPHA'])
  await ui.press({ key: 'mode-recent' })
  expect(await cardTitles(ui)).toEqual([])
  await ui.press({ key: 'mode-groups' })
  expect(await cardTitles(ui)).toEqual(['ALPHA'])
  await ui.press({ key: 'mode-recent' })
  await $.command.run({ command: 'peek-menu' } as never)
  await ui.redraw()
  expect((await ui.find({ key: 'menu-row-groups' }))?.text).toMatch(/e$/)
  await ui.press({ key: 'menu-groups' })
  expect(await cardTitles(ui)).toEqual(['ALPHA'])
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
  w.touch(`${dirOf('/repo/.git')}/${id}.json`)
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

async function openMenu($: { command: { run: (input: never) => Promise<unknown> } }, ui: MountedUi) {
  await $.command.run({ command: 'peek-menu' } as never)
  await ui.redraw()
}

function keysIn(node: unknown, out: string[] = []): string[] {
  const key = (node as Node)?.props?.key
  if (typeof key === 'string') out.push(key)
  for (const child of (node as Node)?.children ?? []) keysIn(child, out)
  return out
}

const menuKeys = async (ui: MountedUi, prefix: string) => keysIn(await ui.drawn()).filter(one => one.startsWith(prefix))

const menuLabel = async (ui: MountedUi, key: string) => (await ui.find({ key }))?.props.label

type MenuUi = MountedUi & { input: (q: { key: string; text: string; kind?: 'change' | 'submit' }) => Promise<unknown> }

async function mountPane($: { ui: { mount: (input: never) => Promise<unknown> } }): Promise<MenuUi> {
  return (await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: paneProps, requestId: 'peek' } as never)) as MenuUi
}

test('Star this group in the ctrl+k menu, on a group page and on a card, toggles the group star shown in the Groups tab', async ($, on) => {
  const w = groupsWorld(on)
  const { id } = await create($, [{ target: 'docs/plan.md' }], 'Alpha')
  const ui = await openFirstGroup($)
  await openMenu($, ui)
  expect(await menuLabel(ui, 'menu-group-star')).toBe('Star this group')
  await ui.press({ key: 'menu-group-star' })
  expect(savedGroup(w, id)?.starred).toBe(true)
  await ui.press({ key: 'mode-groups' })
  expect(await ui.find({ text: /^1 group · 1 starred$/ })).toBeDefined()
  await openMenu($, ui)
  expect(await menuLabel(ui, 'menu-group-star')).toBe('Unstar this group')
  await ui.press({ key: 'menu-group-star' })
  expect(savedGroup(w, id)?.starred).toBe(false)
  expect(await ui.find({ text: /^1 group · 0 starred$/ })).toBeDefined()
  await ui.unmount()
})

test('adding the viewed file through ctrl+k puts it in the unsectioned block; read_group says the person added it', async ($, on) => {
  const w = groupsWorld(on)
  const { id } = await create($, [{ target: PAGE }], 'Launch')
  await call($, 'save_group', { id, sections: [{ action: 'add', title: 'Docs' }], add: [{ target: PR, section: 'Docs' }] })
  await $.command.run({ command: 'peek', args: '/repo/docs/plan.md' } as never)
  const ui = await mountPane($)
  await openMenu($, ui)
  expect(await menuLabel(ui, `menu-group-add-${id}`)).toBe('Add to group: Launch')
  expect(await ui.find({ key: `menu-group-remove-${id}` })).toBeUndefined()
  await ui.press({ key: `menu-group-add-${id}` })
  expect(w.toasts).toContain('Added to Launch')
  const read = jsonOf(await call($, 'read_group', { id })) as { items: { ref: string; addedBy: string; section: string | null }[] }
  expect(read.items.find(one => one.ref === 'docs/plan.md')).toMatchObject({ addedBy: 'person', section: null })
  await ui.press({ key: 'mode-groups' })
  await ui.press({ key: 'item-0' })
  expect(await rowTexts(ui)).toContain('plan.md')
  await ui.unmount()
})

test('after the person removes an agent item from the group page, an agent re-add is skipped and reported', async ($, on) => {
  const w = groupsWorld(on)
  const { id } = await create($, [{ target: 'docs/plan.md' }, { target: 'notes/todo.md' }])
  const ui = await openFirstGroup($)
  await ui.press({ key: 'next' })
  await openMenu($, ui)
  expect(await menuLabel(ui, 'menu-group-remove-here')).toBe('Remove from this group')
  await ui.press({ key: 'menu-group-remove-here' })
  expect(w.toasts).toContain('Removed from Launch')
  expect(await rowTexts(ui)).toEqual(['plan.md'])
  const text = await call($, 'save_group', { id, add: [{ target: 'notes/todo.md' }] })
  const outcome = (jsonOf(text).outcomes as { status: string; reason: string; needsForce?: boolean }[])[0]
  expect(outcome).toMatchObject({ status: 'refused', needsForce: true })
  expect(outcome?.reason).toMatch(/person removed/)
  expect(savedGroup(w, id)?.items.map(one => one.ref)).toEqual(['docs/plan.md'])
  await ui.unmount()
})

test('an agent update after the person added an item keeps that item', async ($, on) => {
  const w = groupsWorld(on)
  const { id } = await create($, [{ target: PAGE }])
  await $.command.run({ command: 'peek', args: '/repo/notes/todo.md' } as never)
  const ui = await mountPane($)
  await openMenu($, ui)
  await ui.press({ key: `menu-group-add-${id}` })
  await call($, 'save_group', { id, title: 'Launch v2', sections: [{ action: 'add', title: 'Later' }], add: [{ target: 'docs/plan.md', section: 'Later' }], remove: [{ target: PAGE }] })
  expect(savedGroup(w, id)?.items).toEqual([
    expect.objectContaining({ ref: 'notes/todo.md', addedBy: 'person' }),
    expect.objectContaining({ ref: 'docs/plan.md', addedBy: 'agent' }),
  ])
  expect(savedGroup(w, id)?.title).toBe('Launch v2')
  await ui.unmount()
})

test('Remove from group shows only for groups holding the viewed item, matched by the same normalisation the agent uses', async ($, on) => {
  const w = groupsWorld(on)
  const a = await create($, [{ target: 'docs/plan.md' }], 'Alpha')
  w.now += 1000
  const b = await create($, [{ target: PAGE }], 'Beta')
  w.now += 1000
  const c = await create($, [{ target: '/repo/docs/plan.md' }], 'Gamma')
  await $.command.run({ command: 'peek', args: '/repo/docs/plan.md' } as never)
  const ui = await mountPane($)
  await openMenu($, ui)
  expect(await menuKeys(ui, 'menu-group-')).toEqual([`menu-group-remove-${c.id}`, `menu-group-add-${b.id}`, `menu-group-remove-${a.id}`])
  expect(await menuLabel(ui, `menu-group-remove-${a.id}`)).toBe('Remove from group: Alpha')
  await ui.press({ key: `menu-group-remove-${a.id}` })
  expect(w.toasts).toContain('Removed from Alpha')
  expect(savedGroup(w, a.id)?.items).toEqual([])
  await openMenu($, ui)
  expect(await ui.find({ key: `menu-group-add-${a.id}` })).toBeDefined()
  await ui.unmount()
})

test('a PR read in Recent matches a group holding its /files URL; adding in Recent acts on the selected entry', async ($, on) => {
  const w = groupsWorld(on)
  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc
  on('tool.call', async () => ({ result: [{ type: 'text', text: `see ${PR}` }] }) as never)
  const held = await create($, [{ target: `${PR}/files` }], 'Alpha')
  w.now += 1000
  const empty = await create($, [{ target: PAGE }], 'Beta')
  // @ts-ignore TS2589: tool.call's types span every tool's input, too deep for tsc
  await $.tool.call({ tool: 'mcp__github__get_pull_request', tool_use_id: 'c1', number: 42 } as never)
  await $.command.run({ command: 'peek', args: '/repo/docs/plan.md' } as never)
  const ui = await mountPane($)
  await ui.press({ key: 'mode-recent' })
  await openMenu($, ui)
  expect(await menuKeys(ui, 'menu-group-')).toEqual([`menu-group-add-${empty.id}`, `menu-group-remove-${held.id}`])
  await openMenu($, ui)
  await ui.press({ key: 'next' })
  await openMenu($, ui)
  expect(await menuKeys(ui, 'menu-group-')).toEqual([`menu-group-add-${empty.id}`, `menu-group-add-${held.id}`])
  await ui.press({ key: `menu-group-add-${empty.id}` })
  expect(savedGroup(w, empty.id)?.items.map(one => one.ref)).toEqual([PAGE, 'docs/plan.md'])
  await ui.unmount()
})

test('a folder view adds the folder itself, never its .. row; an error view lists no add rows', async ($, on) => {
  const w = groupsWorld(on)
  const { id } = await create($, [{ target: PAGE }], 'Alpha')
  await $.command.run({ command: 'peek', args: '/repo/docs' } as never)
  const ui = await mountPane($)
  await openMenu($, ui)
  await ui.press({ key: `menu-group-add-${id}` })
  expect(savedGroup(w, id)?.items.map(one => one.ref)).toEqual([PAGE, 'docs'])
  await $.command.run({ command: 'peek', args: 'https://example.test/broken' } as never)
  await openMenu($, ui)
  expect(await ui.find({ text: /Could not open|HTTP 404|Not found/ })).toBeDefined()
  expect(await menuKeys(ui, 'menu-group-')).toEqual([])
  await ui.unmount()
})

test('with 12 groups the menu shows 8 add rows, most recently updated first, and typing finds the others', async ($, on) => {
  const w = groupsWorld(on)
  const ids: string[] = []
  for (let i = 1; i <= 12; i++) {
    w.now += 1000
    ids.push((await create($, [{ target: PAGE }], `Set ${String(i).padStart(2, '0')}`)).id)
  }
  await $.command.run({ command: 'peek', args: '/repo/docs/plan.md' } as never)
  const ui = await mountPane($)
  await openMenu($, ui)
  const shown = await menuKeys(ui, 'menu-group-add-')
  expect(shown).toEqual(ids.slice(4).reverse().map(one => `menu-group-add-${one}`))
  const rowKeys = await menuKeys(ui, 'menu-row-')
  expect(rowKeys.filter(one => one.startsWith('menu-row-group-'))).toHaveLength(8)
  expect(new Set(rowKeys).size).toBe(rowKeys.length)
  await ui.input({ key: 'menu-filter', text: 'set 02', kind: 'change' })
  expect(await menuKeys(ui, 'menu-group-add-')).toEqual([`menu-group-add-${ids[1]}`])
  await ui.input({ key: 'menu-filter', text: 'set 02' })
  expect(w.toasts).toContain('Added to Set 02')
  expect(savedGroup(w, ids[1] ?? '')?.items.map(one => one.ref)).toEqual([PAGE, 'docs/plan.md'])
  await ui.unmount()
})

test('a person add to a deleted group is refused with a toast; a failed write never says Added', async ($, on) => {
  const w = groupsWorld(on)
  const gone = await create($, [{ target: PAGE }], 'Alpha')
  const kept = await create($, [{ target: PAGE }], 'Beta')
  await $.command.run({ command: 'peek', args: '/repo/docs/plan.md' } as never)
  const ui = await mountPane($)
  await openMenu($, ui)
  delete w.files[`${dirOf('/repo/.git')}/${gone.id}.json`]
  w.touch(`${dirOf('/repo/.git')}/${gone.id}.json`)
  await ui.press({ key: `menu-group-add-${gone.id}` })
  expect(w.toasts).toEqual(['That group was deleted.'])
  expect(savedGroup(w, gone.id)).toBeUndefined()
  w.isMvBroken = true
  await openMenu($, ui)
  await ui.press({ key: `menu-group-add-${kept.id}` })
  expect(w.toasts.at(-1)).toMatch(/^Could not add to Beta: /)
  expect(w.toasts.some(one => one.startsWith('Added'))).toBe(false)
  expect(savedGroup(w, kept.id)?.items.map(one => one.ref)).toEqual([PAGE])
  await ui.unmount()
})

test('an add row pressed after another writer already added the item says Already in, and adds nothing twice', async ($, on) => {
  const w = groupsWorld(on)
  const { id } = await create($, [{ target: PAGE }], 'Launch')
  await $.command.run({ command: 'peek', args: '/repo/docs/plan.md' } as never)
  const ui = await mountPane($)
  await openMenu($, ui)
  editGroup(w, id, group => (group.items as unknown[]).push({ ref: 'docs/plan.md', addedBy: 'agent', addedAt: w.now }))
  await ui.press({ key: `menu-group-add-${id}` })
  expect(w.toasts).toEqual(['Already in Launch'])
  expect(savedGroup(w, id)?.items.map(one => one.ref)).toEqual([PAGE, 'docs/plan.md'])
  await ui.unmount()
})

const drawnText = async (ui: MountedUi) => JSON.stringify(await ui.drawn())

test('a starred group sits above Favourites in Recent; f on it unstars the group, not a file, and it leaves the block', async ($, on) => {
  const w = groupsWorld(on)
  const storeKeys: string[] = []
  on('store.set', (_$, e, next) => {
    storeKeys.push(e.key)
    return next(e)
  })
  const alpha = await create($, [{ target: PAGE }], 'Alpha')
  w.now += 60_000
  await create($, [{ target: PR }], 'Beta')
  editGroup(w, alpha.id, group => (group.starred = true))
  await call($, 'star', { target: '/repo/docs/plan.md' })
  expect(storeKeys).toContain('stars')
  storeKeys.length = 0
  const ui = await mountPane($)
  await ui.press({ key: 'mode-recent' })
  const text = await drawnText(ui)
  expect(text.indexOf('STARRED GROUPS')).toBeGreaterThan(-1)
  expect(text.indexOf('STARRED GROUPS')).toBeLessThan(text.indexOf('FAVOURITES'))
  expect(await cardTitles(ui)).toEqual(['ALPHA'])
  expect((await ui.find({ key: 'item-0' }))?.props.label).toBe('\u{f51a}')
  expect(await ui.find({ key: 'hover-starred-0' })).toBeDefined()
  await openMenu($, ui)
  expect(await menuLabel(ui, 'menu-group-star')).toBe('Unstar this group')
  expect(await menuKeys(ui, 'menu-group-add-')).toEqual([])
  await openMenu($, ui)
  await ui.press({ key: 'star-selected' })
  expect(savedGroup(w, alpha.id)?.starred).toBe(false)
  expect(storeKeys).not.toContain('stars')
  await ui.redraw()
  expect(await drawnText(ui)).not.toContain('STARRED GROUPS')
  expect(await ui.find({ text: /FAVOURITES/ })).toBeDefined()
  await ui.unmount()
})

test('pinned group cards come first in Recent\'s keyboard order; o and a click open the group page', async ($, on) => {
  const w = groupsWorld(on)
  const alpha = await create($, [{ target: PAGE }], 'Alpha')
  editGroup(w, alpha.id, group => (group.starred = true))
  await call($, 'star', { target: '/repo/docs/plan.md' })
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: paneProps, requestId: 'peek' })
  await ui.press({ key: 'mode-recent' })
  await ui.press({ key: 'open-selected' })
  expect((await ui.find({ key: 'group-page-title' }))?.text).toMatch(/Alpha/)
  await ui.press({ key: 'mode-recent' })
  await ui.press({ key: 'item-0' })
  expect((await ui.find({ key: 'group-page-title' }))?.text).toMatch(/Alpha/)
  await ui.press({ key: 'mode-recent' })
  const layer = 'hover-starred-0'
  await ui.resize({ columns: 60, rows: 1, in: layer })
  await ui.pointer({ type: 'down', button: 'left', x: 10, y: 0, in: layer })
  expect((await ui.find({ key: 'group-page-title' }))?.text).toMatch(/Alpha/)
  await ui.press({ key: 'mode-recent' })
  await ui.press({ key: 'next' })
  await ui.press({ key: 'star-selected' })
  expect(savedGroup(w, alpha.id)?.starred).toBe(true)
  await ui.redraw()
  expect(await ui.find({ text: /FAVOURITES/ })).toBeUndefined()
  await ui.unmount()
})

test('with 6 starred groups Recent pins the 4 most recently updated; the Groups tab lists all 6', async ($, on) => {
  const w = groupsWorld(on)
  for (let n = 1; n <= 6; n++) {
    const { id } = await create($, [{ target: PAGE }], `Set ${n}`)
    editGroup(w, id, group => (group.starred = true))
    w.now += 60_000
  }
  const ui = await mountPane($)
  await ui.press({ key: 'mode-recent' })
  expect(await cardTitles(ui)).toEqual(['SET 6', 'SET 5', 'SET 4', 'SET 3'])
  expect(await ui.find({ text: /4 of 6/ })).toBeDefined()
  await ui.press({ key: 'mode-groups' })
  expect(await cardTitles(ui)).toHaveLength(6)
  await ui.unmount()
})

test('the pinned block ignores Recent\'s scope and role filters, shows only this project, and is absent when nothing is starred', async ($, on) => {
  const w = groupsWorld(on)
  const alpha = await create($, [{ target: PAGE }], 'Alpha')
  const ui = await mountPane($)
  await ui.press({ key: 'mode-recent' })
  expect(await drawnText(ui)).not.toContain('STARRED GROUPS')
  editGroup(w, alpha.id, group => (group.starred = true))
  await ui.press({ key: 'scope' })
  await ui.press({ key: 'role' })
  expect(await ui.find({ text: /Show: artifacts/ })).toBeDefined()
  expect(await cardTitles(ui)).toEqual(['ALPHA'])
  expect(await drawnText(ui)).toContain('STARRED GROUPS')
  w.root = '/other'
  await ui.redraw()
  expect(await drawnText(ui)).not.toContain('STARRED GROUPS')
  await ui.unmount()
})

test('deleting a starred group with force removes it from Recent', async ($, on) => {
  const w = groupsWorld(on)
  const alpha = await create($, [{ target: PAGE }], 'Alpha')
  editGroup(w, alpha.id, group => (group.starred = true))
  const ui = await mountPane($)
  await ui.press({ key: 'mode-recent' })
  expect(await cardTitles(ui)).toEqual(['ALPHA'])
  expect(await call($, 'delete_group', { id: alpha.id, force: true })).toMatch(/^Deleted group "Alpha"/)
  await ui.redraw()
  expect(await cardTitles(ui)).toEqual([])
  expect(await drawnText(ui)).not.toContain('STARRED GROUPS')
  await ui.unmount()
})
