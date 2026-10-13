import { describe, expect, test } from 'claude-code/testing'

import { fitMarkdown, linkTasks, linkify, mermaidFences, outlineOf, pathCandidates, segmentsOf, swapMermaidFences, toggleTaskLine, urlCandidates } from '../hooks/markdown'
import { paginateMarkdown } from '../hooks/measure'
import { fileHref, parseHref } from '../hooks/paths'

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

test('fitMarkdown closes a fence it cut through', () => {
  expect(fitMarkdown('```ts\n' + 'x'.repeat(50), 20)).toContain('\n```\n\n*… cut')
  expect(parseHref(fileHref('/a#b?c.md'))).toEqual({ path: '/a#b?c.md', line: undefined })
})

test('urlCandidates trims trailing punctuation', () => {
  expect(urlCandidates('see https://x.dev/a. and (https://y.dev/b)')).toEqual(['https://x.dev/a', 'https://y.dev/b'])
})

describe('mermaid fences', () => {
  const doc = '# Plan\n\n```mermaid\ngraph LR\nA --> B\n```\n\ntext\n\n```mermaid\nsequenceDiagram\nA->>B: hi\n```\n'

  test('finds each mermaid block source', () => {
    expect(mermaidFences(doc)).toEqual(['graph LR\nA --> B', 'sequenceDiagram\nA->>B: hi'])
  })

  test('swaps drawn blocks and keeps a failed one as source', () => {
    const out = swapMermaidFences(doc, ['[A]-->[B]', null])
    expect(out).toContain('```peek-diagram flowchart\n[A]-->[B]\n```')
    expect(out).toContain('```mermaid\nsequenceDiagram')
  })
})

describe('outline', () => {
  const doc = '# Title\nintro\n```\n# not a heading\n```\n## Part one\ntext\n### Detail\n## Part two\n'

  test('lists headings outside code fences, with levels', () => {
    expect(outlineOf(doc).map(one => `${one.level}:${one.text}`)).toEqual(['1:Title', '2:Part one', '3:Detail', '2:Part two'])
  })
})

describe('tasks, images and diagrams in markdown', () => {
  const doc = ['# Todo', '- [ ] write it', '- [x] plan it', '```', '- [ ] not a task', '```', '![shot](img/a.png)'].join('\n')

  test('linkTasks links each task to its source line and counts them', () => {
    const out = linkTasks(doc, 'file:///w/todo.md')
    expect(out.total).toBe(2)
    expect(out.done).toBe(1)
    expect(out.text).toContain('](file:///w/todo.md#task-2) write it')
    expect(out.text).toContain('](file:///w/todo.md#task-3) ~~plan it~~')
    expect(out.text).toContain('- [ ] not a task')
  })

  test('toggleTaskLine flips only the named line, and refuses a non-task', () => {
    expect(toggleTaskLine(doc, 2)?.split('\n')[1]).toBe('- [x] write it')
    expect(toggleTaskLine(doc, 3)?.split('\n')[2]).toBe('- [ ] plan it')
    expect(toggleTaskLine(doc, 1)).toBeNull()
  })

  test('segmentsOf pulls standalone images out of the text', () => {
    expect(segmentsOf(doc).map(one => one.kind)).toEqual(['heading', 'markdown', 'code', 'image'])
    expect(segmentsOf(doc)[3]).toEqual({ kind: 'image', alt: 'shot', src: 'img/a.png' })
  })

  test('an image costs a block of rows when paging', () => {
    const pages = paginateMarkdown(['para', '', '![a](a.png)', '', '![b](b.png)'].join('\n'), 40, 14)
    expect(pages.length).toBe(2)
  })

  test('a drawn diagram becomes a typed peek-diagram fence; one that cannot be drawn keeps its source', () => {
    expect(swapMermaidFences('```mermaid\ngraph LR\nA-->B\n```', ['[A]->[B]'])).toBe('```peek-diagram flowchart\n[A]->[B]\n```')
    expect(swapMermaidFences('```mermaid\npie\n```', [null])).toBe('```mermaid\npie\n```')
  })
})

describe('headings and quotes', () => {
  test('segmentsOf lifts headings and quote runs out of the text, but not inside fences', () => {
    const doc = ['## The **plan**', 'intro', '> first line', '> second `line`', 'after', '```', '# not a heading', '> not a quote', '```'].join('\n')
    const parts = segmentsOf(doc)
    expect(parts.map(one => one.kind)).toEqual(['heading', 'markdown', 'quote', 'markdown', 'code'])
    expect(parts[0]).toEqual({ kind: 'heading', level: 2, text: 'The plan' })
    expect(parts[2]).toEqual({ kind: 'quote', text: 'first line\nsecond `line`' })
    expect(parts[4]).toEqual({ kind: 'code', lang: '', info: '', text: '# not a heading\n> not a quote' })
  })
})

test('segmentsOf lifts fenced code with its language and info', () => {
  const doc = 'before\n```rust\nfn main() {}\n```\n```peek-diagram flowchart\n[A]\n```\nafter'
  expect(segmentsOf(doc)).toEqual([
    { kind: 'markdown', text: 'before' },
    { kind: 'code', lang: 'rust', info: '', text: 'fn main() {}' },
    { kind: 'code', lang: 'peek-diagram', info: 'flowchart', text: '[A]' },
    { kind: 'markdown', text: 'after' },
  ])
})

test('segmentsOf groups consecutive linked tasks into one block with depth and state', () => {
  const linked = linkTasks('# T\n- [ ] one\n  - [x] two\n- [ ] three\n\nafter', 'file:///w/t.md').text
  const parts = segmentsOf(linked)
  expect(parts.map(one => one.kind)).toEqual(['heading', 'tasks', 'markdown'])
  const block = parts[1]
  expect(block?.kind === 'tasks' && block.items).toEqual([
    { href: 'file:///w/t.md', line: 2, isDone: false, text: 'one', depth: 0 },
    { href: 'file:///w/t.md', line: 3, isDone: true, text: 'two', depth: 1 },
    { href: 'file:///w/t.md', line: 4, isDone: false, text: 'three', depth: 0 },
  ])
})

describe('tables', () => {
  test('segmentsOf lifts a pipe table with its alignment, cells cleaned of inline marks', () => {
    const doc = ['intro', '| Name | Count | Note |', '|:-----|------:|:----:|', '| **a** | 1 | x \\| y |', '| `b` | 22 |', 'after'].join('\n')
    const parts = segmentsOf(doc)
    expect(parts.map(one => one.kind)).toEqual(['markdown', 'table', 'markdown'])
    expect(parts[1]).toEqual({
      kind: 'table',
      header: ['Name', 'Count', 'Note'],
      align: ['left', 'right', 'center'],
      rows: [['a', '1', 'x | y'], ['b', '22', '']],
    })
  })

  test('a pipe line without a delimiter row stays prose, and a table in a fence stays code', () => {
    expect(segmentsOf('a | b\nc | d').map(one => one.kind)).toEqual(['markdown'])
    expect(segmentsOf('```\n| a | b |\n|---|---|\n```').map(one => one.kind)).toEqual(['code'])
  })

  test('a table without outer pipes still parses, and a blank line ends it', () => {
    const parts = segmentsOf('a | b\n--- | ---\n1 | 2\n\nafter')
    expect(parts.map(one => one.kind)).toEqual(['table', 'markdown'])
    expect(parts[0]?.kind === 'table' && parts[0].rows).toEqual([['1', '2']])
  })
})
