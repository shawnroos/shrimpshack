// RFC 4180: quoted fields may hold the delimiter, newlines and doubled quotes.
export function parseDelimited(text: string, delimiter = ','): string[][] {
  const rows: string[][] = []
  let row: string[] = []
  let field = ''
  let isQuoted = false
  for (let i = 0; i < text.length; i++) {
    const char = text[i]
    if (isQuoted) {
      if (char === '"' && text[i + 1] === '"') {
        field += '"'
        i += 1
      } else if (char === '"') {
        isQuoted = false
      } else {
        field += char
      }
      continue
    }
    if (char === '"' && field === '') isQuoted = true
    else if (char === delimiter) {
      row.push(field)
      field = ''
    } else if (char === '\n' || char === '\r') {
      if (char === '\r' && text[i + 1] === '\n') i += 1
      row.push(field)
      rows.push(row)
      row = []
      field = ''
    } else field += char
  }
  if (field !== '' || row.length) {
    row.push(field)
    rows.push(row)
  }
  return rows.filter(one => one.some(cell => cell !== ''))
}

export function columnWidths(rows: readonly (readonly string[])[], width: number, gap = 2): number[] {
  const count = Math.max(0, ...rows.map(row => row.length))
  const natural = Array.from({ length: count }, (_, c) =>
    Math.max(1, ...rows.slice(0, 200).map(row => (row[c] ?? '').length)),
  )
  const room = Math.max(count, width - gap * Math.max(0, count - 1))
  if (natural.reduce((a, b) => a + b, 0) <= room) return natural
  const widths = natural.map(() => 0)
  let left = room
  const order = natural.map((w, c) => ({ w, c })).sort((a, b) => a.w - b.w)
  order.forEach((one, i) => {
    const share = Math.floor(left / (order.length - i))
    const take = Math.max(1, Math.min(one.w, share))
    widths[one.c] = take
    left -= take
  })
  return widths
}

export function fitCell(text: string, width: number): string {
  const flat = text.replace(/\s+/g, ' ')
  if (flat.length <= width) return flat.padEnd(width)
  return `${flat.slice(0, Math.max(0, width - 1))}…`
}

function jsonSummary(value: unknown): string {
  if (Array.isArray(value)) return `array · ${value.length} items`
  if (value && typeof value === 'object') return `object · ${Object.keys(value).length} keys`
  return typeof value
}

export function prettyJson(text: string): { text: string; summary: string } | { error: string } {
  try {
    const value: unknown = JSON.parse(text)
    return { text: JSON.stringify(value, null, 2), summary: jsonSummary(value) }
  } catch (error) {
    return { error: error instanceof Error ? error.message : String(error) }
  }
}

export function tomlSections(text: string): number {
  return text.split('\n').filter(line => /^\s*\[{1,2}[^\]]+\]{1,2}\s*(#.*)?$/.test(line)).length
}
