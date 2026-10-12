import type { GalleryType } from './lib'
import { familyOf } from './refs'

const KIND_LABELS: Record<string, { glyph: string; label: string }> = {
  markdown: { glyph: '¶', label: 'Markdown' },
  text: { glyph: '‹›', label: 'Code' },
  mermaid: { glyph: '◇', label: 'Diagram' },
  image: { glyph: '▣', label: 'Image' },
  svg: { glyph: '▣', label: 'SVG' },
  html: { glyph: '◎', label: 'HTML' },
  folder: { glyph: '▸', label: 'Folder' },
  web: { glyph: '◎', label: 'Web page' },
}

export function kindLabel(kind: string | undefined): { glyph: string; label: string } {
  return KIND_LABELS[kind ?? ''] ?? { glyph: '·', label: 'File' }
}

export function typeOf(kind: string): GalleryType {
  if (kind === 'markdown') return 'markdown'
  if (kind === 'image' || kind === 'svg') return 'image'
  if (kind === 'mermaid') return 'diagram'
  if (kind === 'html' || kind === 'web' || familyOf(kind) !== 'web') return 'html'
  if (kind === 'json' || kind === 'toml' || kind === 'csv') return 'data'
  return 'code'
}
