import type { On, ProcessRunResult } from 'claude-code'
import { groupsDir } from '../../hooks/groups'
import type { TasksIo } from '../../hooks/tasks/store'
import { resetRefresh } from '../../hooks/refresh'

// A PNG signature and an 800x600 IHDR chunk: the engine checks both before it draws.
export const PNG_HEAD = 'iVBORw0KGgoAAAANSUhEUgAAAyAAAAJYCAIAAAAVFBUn'
export { MARKER as CURL_MARKER, TYPE_MARKER } from '../../hooks/parsers/curl'

export const PANE_PROPS = {
  title: 'Peek',
  isFocused: true,
  bodyColumns: 100,
  placement: 'dock' as const,
  scroll: { offset: 0, bodyRows: 40 },
  view: {},
}

export function baseWorld(on: On) {
  on('session.cwd', () => ({ value: '/repo' }))
  on('env.get', (_$, e) => ({ value: e.name === 'HOME' ? '/home' : undefined }))
  on('ui.open', () => ({ value: { isPlaced: true as const } }))
  on('ui.toast', () => ({ value: undefined }))
}

export function fakeHttp(on: On) {
  on('http.fetch', () => ({ value: { status: 404, ok: false, headers: {} as Record<string, string>, text: '' } }))
}

export function noDisk(on: On) {
  on('fs.stat', (_$, e) => {
    throw new Error(`ENOENT ${e.path}`)
  })
}

export function fakeProcess(on: On, route: (argv: string[]) => ProcessRunResult | Promise<ProcessRunResult>, ran: string[][] = []) {
  on('process.run', async (_$, e) => {
    ran.push([...e.argv])
    return { value: await route([...e.argv]) }
  })
  return ran
}

export const HOME = '/home'
export const PR = 'https://github.com/acme/widgets/pull/42'
export const LINEAR = 'https://linear.app/acme/issue/WEB-12'
export const PAGE = 'https://example.test/page'

export type World = {
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
  tracked?: Record<string, string[]>
  onLockBusy?: (lock: string) => void
  onWrite?: (path: string) => void
  onRun?: (argv: string[]) => Promise<RunAnswer | undefined> | RunAnswer | undefined
  onFetch?: (url: string) => { status: number; text?: string } | Error | undefined
}

export type RunAnswer = { exitCode: number; stdout?: string; stderr?: string }

// Shared by every world, so an mtime never repeats across tests while the plugin's module state lives on.
let lastMtime = 9 * 3600_000

