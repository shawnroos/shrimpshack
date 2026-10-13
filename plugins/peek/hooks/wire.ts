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

export function asPositiveInt(value: unknown): number | null {
  const number = typeof value === 'number' ? value : typeof value === 'string' && /^\d+$/.test(value) ? Number(value) : NaN
  return Number.isInteger(number) && number > 0 ? number : null
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

export function bareHost(url: URL): string
export function bareHost(url: string): string | undefined
export function bareHost(url: URL | string): string | undefined {
  return (typeof url === 'string' ? parseUrl(url) : url)?.hostname.replace(/^www\./, '')
}

export type Entity = 'nbsp' | 'lt' | 'gt' | 'quot' | '#39' | 'apos' | 'amp'

// &amp; runs last so `&amp;lt;` decodes once, to `&lt;`.
const NAMED: readonly [Entity, RegExp, string][] = [
  ['nbsp', /&nbsp;/g, ' '],
  ['lt', /&lt;/g, '<'],
  ['gt', /&gt;/g, '>'],
  ['quot', /&quot;/g, '"'],
  ['#39', /&#39;/g, "'"],
  ['apos', /&apos;/g, "'"],
  ['amp', /&amp;/g, '&'],
]

function safeChar(code: number): string | undefined {
  return Number.isFinite(code) && code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : undefined
}

// Each caller decodes its own set on purpose: Slack's mrkdwn escapes only < > &, and widening a set changes the text shown.
export function decodeEntities(text: string, names: readonly Entity[], numeric = false): string {
  let out = numeric
    ? text
        .replace(/&#x([0-9a-f]+);/gi, (whole, hex: string) => safeChar(Number.parseInt(hex, 16)) ?? whole)
        .replace(/&#(\d+);/g, (whole, dec: string) => safeChar(Number.parseInt(dec, 10)) ?? whole)
    : text
  for (const [name, pattern, char] of NAMED) if (names.includes(name)) out = out.replace(pattern, char)
  return out
}

export function markedStderr(stderr: string, marker: string): string | null {
  const cut = stderr.lastIndexOf(marker)
  return cut >= 0 ? stderr.slice(cut + marker.length) : null
}
