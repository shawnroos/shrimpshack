import { describe, expect, test } from 'claude-code/testing'

import * as lib from '../hooks/lib'
import { fileHref, fitMarkdown, imageBox, kindOf, linkify, parseHref, pathCandidates, resolvePath } from '../hooks/lib'

const always = (raw: string, line?: number) => fileHref(`/repo/${raw}`, line)

describe('pathCandidates', () => {
  test('finds bare paths and code-span paths, keeps line numbers out of the path', () => {
    const text = 'Edit `src/auth.ts:42`, then read docs/plan.md and ~/notes/a.png.'
    expect(pathCandidates(text)).toEqual(['src/auth.ts', 'docs/plan.md', '~/notes/a.png'])
  })

  test('skips fenced code, existing links and URLs', () => {
    const text = '```\nsrc/inside.ts\n```\n[x](docs/linked.md) see https://example.com/page.html'
    expect(pathCandidates(text)).toEqual([])
  })
})

describe('linkify', () => {
  test('wraps a bare path with its line in a file link', () => {
    expect(linkify('open src/auth.ts:42 now', always)).toBe('open [src/auth.ts:42](file:///repo/src/auth.ts#L42) now')
  })

  test('wraps a code span and keeps it as code', () => {
    expect(linkify('see `docs/plan.md`', always)).toBe('see [`docs/plan.md`](file:///repo/docs/plan.md)')
  })

  test('leaves a path alone when the resolver says it does not exist', () => {
    expect(linkify('see docs/missing.md', () => null)).toBe('see docs/missing.md')
  })
})

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

test('fitMarkdown closes a fence it cut through', () => {
  expect(fitMarkdown('```ts\n' + 'x'.repeat(50), 20)).toContain('\n```\n\n*… cut')
  expect(parseHref(fileHref('/a#b?c.md'))).toEqual({ path: '/a#b?c.md', line: undefined })
})

describe('rankRecent', () => {
  const recent = [
    fileHref('/repo/docs/plans/export-flow.mmd'),
    fileHref('/repo/docs/handoff.md'),
    fileHref('/repo/assets/logo.png'),
  ]

  test('a named diagram beats newer files', () => {
    const { rankRecent } = lib
    expect(rankRecent('show me the export diagram', recent)[0]?.href).toBe(recent[0])
  })

  test('a kind word alone picks that kind', () => {
    const { rankRecent } = lib
    expect(rankRecent('the image', recent)[0]?.href).toBe(recent[2])
  })

  test('"that doc" with no words falls to the newest and says it has no words', () => {
    const { rankRecent, hasMeaningfulWords } = lib
    expect(hasMeaningfulWords('open that doc')).toBe(false)
    expect(rankRecent('open that doc', recent)[0]?.href).toBe(recent[2])
  })
})

test('urlCandidates trims trailing punctuation', () => {
  const { urlCandidates, pushRecent } = lib
  expect(urlCandidates('see https://x.dev/a. and (https://y.dev/b)')).toEqual(['https://x.dev/a', 'https://y.dev/b'])
  expect(pushRecent(['a', 'b'], ['a', 'c'])).toEqual(['b', 'a', 'c'])
})

describe('mermaid fences', () => {
  const doc = '# Plan\n\n```mermaid\ngraph LR\nA --> B\n```\n\ntext\n\n```mermaid\nsequenceDiagram\nA->>B: hi\n```\n'

  test('finds each mermaid block source', () => {
    expect(lib.mermaidFences(doc)).toEqual(['graph LR\nA --> B', 'sequenceDiagram\nA->>B: hi'])
  })

  test('swaps drawn blocks and keeps a failed one as source', () => {
    const out = lib.swapMermaidFences(doc, ['[A]-->[B]', null])
    expect(out).toContain('```peek-diagram flowchart\n[A]-->[B]\n```')
    expect(out).toContain('```mermaid\nsequenceDiagram')
  })
})

