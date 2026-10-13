export type SessionMemo<T> = {
  get: (key: string, make: () => Promise<T>) => Promise<T>
  forget: (key: string) => void
}

// `keep` decides which settled answers stay; a rejected one never does. Without `keep`, every promise stays,
// rejected or not. Past `max` entries the whole memo is cleared before the next one goes in.
export function sessionMemo<T>(options: { max?: number; keep?: (value: T) => boolean } = {}): SessionMemo<T> {
  const memo = new Map<string, Promise<T>>()
  const { max, keep } = options
  return {
    get: (key, make) => {
      const known = memo.get(key)
      if (known) return known
      if (max !== undefined && memo.size > max) memo.clear()
      const pending = make()
      memo.set(key, pending)
      if (keep) {
        const drop = () => {
          if (memo.get(key) === pending) memo.delete(key)
        }
        void pending.then(value => keep(value) || drop(), drop)
      }
      return pending
    },
    forget: key => void memo.delete(key),
  }
}
