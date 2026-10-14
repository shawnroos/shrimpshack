import type { PropValue } from '../../types'
import { readFrontmatter } from '../frontmatter'
import { groupsDir, shortId } from '../groups'

export type TasksIo = {
  read: (path: string) => Promise<string>
  write: (path: string, text: string) => Promise<void>
  list: (dir: string) => Promise<readonly { name: string; kind: string }[]>
  stat: (path: string) => Promise<{ mtimeMs: number } | null>
  run: (argv: readonly string[]) => Promise<{ exitCode: number; stdout: string; stderr: string }>
  now: () => Promise<number>
  sleep: (ms: number) => Promise<void>
  home: () => Promise<string | undefined>
}

export type TaskPlace = { key: string; folder: string; stateDir: string; excludeFile?: string; isUser: boolean }
export type TaskDoc = { path: string; props: Record<string, PropValue>; status?: string; mtimeMs: number; worktree?: string }
export type TaskWrite = { status: 'applied'; reason: string; path: string; id: string } | { status: 'refused'; reason: string }

export const TASK_CAPS = { folderDocs: 500, indexed: 2000, name: 200 }

const EXCLUDE_LINE = '.peek/'
const STATUS_WORD = /^[a-z][a-z_-]{0,31}$/
const UNSAFE = /[\u0000-\u001F\u007F-\u009F\u2028\u2029]/g

export const isStatusWord = (status: string) => STATUS_WORD.test(status)

const parentOf = (path: string) => path.slice(0, path.lastIndexOf('/'))

async function dataDir(io: TasksIo): Promise<string> {
  const home = await io.home()
  if (!home) throw new Error('HOME is not set, so peek has nowhere to keep tasks')
  return `${home}/.local/share/claude-peek`
}

export async function userPlace(io: TasksIo): Promise<TaskPlace> {
  const data = await dataDir(io)
  return { key: 'user', folder: `${data}/tasks`, stateDir: `${data}/task-log/user`, isUser: true }
}

export async function capturePlace(io: TasksIo, worktree: string): Promise<TaskPlace> {
  const ran = await io.run(['git', '-C', worktree, 'rev-parse', '--path-format=absolute', '--git-common-dir']).catch(() => null)
  const common = ran?.exitCode === 0 ? ran.stdout.trim() : ''
  if (!common) return userPlace(io)
  const data = await dataDir(io)
  return {
    key: common,
    folder: `${parentOf(common)}/.peek/tasks`,
    // The groups folder is named by the project's hash; the log reuses that name rather than a second hash.
    stateDir: `${data}/task-log/${groupsDir('', common).split('/').at(-1) ?? 'unknown'}`,
    excludeFile: `${common}/info/exclude`,
    isUser: false,
  }
}

export function statusOf(text: string): string | undefined {
  const status = readFrontmatter(text).props?.status
  return typeof status === 'string' ? status : undefined
}

export async function readDoc(io: TasksIo, path: string, worktree?: string): Promise<TaskDoc | null> {
  const [text, stat] = await Promise.all([io.read(path).catch(() => null), io.stat(path)])
  if (text === null) return null
  const props = readFrontmatter(text).props ?? {}
  const status = typeof props.status === 'string' ? props.status : undefined
  return { path, props, ...(status ? { status } : {}), mtimeMs: stat?.mtimeMs ?? 0, ...(worktree ? { worktree } : {}) }
}

export async function folderDocPaths(io: TasksIo, place: TaskPlace): Promise<string[]> {
  const entries = await io.list(place.folder).catch(() => [])
  return entries
    .filter(one => one.kind === 'file' && one.name.endsWith('.md'))
    .map(one => `${place.folder}/${one.name}`)
    .sort()
    .slice(0, TASK_CAPS.folderDocs)
}

export async function listFolderTasks(io: TasksIo, place: TaskPlace): Promise<TaskDoc[]> {
  const docs = await Promise.all((await folderDocPaths(io, place)).map(path => readDoc(io, path)))
  return docs.filter((one): one is TaskDoc => one !== null)
}

async function ensureExcluded(io: TasksIo, file: string): Promise<void> {
  const isPresent = (await io.stat(file)) !== null
  const text = isPresent ? await io.read(file).catch(() => null) : ''
  // An exclude file that exists but cannot be read is left alone, never overwritten with one line.
  if (text === null) return
  if (text.split('\n').some(one => one.trim() === EXCLUDE_LINE || one.trim() === `/${EXCLUDE_LINE}`)) return
  await io.run(['mkdir', '-p', parentOf(file)])
  await io.write(file, `${text}${text && !text.endsWith('\n') ? '\n' : ''}${EXCLUDE_LINE}\n`)
}