describe('outline', () => {
  const doc = '# Title\nintro\n```\n# not a heading\n```\n## Part one\ntext\n### Detail\n## Part two\n'

  test('lists headings outside code fences, with levels', () => {
    expect(lib.outlineOf(doc).map(one => `${one.level}:${one.text}`)).toEqual(['1:Title', '2:Part one', '3:Detail', '2:Part two'])
  })

  test('fromSection starts at the chosen heading', () => {
    expect(lib.fromSection(doc, 3)).toBe('## Part two\n')
    expect(lib.fromSection(doc, 99)).toBe(doc)
  })
})

test('size, age and kind labels read plainly', () => {
  expect(lib.describeSize(12_700)).toBe('12.4 KB')
  expect(lib.describeAge(0, 3 * 3600_000)).toBe('3h ago')
  expect(lib.kindLabel('mermaid').label).toBe('Diagram')
})

test('rasterGradient packs three little-endian words per cell', () => {
  const base64 = lib.rasterGradient(4, 2)
  const bytes = Uint8Array.from(atob(base64), char => char.charCodeAt(0))
  expect(bytes.length).toBe(4 * 2 * 12)
  expect(new Uint32Array(bytes.buffer)[0]).toBe(0x2580)
})

describe('mentions', () => {
  test('a repeat mention moves to newest and counts up', () => {
    const once = lib.noteMentions([], ['a', 'b'], 1)
    const twice = lib.noteMentions(once, ['a'], 5)
    expect(twice).toEqual([
      { href: 'b', at: 1, count: 1 },
      { href: 'a', at: 5, count: 2 },
    ])
  })

  test('pageOf clamps the page and counts pages', () => {
    expect(lib.pageOf([1, 2, 3, 4, 5], 9, 2)).toEqual({ items: [5], page: 2, pages: 3 })
  })

  test('shortPath trims the working folder, then home', () => {
    expect(lib.shortPath('/w/docs/a.md', '/w', '/h')).toBe('docs/a.md')
    expect(lib.shortPath('/h/x.png', '/w', '/h')).toBe('~/x.png')
  })
})

