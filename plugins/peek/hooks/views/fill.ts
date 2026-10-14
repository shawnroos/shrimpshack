import type { PropValue } from '../../types'

export type FilledPart = { kind: 'template' | 'value'; text: string }

// The same fence rule as definition.ts templateBlocks, so a placeholder inside a fence is never taken as a part.
const FENCE_LINE = /^\s*(```|~~~)\s*([\w+#.-]*)\s*(.*)$/
const ALONE = /^\s*\{\{([A-Za-z_][\w-]{0,31})\}\}\s*$/
const PLACEHOLDER = /\{\{([A-Za-z_][\w-]{0,31})\}\}/g
const MARKDOWN_SIGNS = /[\\`*_{}[\]()#+!|<>~]/g
const UNSAFE = /[\u0000-\u001F\u007F-\u009F\u2028\u2029]/g

export function plainValue(value: PropValue | undefined): string {
  if (value === undefined || value === null) return ''
  if (Array.isArray(value)) return value.map(one => plainValue(one)).filter(Boolean).join(', ')
  if (typeof value === 'object') return Object.entries(value).map(([key, one]) => `${key}: ${plainValue(one)}`).join(', ')
  return String(value).replace(UNSAFE, ' ').trim()
}

// Parts first, values second (KTD1): a placeholder alone on a line that names a markdown value becomes its own part,
// drawn as markdown on its own, so a body can never open or close the template's fences. Every other placeholder
// inserts plain text; inside a fence it lands in the block's options, where whitespace would split a value.
export function fillTemplate(template: string, values: Record<string, PropValue | undefined>, markdown: Record<string, string>): FilledPart[] {
  const parts: FilledPart[] = []
  let lines: string[] = []
  let isInFence = false
  const flush = () => {
    if (lines.length) parts.push({ kind: 'template', text: lines.join('\n') })
    lines = []
  }
  for (const line of template.split('\n')) {
    const fence = FENCE_LINE.exec(line)
    const alone = isInFence ? null : ALONE.exec(line)
    if (alone?.[1] !== undefined && Object.hasOwn(markdown, alone[1])) {
      flush()
      parts.push({ kind: 'value', text: markdown[alone[1]] ?? '' })
      continue
    }
    const isOption = isInFence || fence !== null
    lines.push(line.replace(PLACEHOLDER, (_whole, name: string) => {
      const text = plainValue(values[name])
      return isOption ? text.replace(/\s+/g, '_') : text.replace(MARKDOWN_SIGNS, '\\$&')
    }))
    if (fence && (!isInFence || !fence[2])) isInFence = !isInFence
  }
  flush()
  return parts
}
