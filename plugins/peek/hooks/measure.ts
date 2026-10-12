export function imageBox(width: number, height: number, maxColumns: number, maxRows: number) {
  const cellAspect = 2.1
  let columns = Math.max(1, Math.min(255, maxColumns))
  let rows = Math.round((columns * height) / width / cellAspect)
  if (rows > maxRows) {
    rows = maxRows
    columns = Math.max(1, Math.round((rows * width * cellAspect) / height))
  }
  return { columns: Math.min(255, columns), rows: Math.max(1, Math.min(255, rows)) }
}

// Raster cells are little-endian u32 triplets: code point, foreground, background.
export function rasterGradient(columns: number, rows: number): string {
  const words = new Uint32Array(columns * rows * 3)
  for (let y = 0; y < rows; y++) {
    for (let x = 0; x < columns; x++) {
      const at = (y * columns + x) * 3
      const red = Math.round((x / Math.max(1, columns - 1)) * 255)
      const blue = Math.round((y / Math.max(1, rows - 1)) * 255)
      const isEdge = y === 0 || y === rows - 1
      words[at] = isEdge ? 0x2580 : 0x2591
      words[at + 1] = (red << 16) | (120 << 8) | blue
      words[at + 2] = ((255 - red) << 16) | (40 << 8) | (255 - blue)
    }
  }
  const bytes = new Uint8Array(words.buffer)
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary)
}

export const IMAGE_ROWS = 10

function rowsFor(line: string, width: number): number {
  if (/^\s*!\[[^\]]*\]\([^)\s]+(?:\s+"[^"]*")?\)\s*$/.test(line)) return IMAGE_ROWS
  return Math.max(1, Math.ceil(line.length / Math.max(10, width)))
}

// Blocks are paragraphs and whole fenced blocks, so a page break never lands
// inside a fence unless the fence alone is taller than a page.
function markdownBlocks(text: string): string[][] {
  const blocks: string[][] = []
  let current: string[] = []
  let inFence = false
  for (const line of text.split('\n')) {
    const isFence = /^\s*(```|~~~)/.test(line)
    if (!inFence && !isFence && line.trim() === '') {
      if (current.length) blocks.push(current)
      current = []
      continue
    }
    if (!inFence && /^#{1,6}\s/.test(line) && current.length) {
      blocks.push(current)
      current = []
    }
    current.push(line)
    if (isFence) inFence = !inFence
  }
  if (current.length) blocks.push(current)
  return blocks
}

export function paginateMarkdown(text: string, width: number, rows: number): string[] {
  const pages: string[][] = [[]]
  let used = 0
  const startPage = () => {
    pages.push([])
    used = 0
  }
  for (const block of markdownBlocks(text)) {
    const cost = block.reduce((sum, line) => sum + rowsFor(line, width), 0) + 1
    const isHeading = /^#{1,6}\s/.test(block[0] ?? '')
    if (used > 0 && (used + cost > rows || (isHeading && used + Math.min(cost, 4) > rows))) startPage()
    if (cost <= rows) {
      pages[pages.length - 1]?.push(block.join('\n'), '')
      used += cost
      continue
    }
    const fence = /^\s*(```|~~~)(.*)$/.exec(block[0] ?? '')
    let chunk: string[] = []
    let chunkRows = 0
    const flush = (isLast: boolean) => {
      if (!chunk.length) return
      let lines = chunk
      if (fence && lines[0] !== block[0]) lines = [`${fence[1]}${fence[2]}`, ...lines]
      if (fence && !isLast) lines = [...lines, fence[1] ?? '```']
      pages[pages.length - 1]?.push(lines.join('\n'), '')
      chunk = []
      chunkRows = 0
      startPage()
    }
    block.forEach((line, index) => {
      const cost = rowsFor(line, width)
      if (chunkRows + cost > rows - 2) flush(false)
      chunk.push(line)
      chunkRows += cost
      if (index === block.length - 1) {
        let lines = chunk
        if (fence && lines[0] !== block[0]) lines = [`${fence[1]}${fence[2]}`, ...lines]
        pages[pages.length - 1]?.push(lines.join('\n'), '')
        used = chunkRows + 1
        chunk = []
      }
    })
  }
  return pages.map(page => page.join('\n').trimEnd()).filter((page, index, all) => page || all.length === 1)
}

