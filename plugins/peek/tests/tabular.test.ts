import { describe, expect, test } from 'claude-code/testing'

import { typeOf } from '../hooks/kinds'
import { kindOf } from '../hooks/paths'
import { columnWidths, fitCell, parseDelimited, prettyJson, tomlSections } from '../hooks/tabular'

describe('data files', () => {
  test('kindOf and typeOf know json, toml and csv', () => {
    expect(['a.json', 'b.toml', 'c.csv', 'd.tsv'].map(kindOf)).toEqual(['json', 'toml', 'csv', 'csv'])
    expect(typeOf('json')).toBe('data')
  })

  test('parseDelimited handles quotes, embedded commas, newlines and CRLF', () => {
    const text = 'name,note\r\n"Lee, A","said ""hi""\nthen left"\r\nB,plain\n'
    expect(parseDelimited(text)).toEqual([['name', 'note'], ['Lee, A', 'said "hi"\nthen left'], ['B', 'plain']])
    expect(parseDelimited('a\tb\n1\t2', '\t')).toEqual([['a', 'b'], ['1', '2']])
  })

  test('columnWidths keeps natural widths that fit and squeezes the widest when they do not', () => {
    expect(columnWidths([['ab', 'c'], ['a', 'cdef']], 40)).toEqual([2, 4])
    const squeezed = columnWidths([['id', 'x'.repeat(80)]], 30)
    expect(squeezed[0]).toBe(2)
    expect(squeezed.reduce((a, b) => a + b, 0) + 2).toBeLessThanOrEqual(30)
  })

  test('fitCell pads short text and cuts long text with an ellipsis', () => {
    expect(fitCell('ab', 4)).toBe('ab  ')
    expect(fitCell('abcdef', 4)).toBe('abc…')
  })

  test('prettyJson re-indents and summarises, and reports a parse error', () => {
    const out = prettyJson('{"a":1,"b":[1,2]}')
    expect('text' in out && out.text).toBe('{\n  "a": 1,\n  "b": [\n    1,\n    2\n  ]\n}')
    expect('summary' in out && out.summary).toBe('object · 2 keys')
    expect('error' in prettyJson('{oops')).toBe(true)
  })

  test('tomlSections counts tables and array tables', () => {
    expect(tomlSections('a = 1\n[server]\nport = 1\n[[workers]]\n# [not]\n')).toBe(2)
  })
})
