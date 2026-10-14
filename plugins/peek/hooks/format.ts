export function describeSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`
}

export function describeAge(thenMs: number, nowMs: number): string {
  const minutes = Math.max(0, Math.round((nowMs - thenMs) / 60000))
  if (minutes < 1) return 'just now'
  if (minutes < 60) return `${minutes}m ago`
  const hours = Math.round(minutes / 60)
  if (hours < 48) return `${hours}h ago`
  return `${Math.round(hours / 24)}d ago`
}

export function fetchedAge(fetchedAt: number | undefined, now: number): string {
  if (fetchedAt === undefined) return ''
  const seconds = Math.max(0, Math.round((now - fetchedAt) / 1000))
  return seconds < 60 ? `${seconds}s ago` : describeAge(fetchedAt, now)
}

export const plural = (count: number, word: string) => `${count} ${word}${count === 1 ? '' : 's'}`

export const clip = (text: string, max: number) => (text.length > max ? `${text.slice(0, max - 1)}…` : text)

export function initials(name: string): string {
  const words = name.split(/\s+/).map(word => word.replace(/[^\p{L}\p{N}]/gu, '')).filter(Boolean)
  const first = words[0]?.[0] ?? ''
  const last = words.length > 1 ? (words.at(-1)?.[0] ?? '') : ''
  return `${first}${last}`.toUpperCase() || '?'
}

export function whenLabel(iso: string, now: number, timeZone?: string): string {
  const at = Date.parse(iso)
  if (Number.isNaN(at)) return iso
  const day = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' })
  if (day.format(at) === day.format(now)) return describeAge(at, now)
  const isThisYear = day.format(at).slice(0, 4) === day.format(now).slice(0, 4)
  const date = new Intl.DateTimeFormat('en-US', { timeZone, month: 'short', day: 'numeric', ...(isThisYear ? {} : { year: 'numeric' }) }).format(at)
  const time = new Intl.DateTimeFormat('en-US', { timeZone, hour: 'numeric', minute: '2-digit' }).format(at)
  // Newer ICU puts a narrow no-break space before AM/PM.
  return `${date}, ${time}`.replace(/\s/g, ' ')
}
