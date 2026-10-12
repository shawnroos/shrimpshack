import type { RemoteKind } from '../types'
import type { GalleryType } from './gallery'
import type { Kind } from './paths'
import { familyOf } from './refs'
import { C, ICON } from './theme'

type KindInfo = {
  icon: string
  color: string
  type: GalleryType
  label?: { glyph: string; label: string }
}

export const KINDS: Record<Kind | 'folder' | RemoteKind, KindInfo> = {
  markdown: { icon: ICON.markdown, color: C.yellow, type: 'markdown', label: { glyph: '¶', label: 'Markdown' } },
  text: { icon: ICON.text, color: C.blue, type: 'code', label: { glyph: '‹›', label: 'Code' } },
  mermaid: { icon: ICON.mermaid, color: C.mauve, type: 'diagram', label: { glyph: '◇', label: 'Diagram' } },
  image: { icon: ICON.image, color: C.teal, type: 'image', label: { glyph: '▣', label: 'Image' } },
  svg: { icon: ICON.svg, color: C.teal, type: 'image', label: { glyph: '▣', label: 'SVG' } },
  html: { icon: ICON.html, color: C.peach, type: 'html', label: { glyph: '◎', label: 'HTML' } },
  folder: { icon: ICON.folder, color: C.overlay1, type: 'code', label: { glyph: '▸', label: 'Folder' } },
  json: { icon: ICON.json, color: C.yellow, type: 'data' },
  toml: { icon: ICON.toml, color: C.peach, type: 'data' },
  csv: { icon: ICON.csv, color: C.green, type: 'data' },
  web: { icon: ICON.web, color: C.peach, type: 'html', label: { glyph: '◎', label: 'Web page' } },
  'gh-pr': { icon: ICON['gh-pr'], color: C.green, type: 'html' },
  'gh-issue': { icon: ICON['gh-issue'], color: C.teal, type: 'html' },
  'gh-repo': { icon: ICON['gh-repo'], color: C.overlay1, type: 'html' },
  'linear-issue': { icon: ICON['linear-issue'], color: C.blue, type: 'html' },
  'linear-project': { icon: ICON['linear-project'], color: C.mauve, type: 'html' },
  'slack-thread': { icon: ICON['slack-thread'], color: C.yellow, type: 'html' },
}

function infoOf(kind: string | undefined): KindInfo | undefined {
  return (KINDS as Partial<Record<string, KindInfo>>)[kind ?? '']
}

export function iconFor(kind: string | undefined): string {
  return infoOf(kind)?.icon ?? ICON.file
}

export function colorFor(kind: string | undefined): string {
  return infoOf(kind)?.color ?? C.overlay1
}

export function kindLabel(kind: string | undefined): { glyph: string; label: string } {
  return infoOf(kind)?.label ?? { glyph: '·', label: 'File' }
}

// An unlisted remote kind (a new gh-/linear-/slack- one) still sorts as a page.
export function typeOf(kind: string): GalleryType {
  return infoOf(kind)?.type ?? (familyOf(kind) === 'web' ? 'code' : 'html')
}