const oneLine = (text: string) => text.replace(UNSAFE, ' ').trim()

function slugOf(name: string): string {
  const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+/, '').slice(0, 40).replace(/-+$/, '')
  return slug || 'task'
}

export async function createTask(io: TasksIo, place: TaskPlace, input: { name: string; creator: string; status?: string; body?: string }): Promise<TaskWrite> {
  const name = oneLine(input.name)
  const creator = oneLine(input.creator)
  const status = input.status ?? 'todo'
  if (!name) return { status: 'refused', reason: 'A task needs a name' }
  if (name.length > TASK_CAPS.name) return { status: 'refused', reason: `A task name holds at most ${TASK_CAPS.name} characters` }
  if (!creator) return { status: 'refused', reason: 'A task needs a creator' }
  if (!isStatusWord(status)) return { status: 'refused', reason: `"${status}" is not a status` }
  const made = await io.run(['mkdir', '-p', place.folder]).catch(() => null)
  if (made?.exitCode !== 0) return { status: 'refused', reason: `Could not create the tasks folder ${place.folder}` }
  if (place.excludeFile) await ensureExcluded(io, place.excludeFile).catch(() => undefined)
  const id = shortId(Math.random)
  const path = `${place.folder}/${slugOf(name)}-${id}.md`
  const text = ['---', `name: ${JSON.stringify(name)}`, `id: ${id}`, `status: ${status}`, `creator: ${JSON.stringify(creator)}`, '---', input.body ?? ''].join('\n')
  const stagedDir = `${place.stateDir}/staged`
  const staged = `${stagedDir}/${id}.${shortId(Math.random)}.staged`
  const ready = await io.run(['mkdir', '-p', stagedDir]).catch(() => null)
  const wrote =
    ready?.exitCode === 0 &&
    (await io.write(staged, text).then(
      () => true,
      () => false,
    ))
  if (!wrote) return { status: 'refused', reason: `Could not write ${staged}` }
  const moved = await io.run(['mv', '-f', staged, path]).catch(() => null)
  if (moved?.exitCode !== 0) {
    await io.run(['rm', '-f', staged]).catch(() => null)
    return { status: 'refused', reason: `Could not write ${path}` }
  }
  return { status: 'applied', reason: `Captured "${name}"`, path, id }
}

export type TaskIndex = {
  refresh: (io: TasksIo) => Promise<void>
  changed: (io: TasksIo) => Promise<TaskDoc[]>
  docs: () => TaskDoc[]
}

// Tracked markdown with `isTask: true` in one worktree. A head is re-read only when its file's timestamp moves.
export function createIndex(worktree: string): TaskIndex {
  const seen = new Map<string, { mtimeMs: number; doc: TaskDoc | null }>()
  const look = async (io: TasksIo, path: string) => {
    const doc = await readDoc(io, path, worktree)
    seen.set(path, { mtimeMs: doc?.mtimeMs ?? 0, doc: doc?.props.isTask === true ? doc : null })
    return doc
  }
  return {
    refresh: async io => {
      const ran = await io.run(['git', '-C', worktree, 'ls-files', '-z', '--', '*.md']).catch(() => null)
      if (ran?.exitCode !== 0) return
      const paths = ran.stdout
        .split('\0')
        .filter(Boolean)
        .slice(0, TASK_CAPS.indexed)
        .map(one => `${worktree}/${one}`)
      const wanted = new Set(paths)
      for (const path of [...seen.keys()]) if (!wanted.has(path)) seen.delete(path)
      await Promise.all(
        paths.map(async path => {
          const stat = await io.stat(path)
          if (stat && seen.get(path)?.mtimeMs !== stat.mtimeMs) await look(io, path)
        }),
      )
    },
    changed: async io => {
      const moved: TaskDoc[] = []
      const tasks = [...seen].filter(([, one]) => one.doc)
      await Promise.all(
        tasks.map(async ([path, one]) => {
          const stat = await io.stat(path)
          if (!stat || stat.mtimeMs === one.mtimeMs) return
          const doc = await look(io, path)
          if (doc) moved.push(doc)
        }),
      )
      return moved
    },
    docs: () => [...seen.values()].flatMap(one => (one.doc ? [one.doc] : [])),
  }
}
