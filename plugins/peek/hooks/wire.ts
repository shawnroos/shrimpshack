export type Json = Record<string, unknown>

export function asObj(value: unknown): Json | null {
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as Json) : null
}

export function asStr(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() ? value.trim() : undefined
}

export function asNum(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined
}

export function asArr(value: unknown): unknown[] {
  return Array.isArray(value) ? value : []
}

export function asDay(value: unknown): string | undefined {
  return asStr(value)?.slice(0, 10)
}

// JSON.parse never yields undefined, so undefined means the text was not JSON.
export function tryJson(text: string): unknown {
  try {
    return JSON.parse(text)
  } catch {
    return undefined
  }
}

export function parseUrl(raw: string, base?: string): URL | null {
  try {
    return new URL(raw, base)
  } catch {
    return null
  }
}

export function markedStderr(stderr: string, marker: string): string | null {
  const cut = stderr.lastIndexOf(marker)
  return cut >= 0 ? stderr.slice(cut + marker.length) : null
}
