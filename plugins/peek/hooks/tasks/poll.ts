import { capturePlace, createIndex, folderDocPaths, readDoc, userPlace } from './store'
import type { TaskDoc, TaskIndex, TaskPlace, TasksIo } from './store'
import { noticeReads, observe } from './status'
import type { Observer } from './status'
import { createMirror } from '../mirror/watch'
import type { Mirror } from '../mirror/watch'

export type TaskSessionIo = TasksIo & { every: (ms: number, fn: () => void) => void; isActive: () => Promise<boolean> }

export type TaskSession = {
  id: string
  root: string
  places: TaskPlace[]
  observers: Observer[]
  index: TaskIndex
  mirror: Mirror
  nudge: () => void
  polled: (count: number) => Promise<void>
  refreshed: (count: number) => Promise<void>
}

// Unlike peek's refresh tick this one never pauses while the person is idle, which is when agents work, so it does
// nothing heavier than stat calls until a timestamp moves.
const POLL_MS = 3_000
const REFRESH_MS = 15_000

type Counter = { count: number; waiters: { count: number; resolve: () => void }[] }

function bump(counter: Counter) {
  counter.count++
  for (const one of counter.waiters.filter(waiter => counter.count >= waiter.count)) {
    counter.waiters.splice(counter.waiters.indexOf(one), 1)
    one.resolve()
  }
}

const reached = (counter: Counter, count: number) =>
  counter.count >= count ? Promise.resolve() : new Promise<void>(resolve => counter.waiters.push({ count, resolve }))

let current: TaskSession | null = null

export const taskSession = () => current

// The session root is where the session started, which can be a folder inside the worktree.
async function worktreeOf(io: TasksIo, root: string): Promise<string> {
  const ran = await io.run(['git', '-C', root, 'rev-parse', '--path-format=absolute', '--show-toplevel']).catch(() => null)
  return (ran?.exitCode === 0 && ran.stdout.split('\n')[0]?.trim()) || root
}

export async function startTaskPoll(io: TaskSessionIo, started: { id: string; root: string }): Promise<TaskSession> {
  const session = { id: started.id, root: await worktreeOf(io, started.root) }
  const repo = await capturePlace(io, session.root)
  const places = repo.isUser ? [repo] : [repo, await userPlace(io)]
  const observers = places.map(place => observe(io, place, session))
  await Promise.all(observers.map(one => one.prime()))
  const index = createIndex(session.root)
  const mirror = createMirror(io, session)
  await mirror.noteStart().catch(() => undefined)
  const folderTimes = places.map(() => new Map<string, number>())
  const folderStamps = places.map((): { mtimeMs?: number } => ({}))

  const notice = async (place: TaskPlace, docs: readonly TaskDoc[]) => {
    if (docs.length) await noticeReads(io, place, docs, session.id)
  }

  const movedFolderDocs = async (at: number, isFull: boolean): Promise<TaskDoc[]> => {
    const place = places[at]
    const times = folderTimes[at]
    const stamp = folderStamps[at]
    if (!place || !times || !stamp) return []
    const folder = await io.stat(place.folder)
    const isListed = isFull || !folder || folder.mtimeMs !== stamp.mtimeMs
    stamp.mtimeMs = folder?.mtimeMs
    const paths = isListed ? await folderDocPaths(io, place) : [...times.keys()]
    const wanted = new Set(paths)
    for (const path of [...times.keys()]) if (!wanted.has(path)) times.delete(path)
    const moved: TaskDoc[] = []
    await Promise.all(
      paths.map(async path => {
        const stat = isFull ? null : await io.stat(path)
        if (stat && stat.mtimeMs === times.get(path)) return
        const doc = await readDoc(io, path)
        if (!doc) return
        times.set(path, doc.mtimeMs)
        moved.push(doc)
      }),
    )
    return moved
  }

  const refresh = async () => {
    await index.refresh(io)
    await notice(repo, index.docs())
    for (const [at, place] of places.entries()) await notice(place, await movedFolderDocs(at, true))
  }

  const pollOnce = async () => {
    if (!repo.isUser) await notice(repo, await index.changed(io))
    for (const [at, place] of places.entries()) await notice(place, await movedFolderDocs(at, false))
    await mirror.poll().catch(() => undefined)
    for (const one of observers) await one.poll()
  }

  await refresh()
  const polls: Counter = { count: 0, waiters: [] }
  const refreshes: Counter = { count: 0, waiters: [] }
  let isPolling = false
  let isRefreshing = false
  const tick = () => {
    if (isPolling) return
    isPolling = true
    void pollOnce()
      .catch(() => undefined)
      .finally(() => {
        isPolling = false
        bump(polls)
      })
  }
  io.every(POLL_MS, tick)
  io.every(REFRESH_MS, () => {
    if (isRefreshing) return
    isRefreshing = true
    void (async () => {
      if (await io.isActive()) await refresh()
    })()
      .catch(() => undefined)
      .finally(() => {
        isRefreshing = false
        bump(refreshes)
      })
  })
  current = { ...session, places, observers, index, mirror, nudge: tick, polled: count => reached(polls, count), refreshed: count => reached(refreshes, count) }
  return current
}