export function fakeFs(on: On, files: Record<string, string> = {}, options: { isClockMocked?: boolean } = {}): World {
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
    if (bin === 'git' && argv.includes('ls-files') && w.tracked) {
      const listed = w.tracked[rest[rest.indexOf('-C') + 1] ?? '']
      return listed ? done(0, listed.map(one => `${one}\0`).join('')) : done(128)
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

export async function call($: { tool: { call: (input: never) => Promise<unknown> } }, tool: string, input: Record<string, unknown>): Promise<string> {
  const answer = (await $.tool.call({ tool: `mcp__peek__${tool}`, tool_use_id: `${tool}-${Math.random()}`, ...input } as never)) as ToolAnswer
  return String(answer.result ?? answer.deny ?? '')
}

export function jsonOf(text: string): Record<string, unknown> {
  return JSON.parse(text.slice(text.indexOf('\n') + 1)) as Record<string, unknown>
}

export const dirOf = (projectKey: string) => groupsDir(HOME, projectKey)

export function savedGroup(w: World, id: string, projectKey = '/repo/.git') {
  const text = w.files[`${dirOf(projectKey)}/${id}.json`]
  return text === undefined ? undefined : (JSON.parse(text) as { items: { ref: string; addedBy: string }[]; starred: boolean; title: string })
}

export async function create($: Parameters<typeof call>[0], add: unknown[], title = 'Launch') {
  const text = await call($, 'save_group', { title, add })
  const id = String(jsonOf(text).id)
  return { text, id }
}

export type Found = { props: Record<string, unknown>; text: string } | undefined

export async function cardTitles(ui: { find: (q: { key: string }) => Promise<Found> }) {
  const titles: string[] = []
  for (let i = 0; i < 10; i++) {
    const one = await ui.find({ key: `group-name-${i}` })
    if (one) titles.push(one.text.trim())
  }
  return titles
}

export function editGroup(w: World, id: string, change: (group: Record<string, unknown>) => void) {
  const file = `${dirOf('/repo/.git')}/${id}.json`
  const group = JSON.parse(w.files[file] ?? '{}') as Record<string, unknown>
  change(group)
  w.files[file] = JSON.stringify(group)
  w.touch(file)
}

// The task modules take io ports, not `$`, so their tests call the fake world's own handlers directly.
export function tasksWorld(on: On, files: Record<string, string> = {}): { w: World; io: TasksIo } {
  const handlers = new Map<string, (...args: unknown[]) => unknown>()
  const spy = ((name: string, ...rest: unknown[]) => {
    const fn = rest.at(-1)
    if (typeof fn === 'function') handlers.set(name, fn as (...args: unknown[]) => unknown)
    return (on as unknown as (...args: unknown[]) => unknown)(name, ...rest)
  }) as unknown as On
  const w = fakeFs(spy, files)
  const call = async <T>(name: string, e: Record<string, unknown>): Promise<T> => {
    const handler = handlers.get(name)
    if (!handler) throw new Error(`the fake world does not answer ${name}`)
    return ((await handler(undefined, e)) as { value: T }).value
  }
  const io: TasksIo = {
    read: path => call<string>('fs.read', { path }),
    write: async (path, text) => {
      await call('fs.write', { path, text })
    },
    list: path => call<{ name: string; kind: string }[]>('fs.list', { path }),
    stat: path => call<{ mtimeMs: number }>('fs.stat', { path }).catch(() => null),
    run: argv => call<{ exitCode: number; stdout: string; stderr: string }>('process.run', { argv }),
    now: () => call<number>('clock.now', {}),
    sleep: async ms => {
      await call('clock.sleep', { ms })
    },
    home: () => call<string | undefined>('env.get', { name: 'HOME' }),
  }
  return { w, io }
}

export type Timers = { every: (ms: number, fn: () => void) => void; advance: (ms: number) => void }

// Fires `every` callbacks as the test moves time. Each callback starts its work without waiting, as
// $.clock.every does, so a test waits on the poll's own completion signal rather than on this.
export function fakeTimers(w: World): Timers {
  const timers: { ms: number; due: number; fn: () => void }[] = []
  return {
    every: (ms, fn) => {
      timers.push({ ms, due: w.now + ms, fn })
    },
    advance: ms => {
      const end = w.now + ms
      for (;;) {
        const next = timers.filter(one => one.due <= end).sort((a, b) => a.due - b.due)[0]
        if (!next) break
        w.now = next.due
        next.due += next.ms
        next.fn()
      }
      w.now = end
    },
  }
}

// Claude Code's own task folders, in the shapes U1 found on disk: a folder per session UUID holding `.lock`, an
// optional `.highwatermark` and one `<id>.json` per item.
export const AGENT = '2fed97d7-856a-4f46-8093-52433cc1af0b'
export const AGENT_TWO = '04b1befa-7bf3-4e11-8a58-129666ae59b4'
export const agentFolder = (session: string) => `${HOME}/.claude/tasks/${session}`

export function agentItem(w: World, session: string, id: string, subject: string, status = 'pending', blockedBy: string[] = []) {
  const folder = agentFolder(session)
  if (w.files[`${folder}/.lock`] === undefined) w.files[`${folder}/.lock`] = ''
  const path = `${folder}/${id}.json`
  w.files[path] = JSON.stringify({ id, subject, description: subject, activeForm: `Doing ${subject}`, status, blocks: [], blockedBy })
  w.touch(path)
}

export function deleteAgentItems(w: World, session: string) {
  const folder = agentFolder(session)
  for (const path of Object.keys(w.files)) if (path.startsWith(`${folder}/`) && path.endsWith('.json')) delete w.files[path]
  w.touch(`${folder}/.lock`)
}

export function clearAgentList(w: World, session: string, watermark: number) {
  deleteAgentItems(w, session)
  w.files[`${agentFolder(session)}/.highwatermark`] = String(watermark)
  w.touch(`${agentFolder(session)}/.highwatermark`)
}

export function lockOnlyFolder(w: World, session: string, watermark?: number) {
  w.files[`${agentFolder(session)}/.lock`] = ''
  if (watermark !== undefined) w.files[`${agentFolder(session)}/.highwatermark`] = String(watermark)
}

export function agentTranscript(w: World, cwd: string, session: string, lines: readonly unknown[]) {
  const path = `${HOME}/.claude/projects/${cwd.replace(/\//g, '-')}/${session}.jsonl`
  w.files[path] = lines.map(one => JSON.stringify(one)).join('\n')
  return path
}

export const MIRROR_ROOT = `${HOME}/.local/share/claude-peek/mirror`

// The list state the mirror keeps per session: each list's phase, and the repo the session was placed in.
export function mirrorListState(w: World, session: string, lists: Record<string, { phase: string; archivedAt?: number; foldedAt?: number }>, placeKey = '/repo/.git') {
  const path = `${MIRROR_ROOT}/${session}/state.json`
  w.files[path] = JSON.stringify({ count: Math.max(1, Object.keys(lists).length), watermark: 0, isCleared: false, lists, placeKey })
  w.touch(path)
}
