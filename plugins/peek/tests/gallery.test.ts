import { describe, expect, test } from 'claude-code/testing'

import { classifyBlocks, filterRole, gridColumns, hasMeaningfulWords, nextOf, noteMentions, parseStatLines, rankRecent, selectEntries, toggleStar } from '../hooks/gallery'
import { fileHref, shortPath } from '../hooks/paths'

describe('rankRecent', () => {
  const recent = [
    fileHref('/repo/docs/plans/export-flow.mmd'),
    fileHref('/repo/docs/handoff.md'),
    fileHref('/repo/assets/logo.png'),
  ]

  test('a named diagram beats newer files', () => {
    expect(rankRecent('show me the export diagram', recent)[0]?.href).toBe(recent[0])
  })

  test('a kind word alone picks that kind', () => {
    expect(rankRecent('the image', recent)[0]?.href).toBe(recent[2])
  })

  test('"that doc" with no words falls to the newest and says it has no words', () => {
    expect(hasMeaningfulWords('open that doc')).toBe(false)
    expect(rankRecent('open that doc', recent)[0]?.href).toBe(recent[2])
  })
})

describe('mentions', () => {
  test('a repeat mention moves to newest and counts up', () => {
    const once = noteMentions([], ['a', 'b'], 1)
    const twice = noteMentions(once, ['a'], 5)
    expect(twice).toEqual([
      { href: 'b', at: 1, count: 1, isArtifact: false },
      { href: 'a', at: 5, count: 2, isArtifact: false },
    ])
  })

  test('shortPath trims the working folder, then home', () => {
    expect(shortPath('/w/docs/a.md', '/w', '/h')).toBe('docs/a.md')
    expect(shortPath('/h/x.png', '/w', '/h')).toBe('~/x.png')
  })
})

describe('scopes and the gallery', () => {
  const out = ['1700000000 1200 docs/plan.md', '1700000500 90 src/a.rs', '1700000100 5000 shots/x.png', '1700000200 10 node_modules.bin', '1700000300 70 flow.mmd'].join('\n')
  const entries = parseStatLines(out, '/w', 'tui')

  test('parseStatLines keeps viewable files with their folder, kind, time and size', () => {
    expect(entries.map(one => one.name)).toEqual(['plan.md', 'a.rs', 'x.png', 'flow.mmd'])
    expect(entries[0]).toMatchObject({ path: '/w/docs/plan.md', folder: 'docs', kind: 'markdown', mtimeMs: 1700000000000, size: 1200, worktree: 'tui' })
  })

  test('selectEntries filters by type and words, then sorts', () => {
    expect(selectEntries(entries, 'image', '', 'recent').map(one => one.name)).toEqual(['x.png'])
    expect(selectEntries(entries, 'diagram', '', 'recent').map(one => one.name)).toEqual(['flow.mmd'])
    expect(selectEntries(entries, 'all', 'src', 'recent').map(one => one.name)).toEqual(['a.rs'])
    expect(selectEntries(entries, 'all', '', 'recent').map(one => one.name)).toEqual(['a.rs', 'flow.mmd', 'x.png', 'plan.md'])
    expect(selectEntries(entries, 'all', '', 'size').map(one => one.name)).toEqual(['x.png', 'plan.md', 'a.rs', 'flow.mmd'])
    expect(selectEntries(entries, 'all', '', 'name').map(one => one.name)).toEqual(['a.rs', 'flow.mmd', 'plan.md', 'x.png'])
  })

  test('nextOf cycles and gridColumns fits whole cards', () => {
    expect(nextOf(['a', 'b', 'c'], 'c')).toBe('a')
    expect(gridColumns(80)).toBe(3)
    expect(gridColumns(79)).toBe(2)
    expect(gridColumns(20)).toBe(1)
    expect(gridColumns(107)).toBe(4)
  })
})

describe('artifacts and touched files', () => {
  test('noteMentions marks artifacts and never demotes one', () => {
    const touched = noteMentions([], ['a', 'b'], 1)
    expect(touched.map(one => one.isArtifact)).toEqual([false, false])
    const shown = noteMentions(touched, ['a'], 2, 200, true)
    const readAgain = noteMentions(shown, ['a'], 3)
    expect(readAgain.find(one => one.href === 'a')?.isArtifact).toBe(true)
    expect(readAgain.find(one => one.href === 'b')?.isArtifact).toBe(false)
  })

  test('filterRole keeps all, artifacts or touched', () => {
    const base = { path: '', name: '', folder: '', kind: 'text', mtimeMs: 0, size: 0, mentions: 0, mentionedAt: 0 }
    const entries = [
      { ...base, href: 'a', role: 'artifact' as const },
      { ...base, href: 'b', role: 'touched' as const },
      { ...base, href: 'c' },
    ]
    expect(filterRole(entries, 'all').map(one => one.href)).toEqual(['a', 'b', 'c'])
    expect(filterRole(entries, 'artifacts').map(one => one.href)).toEqual(['a'])
    expect(filterRole(entries, 'touched').map(one => one.href)).toEqual(['b'])
  })
})

test('classifyBlocks splits reply text and Write from files other tools only worked on', () => {
  expect(
    classifyBlocks([
      { type: 'text', text: 'See out/report.md' },
      { type: 'tool_use', name: 'Write', input: { file_path: '/w/new.md' } },
      { type: 'tool_use', name: 'Read', input: { file_path: '/w/a.rs' } },
      { type: 'tool_use', name: 'Edit', input: { file_path: '/w/b.rs' } },
      { type: 'tool_use', name: 'Grep', input: { path: '/w/src', pattern: 'x' } },
    ]),
  ).toEqual({ texts: ['See out/report.md'], created: ['/w/new.md'], touched: ['/w/a.rs', '/w/b.rs', '/w/src'] })
})

describe('stars', () => {
  test('toggleStar flips, or sets a wanted state, without duplicates', () => {
    expect(toggleStar([], 'a')).toEqual(['a'])
    expect(toggleStar(['a'], 'a')).toEqual([])
    expect(toggleStar(['a'], 'a', true)).toEqual(['a'])
    expect(toggleStar([], 'a', false)).toEqual([])
  })
})
