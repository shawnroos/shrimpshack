import { describe, expect, test } from 'claude-code/testing'

import { imageBox } from '../hooks/measure'
import { fileHref, kindOf, parseHref, resolvePath } from '../hooks/paths'

test('parseHref round-trips a path with spaces and a line', () => {
  expect(parseHref(fileHref('/a b/c.ts', 7))).toEqual({ path: '/a b/c.ts', line: 7 })
  expect(parseHref('https://x.dev')).toBeNull()
})

test('resolvePath handles ~, .. and relative', () => {
  expect(resolvePath('~/x.md', '/w', '/Users/s')).toBe('/Users/s/x.md')
  expect(resolvePath('../y/z.md', '/w/v', '/h')).toBe('/w/y/z.md')
})

test('kindOf and imageBox', () => {
  expect(kindOf('a/B.SVG')).toBe('svg')
  expect(kindOf('d.mmd')).toBe('mermaid')
  expect(imageBox(1000, 1000, 80, 20)).toEqual({ columns: 42, rows: 20 })
})
