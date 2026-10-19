export type Selection = { item?: string; step?: number }

let selected: Selection = {}
const listeners = new Set<() => void>()

export function getSelection(): Selection {
  return selected
}

export function select(next: Selection): void {
  selected = next
  for (const listener of listeners) listener()
}

export function onSelect(listener: () => void): () => void {
  listeners.add(listener)
  return () => listeners.delete(listener)
}

export function viewedKey(item: string): string {
  return `viewed:${item}`
}
