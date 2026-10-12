import { describe, expect, test } from 'claude-code/testing'

import { kindLabel, typeOf } from '../hooks/lib'
import { C, ICON, colorFor, iconFor } from '../hooks/theme'

const FILE_LABEL = { glyph: '·', label: 'File' }

type Row = { kind: string; icon: string; color: string; label: { glyph: string; label: string }; type: string }

const ROWS: Row[] = [
  { kind: 'markdown', icon: ICON.markdown, color: C.yellow, label: { glyph: '¶', label: 'Markdown' }, type: 'markdown' },
  { kind: 'text', icon: ICON.text, color: C.blue, label: { glyph: '‹›', label: 'Code' }, type: 'code' },
  { kind: 'mermaid', icon: ICON.mermaid, color: C.mauve, label: { glyph: '◇', label: 'Diagram' }, type: 'diagram' },
  { kind: 'image', icon: ICON.image, color: C.teal, label: { glyph: '▣', label: 'Image' }, type: 'image' },
  { kind: 'svg', icon: ICON.svg, color: C.teal, label: { glyph: '▣', label: 'SVG' }, type: 'image' },
  { kind: 'html', icon: ICON.html, color: C.peach, label: { glyph: '◎', label: 'HTML' }, type: 'html' },
  { kind: 'folder', icon: ICON.folder, color: C.overlay1, label: { glyph: '▸', label: 'Folder' }, type: 'code' },
  { kind: 'json', icon: ICON.json, color: C.yellow, label: FILE_LABEL, type: 'data' },
  { kind: 'toml', icon: ICON.toml, color: C.peach, label: FILE_LABEL, type: 'data' },
  { kind: 'csv', icon: ICON.csv, color: C.green, label: FILE_LABEL, type: 'data' },
  { kind: 'web', icon: ICON.web, color: C.peach, label: { glyph: '◎', label: 'Web page' }, type: 'html' },
  { kind: 'gh-pr', icon: ICON['gh-pr'], color: C.green, label: FILE_LABEL, type: 'html' },
  { kind: 'gh-issue', icon: ICON['gh-issue'], color: C.teal, label: FILE_LABEL, type: 'html' },
  { kind: 'gh-repo', icon: ICON['gh-repo'], color: C.overlay1, label: FILE_LABEL, type: 'html' },
  { kind: 'linear-issue', icon: ICON['linear-issue'], color: C.blue, label: FILE_LABEL, type: 'html' },
  { kind: 'linear-project', icon: ICON['linear-project'], color: C.mauve, label: FILE_LABEL, type: 'html' },
  { kind: 'slack-thread', icon: ICON['slack-thread'], color: C.yellow, label: FILE_LABEL, type: 'html' },
]

describe('kind metadata', () => {
  for (const row of ROWS) {
    test(`${row.kind} keeps its icon, colour, label and gallery type`, () => {
      expect(iconFor(row.kind)).toBe(row.icon)
      expect(colorFor(row.kind)).toBe(row.color)
      expect(kindLabel(row.kind)).toEqual(row.label)
      expect(typeOf(row.kind)).toBe(row.type)
    })
  }

  test('an unknown or missing kind falls back to the file defaults', () => {
    expect(iconFor('weird')).toBe(ICON.file)
    expect(iconFor(undefined)).toBe(ICON.file)
    expect(colorFor('weird')).toBe(C.overlay1)
    expect(colorFor(undefined)).toBe(C.overlay1)
    expect(kindLabel('weird')).toEqual(FILE_LABEL)
    expect(kindLabel(undefined)).toEqual(FILE_LABEL)
    expect(typeOf('weird')).toBe('code')
  })

  test('an unlisted remote kind still takes its source family type', () => {
    expect(typeOf('gh-other')).toBe('html')
    expect(typeOf('linear-other')).toBe('html')
    expect(typeOf('slack-other')).toBe('html')
  })
})