describe('paginateMarkdown', () => {
  test('keeps every line, fits each page, and starts headings on a fresh page when they would sit at the bottom', () => {
    const doc = ['# Title', '', 'one two three', '', '## Next', '', 'para a', '', 'para b', '', 'para c'].join('\n')
    const pages = lib.paginateMarkdown(doc, 40, 5)
    expect(pages.join('\n').replace(/\n+/g, '\n')).toBe(doc.replace(/\n+/g, '\n'))
    expect(pages.length).toBeGreaterThan(1)
    expect(pages[1]?.startsWith('## Next')).toBe(true)
  })

  test('splits a fence taller than a page and reopens it on the next page', () => {
    const code = ['```rust', ...Array.from({ length: 12 }, (_, i) => `let x${i} = ${i};`), '```'].join('\n')
    const pages = lib.paginateMarkdown(code, 40, 6)
    expect(pages.length).toBeGreaterThan(1)
    for (const page of pages) {
      expect(page.startsWith('```')).toBe(true)
      expect((page.match(/```/g) ?? []).length % 2).toBe(0)
    }
  })
})

describe('tasks, images and diagrams in markdown', () => {
  const doc = ['# Todo', '- [ ] write it', '- [x] plan it', '```', '- [ ] not a task', '```', '![shot](img/a.png)'].join('\n')

  test('linkTasks links each task to its source line and counts them', () => {
    const out = lib.linkTasks(doc, 'file:///w/todo.md')
    expect(out.total).toBe(2)
    expect(out.done).toBe(1)
    expect(out.text).toContain('](file:///w/todo.md#task-2) write it')
    expect(out.text).toContain('](file:///w/todo.md#task-3) ~~plan it~~')
    expect(out.text).toContain('- [ ] not a task')
  })

  test('toggleTaskLine flips only the named line, and refuses a non-task', () => {
    expect(lib.toggleTaskLine(doc, 2)?.split('\n')[1]).toBe('- [x] write it')
    expect(lib.toggleTaskLine(doc, 3)?.split('\n')[2]).toBe('- [ ] plan it')
    expect(lib.toggleTaskLine(doc, 1)).toBeNull()
  })

  test('segmentsOf pulls standalone images out of the text', () => {
    expect(lib.segmentsOf(doc).map(one => one.kind)).toEqual(['heading', 'markdown', 'code', 'image'])
    expect(lib.segmentsOf(doc)[3]).toEqual({ kind: 'image', alt: 'shot', src: 'img/a.png' })
  })

  test('an image costs a block of rows when paging', () => {
    const pages = lib.paginateMarkdown(['para', '', '![a](a.png)', '', '![b](b.png)'].join('\n'), 40, 14)
    expect(pages.length).toBe(2)
  })

  test('a drawn diagram becomes a typed peek-diagram fence; one that cannot be drawn keeps its source', () => {
    expect(lib.swapMermaidFences('```mermaid\ngraph LR\nA-->B\n```', ['[A]->[B]'])).toBe('```peek-diagram flowchart\n[A]->[B]\n```')
    expect(lib.swapMermaidFences('```mermaid\npie\n```', [null])).toBe('```mermaid\npie\n```')
  })
})

describe('one scrollable page', () => {
  test('chunkMarkdown keeps every block and respects the cap', () => {
    const doc = Array.from({ length: 50 }, (_, i) => `## H${i}\n\n${'w '.repeat(100)}`).join('\n\n')
    const chunks = lib.chunkMarkdown(doc, 1000)
    expect(chunks.length).toBeGreaterThan(5)
    for (const chunk of chunks) expect(chunk.length).toBeLessThanOrEqual(1000)
    expect(chunks.join('\n\n')).toBe(doc)
  })

  test('estimateRows grows with wrapping and images', () => {
    expect(lib.estimateRows('a', 40)).toBe(2)
    expect(lib.estimateRows('x'.repeat(100), 40)).toBe(4)
    expect(lib.estimateRows('![a](a.png)', 40)).toBe(lib.IMAGE_ROWS + 1)
  })
})

describe('headings and quotes', () => {
  test('segmentsOf lifts headings and quote runs out of the text, but not inside fences', () => {
    const doc = ['## The **plan**', 'intro', '> first line', '> second `line`', 'after', '```', '# not a heading', '> not a quote', '```'].join('\n')
    const parts = lib.segmentsOf(doc)
    expect(parts.map(one => one.kind)).toEqual(['heading', 'markdown', 'quote', 'markdown', 'code'])
    expect(parts[0]).toEqual({ kind: 'heading', level: 2, text: 'The plan' })
    expect(parts[2]).toEqual({ kind: 'quote', text: 'first line\nsecond `line`' })
    expect(parts[4]).toEqual({ kind: 'code', lang: '', info: '', text: '# not a heading\n> not a quote' })
  })
})

test('segmentsOf lifts fenced code with its language and info', () => {
  const doc = 'before\n```rust\nfn main() {}\n```\n```peek-diagram flowchart\n[A]\n```\nafter'
  expect(lib.segmentsOf(doc)).toEqual([
    { kind: 'markdown', text: 'before' },
    { kind: 'code', lang: 'rust', info: '', text: 'fn main() {}' },
    { kind: 'code', lang: 'peek-diagram', info: 'flowchart', text: '[A]' },
    { kind: 'markdown', text: 'after' },
  ])
})

test('segmentsOf groups consecutive linked tasks into one block with depth and state', () => {
  const linked = lib.linkTasks('# T\n- [ ] one\n  - [x] two\n- [ ] three\n\nafter', 'file:///w/t.md').text
  const parts = lib.segmentsOf(linked)
  expect(parts.map(one => one.kind)).toEqual(['heading', 'tasks', 'markdown'])
  const block = parts[1]
  expect(block?.kind === 'tasks' && block.items).toEqual([
    { href: 'file:///w/t.md', line: 2, isDone: false, text: 'one', depth: 0 },
    { href: 'file:///w/t.md', line: 3, isDone: true, text: 'two', depth: 1 },
    { href: 'file:///w/t.md', line: 4, isDone: false, text: 'three', depth: 0 },
  ])
})
