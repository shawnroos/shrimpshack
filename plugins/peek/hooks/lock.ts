import { shortId } from './groups'
import type { GroupsIo } from './groups'

type LockIo = Pick<GroupsIo, 'run' | 'read' | 'write' | 'stat' | 'now' | 'sleep'>

const LOCK_STALE_MS = 10_000
const LOCK_POLL_MS = 100
// 20 polls of 100 ms: a lock still held after about 2 s refuses the write.
const LOCK_POLLS = 20

const ownerOf = (lock: string) => `${lock}/owner`

export async function dropLock(io: LockIo, lock: string) {
  await io.run(['rm', '-f', ownerOf(lock)]).catch(() => null)
  await io.run(['rmdir', lock]).catch(() => null)
}

// A lock older than LOCK_STALE_MS can be broken by another session while its holder is
// still running, so a holder re-checks this token before it commits or releases.
export async function holdsLock(io: LockIo, lock: string, token: string): Promise<boolean> {
  return (await io.read(ownerOf(lock)).catch(() => null)) === token
}

export async function takeLock(io: LockIo, lock: string): Promise<string | null> {
  let hasBroken = false
  for (let poll = 0; poll <= LOCK_POLLS; poll++) {
    const made = await io.run(['mkdir', lock]).catch(() => null)
    if (made?.exitCode === 0) {
      const token = `${shortId(Math.random)}${shortId(Math.random)}`
      const wrote = await io.write(ownerOf(lock), token).then(
        () => true,
        () => false,
      )
      if (wrote) return token
      await dropLock(io, lock)
      return null
    }
    const held = await io.stat(lock).catch(() => null)
    if (held && !hasBroken && (await io.now()) - held.mtimeMs > LOCK_STALE_MS) {
      hasBroken = true
      await dropLock(io, lock)
      continue
    }
    if (poll < LOCK_POLLS) await io.sleep(LOCK_POLL_MS)
  }
  return null
}

// One process queues its own writes per key, so a pane action and a tool call never race each other for the lock.
export function queuedBy<T>(queues: Map<string, Promise<unknown>>, key: string, work: () => Promise<T>): Promise<T> {
  const run = (queues.get(key) ?? Promise.resolve()).then(work)
  const tail = run.catch(() => undefined)
  queues.set(key, tail)
  void tail.then(() => {
    if (queues.get(key) === tail) queues.delete(key)
  })
  return run
}