export function estimateRows(text: string, width: number): number {
  return markdownBlocks(text).reduce((sum, block) => {
    const isTitle = /^#\s/.test(block[0] ?? '')
    const isFence = /^\s*(```|~~~)/.test(block[0] ?? '')
    const lines = block.reduce((rows, line) => rows + rowsFor(line, width), 0)
    return sum + lines + 1 + (isTitle ? 1 : 0) - (isFence ? 1 : 0)
  }, 0)
}

// One Markdown element holds at most 10,000 characters, so a long doc is drawn
// as several, cut between blocks.
export function chunkMarkdown(text: string, maxChars = 9000): string[] {
  const chunks: string[] = []
  let current = ''
  for (const block of markdownBlocks(text)) {
    const piece = block.join('\n')
    if (current && current.length + piece.length + 2 > maxChars) {
      chunks.push(current)
      current = ''
    }
    current = current ? `${current}\n\n${piece}` : piece
  }
  if (current) chunks.push(current)
  return chunks
}

export type TaskRow = { item: number; isFirst: boolean; text: string }

// Rows a task list draws at `width` columns: each task wraps under its own text
// (a hanging indent past depth*2 + the 2-column checkbox).
export function taskRows(items: readonly { text: string; depth: number }[], width: number): TaskRow[] {
  const rows: TaskRow[] = []
  items.forEach((item, index) => {
    const room = Math.max(8, width - item.depth * 2 - 2)
    const lines: string[] = ['']
    for (const word of item.text.split(/\s+/).filter(Boolean)) {
      const current = lines[lines.length - 1] ?? ''
      if (!current) lines[lines.length - 1] = word.slice(0, room)
      else if (current.length + 1 + word.length <= room) lines[lines.length - 1] = `${current} ${word}`
      else lines.push(word.slice(0, room))
    }
    lines.forEach((text, line) => rows.push({ item: index, isFirst: line === 0, text }))
  })
  return rows
}

// Keeps a list row to one line: a name past its room keeps its start and its extension.
export function fitName(name: string, room: number): string {
  if (name.length <= room) return name
  const dot = name.lastIndexOf('.')
  const ext = dot > 0 && name.length - dot <= 6 ? name.slice(dot) : ''
  const keep = Math.max(1, room - ext.length - 1)
  return `${name.slice(0, keep)}…${ext}`
}

export function wrapLines(text: string, width: number, max: number): string[] {
  const room = Math.max(1, width)
  const lines: string[] = []
  for (const paragraph of text.split('\n')) {
    let line = ''
    for (const word of paragraph.split(/\s+/).filter(Boolean)) {
      for (let rest = word; rest; ) {
        const joined = line ? `${line} ${rest}` : rest
        if (joined.length <= room) {
          line = joined
          rest = ''
        } else if (line) {
          lines.push(line)
          line = ''
        } else {
          lines.push(rest.slice(0, room))
          rest = rest.slice(room)
        }
      }
    }
    if (line) lines.push(line)
  }
  if (lines.length <= max) return lines
  const last = lines[max - 1] ?? ''
  return [...lines.slice(0, max - 1), `${last.length >= room ? last.slice(0, room - 1).trimEnd() : last}…`]
}

// `─ LABEL ──────── right ─`, the toy's lane rule, sized to the pane.
export function ruleParts(label: string, right: string, columns: number) {
  const head = ` ${label.toUpperCase()} `
  const tail = right ? ` ${right} ` : ''
  const fill = Math.max(1, columns - 2 - head.length - tail.length)
  return { head, fill: '─'.repeat(fill), tail }
}
