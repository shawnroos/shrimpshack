import { describe, expect, test } from 'claude-code/testing'

import { IMAGE_ROWS, chunkMarkdown, estimateRows, fitName, paginateMarkdown, rasterGradient, wrapLines } from '../hooks/measure'

test('rasterGradient packs three little-endian words per cell', () => {
  const base64 = rasterGradient(4, 2)
  const bytes = Uint8Array.from(atob(base64), char => char.charCodeAt(0))
  expect(bytes.length).toBe(4 * 2 * 12)
  expect(new Uint32Array(bytes.buffer)[0]).toBe(0x2580)
})

describe('paginateMarkdown', () => {
  test('keeps every line, fits each page, and starts headings on a fresh page when they would sit at the bottom', () => {
    const doc = ['# Title', '', 'one two three', '', '## Next', '', 'para a', '', 'para b', '', 'para c'].join('\n')
    const pages = paginateMarkdown(doc, 40, 5)
    expect(pages.join('\n').replace(/\n+/g, '\n')).toBe(doc.replace(/\n+/g, '\n'))
    expect(pages.length).toBeGreaterThan(1)
    expect(pages[1]?.startsWith('## Next')).toBe(true)
  })

  test('splits a fence taller than a page and reopens it on the next page', () => {
    const code = ['```rust', ...Array.from({ length: 12 }, (_, i) => `let x${i} = ${i};`), '```'].join('\n')
    const pages = paginateMarkdown(code, 40, 6)
    expect(pages.length).toBeGreaterThan(1)
    for (const page of pages) {
      expect(page.startsWith('```')).toBe(true)
      expect((page.match(/```/g) ?? []).length % 2).toBe(0)
    }
  })
})

describe('one scrollable page', () => {
  test('chunkMarkdown keeps every block and respects the cap', () => {
    const doc = Array.from({ length: 50 }, (_, i) => `## H${i}\n\n${'w '.repeat(100)}`).join('\n\n')
    const chunks = chunkMarkdown(doc, 1000)
    expect(chunks.length).toBeGreaterThan(5)
    for (const chunk of chunks) expect(chunk.length).toBeLessThanOrEqual(1000)
    expect(chunks.join('\n\n')).toBe(doc)
  })

  test('estimateRows grows with wrapping and images', () => {
    expect(estimateRows('a', 40)).toBe(2)
    expect(estimateRows('x'.repeat(100), 40)).toBe(4)
    expect(estimateRows('![a](a.png)', 40)).toBe(IMAGE_ROWS + 1)
  })
})

test('fitName keeps short names and shortens long ones but keeps the extension', () => {
  expect(fitName('plan.md', 20)).toBe('plan.md')
  expect(fitName('synthesis-and-presentation.md', 16)).toBe('synthesis-an….md')
  expect(fitName('synthesis-and-presentation.md', 16).length).toBe(16)
  expect(fitName('averyveryverylongnamewithoutdot', 10)).toBe('averyvery…')
})

describe('wrapLines', () => {
  test('wraps on spaces, keeps paragraph breaks, and caps with an ellipsis on the last kept line', () => {
    expect(wrapLines('one two three four', 9, 5)).toEqual(['one two', 'three', 'four'])
    expect(wrapLines('first\nsecond', 20, 5)).toEqual(['first', 'second'])
    expect(wrapLines('a b c d e f', 3, 2)).toEqual(['a b', 'c…'])
    expect(wrapLines('abcdefghij', 4, 5)).toEqual(['abcd', 'efgh', 'ij'])
    expect(wrapLines('', 10, 3)).toEqual([])
  })
})
