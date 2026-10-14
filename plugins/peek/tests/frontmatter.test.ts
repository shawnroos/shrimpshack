import { describe, expect, test } from 'claude-code/testing'

import { readFrontmatter } from '../hooks/frontmatter'

const kinds = (text: string) => readFrontmatter(text).problems.map(one => one.kind)

describe('readFrontmatter', () => {
  test('reads scalars, quoted strings, block and one-line lists, and a two-level map', () => {
    const text = [
      '---',
      'title: Plan the launch',
      'count: 3',
      'ratio: -1.5',
      'isTask: true',
      'isDraft: false',
      'owner: null',
      'empty:',
      'quoted: "a: b, # not a comment"',
      "single: 'it''s'",
      'tags: [one, "two, three", 4]',
      'steps:',
      '  - first',
      '  - "second"',
      'props:',
      '  status: { kind: choice, values: [todo, done], required: true }',
      '  due: date',
      '---',
      '# Body',
    ].join('\n')
    const read = readFrontmatter(text)
    expect(read.problems).toEqual([])
    expect(read.props).toEqual({
      title: 'Plan the launch',
      count: 3,
      ratio: -1.5,
      isTask: true,
      isDraft: false,
      owner: null,
      empty: null,
      quoted: 'a: b, # not a comment',
      single: "it's",
      tags: ['one', 'two, three', 4],
      steps: ['first', 'second'],
      props: { status: { kind: 'choice', values: ['todo', 'done'], required: true }, due: 'date' },
    })
    expect(read.body).toBe('# Body')
    expect(read.bodyStartLine).toBe(19)
  })

  test('the definition sketch from the plan reads into its props', () => {
    const sketch = [
      '---',
      'type: task',
      'match: { folder: .peek/tasks }          # or { prop: isTask, equals: true }',
      'props:',
      '  status: { kind: choice, values: [todo, doing, done, cancelled], required: true }',
      '  due:    { kind: date }',
      'requires_when: { isTask: true, all: true }',
      'layout_default: { page: tree, group: list }',
      '---',
      '# {{name}}',
      '',
      '```peek-tree parent={{id}}',
      '```',
    ].join('\n')
    const read = readFrontmatter(sketch)
    expect(read.problems).toEqual([])
    expect(read.props).toEqual({
      type: 'task',
      match: { folder: '.peek/tasks' },
      props: {
        status: { kind: 'choice', values: ['todo', 'doing', 'done', 'cancelled'], required: true },
        due: { kind: 'date' },
      },
      requires_when: { isTask: true, all: true },
      layout_default: { page: 'tree', group: 'list' },
    })
    expect(read.body).toBe('# {{name}}\n\n```peek-tree parent={{id}}\n```')
    expect(read.bodyStartLine).toBe(10)
  })

  test('a doc with no frontmatter has no props and an unchanged body', () => {
    const text = '# Title\n\n---\n\nkey: value\n'
    const read = readFrontmatter(text)
    expect(read.props).toBeUndefined()
    expect('props' in read).toBe(false)
    expect(read.body).toBe(text)
    expect(read.problems).toEqual([])
    expect(read.bodyStartLine).toBe(1)
  })

  test('an unterminated block is a named problem and the whole text stays the body', () => {
    const text = '---\ntitle: x\n# Body\n'
    const read = readFrontmatter(text)
    expect(read.problems.map(one => one.kind)).toEqual(['unterminated'])
    expect(read.body).toBe(text)
    expect(read.bodyStartLine).toBe(1)
  })

  test('a tab-indented line is a named problem', () => {
    expect(kinds('---\nprops:\n\tstatus: done\n---\n')).toContain('tab')
  })

  test('a three-level block map is a named problem', () => {
    const text = '---\nprops:\n  status:\n    kind: choice\n---\nbody'
    const read = readFrontmatter(text)
    expect(read.problems.map(one => one.kind)).toEqual(['too-deep'])
    expect(read.problems[0]?.line).toBe(4)
    expect(read.body).toBe('body')
  })

  test('a container nested inside a one-line map, a one-line list or a block list item is a named problem', () => {
    expect(kinds('---\nprops: { a: { b: c } }\n---\n')).toEqual(['too-deep'])
    expect(kinds('---\nsteps:\n  - [a, b]\n---\n')).toEqual(['too-deep'])
    expect(kinds('---\ntags: [a, [b]]\n---\n')).toEqual(['too-deep'])
  })

  test('other YAML features are named problems', () => {
    expect(kinds('---\nbody: |\n  text\n---\n')).toEqual(['unsupported'])
    expect(kinds('---\nref: *anchor\n---\n')).toEqual(['unsupported'])
    expect(kinds('---\n- top level item\n---\n')).toEqual(['unsupported'])
    expect(kinds('---\na: 1\na: 2\n---\n')).toEqual(['duplicate'])
    expect(kinds('---\nlist: [a, b\n---\n')).toEqual(['unsupported'])
  })

  test('problems are capped', () => {
    const lines = Array.from({ length: 80 }, (_, i) => `k${i}: &x`)
    expect(readFrontmatter(`---\n${lines.join('\n')}\n---\n`).problems.length).toBe(50)
  })

  test('control and bidi characters are removed from values', () => {
    const text = '---\ntitle: "safe\u202Etxt\u0007"\nplain: a\u2066b\u0085c\ntags: [x\u200Fy]\n---\n'
    expect(readFrontmatter(text).props).toEqual({ title: 'safetxt', plain: 'abc', tags: ['xy'] })
  })

  test('no value in props is undefined', () => {
    const read = readFrontmatter('---\na:\nb: { c: }\n---\n')
    expect(read.props).toEqual({ a: null, b: { c: null } })
    expect(JSON.stringify(read.props)).toBe('{"a":null,"b":{"c":null}}')
  })
})
