import { describe, expect, test } from 'claude-code/testing'

import { fileHref, linkify } from '../hooks/lib'
import { itemKey, parseRef, refHref } from '../hooks/refs'

const none = () => null
const ctx = { teamKeys: ['WEB'], workspace: 'acme', repo: 'o/r' }

describe('parseRef canonical addresses', () => {
  test('a pull request URL drops /files and the comment anchor', () => {
    expect(parseRef('https://github.com/o/r/pull/12/files#discussion_r1')).toEqual({
      kind: 'gh-pr',
      address: 'https://github.com/o/r/pull/12',
      owner: 'o',
      repo: 'r',
      number: 12,
    })
  })

  test('an issue URL drops its query string', () => {
    expect(parseRef('http://www.github.com/o/r/issues/7?foo=1')?.address).toBe('https://github.com/o/r/issues/7')
  })

  test('a repo URL is a repo, with or without .git', () => {
    expect(parseRef('https://github.com/o/r.git')).toEqual({ kind: 'gh-repo', address: 'https://github.com/o/r', owner: 'o', repo: 'r' })
    expect(parseRef('https://github.com/o/r/')?.kind).toBe('gh-repo')
  })

  test('other GitHub pages and reserved owners stay web pages', () => {
    expect(parseRef('https://github.com/o/r/blob/main/a.ts')?.kind).toBe('web')
    expect(parseRef('https://github.com/settings/profile')?.kind).toBe('web')
  })

  test('a Linear issue URL drops its slug and uppercases the identifier', () => {
    expect(parseRef('https://linear.app/acme/issue/web-2757/fix-the-thing')).toEqual({
      kind: 'linear-issue',
      address: 'https://linear.app/acme/issue/WEB-2757',
      workspace: 'acme',
      key: 'WEB-2757',
    })
  })

  test('a Linear project URL keeps its slug-id and drops sub-pages', () => {
    expect(parseRef('https://linear.app/acme/project/peek-remote-1a2b3c4d5e6f/overview')).toEqual({
      kind: 'linear-project',
      address: 'https://linear.app/acme/project/peek-remote-1a2b3c4d5e6f',
      workspace: 'acme',
      slug: 'peek-remote-1a2b3c4d5e6f',
    })
  })

  test('a web URL keeps its query string and drops only the fragment', () => {
    expect(parseRef('https://example.com/a?b=1#top')).toEqual({ kind: 'web', address: 'https://example.com/a?b=1' })
  })

  test('o/r#12 is a GitHub number on o/r, kind not yet known', () => {
    expect(parseRef('o/r#12')).toEqual({ kind: 'gh-number', address: 'https://github.com/o/r/issues/12', owner: 'o', repo: 'r', number: 12 })
  })

  test('#12 needs repo context', () => {
    expect(parseRef('#12', { repo: 'o/r' })?.address).toBe('https://github.com/o/r/issues/12')
    expect(parseRef('#12')).toBeNull()
  })

  test('KEY-N needs the team key and the workspace', () => {
    expect(parseRef('WEB-2757', ctx)?.address).toBe('https://linear.app/acme/issue/WEB-2757')
    expect(parseRef('UTF-8', ctx)).toBeNull()
    expect(parseRef('WEB-2757', { teamKeys: [], workspace: 'acme' })).toBeNull()
    expect(parseRef('WEB-2757', { teamKeys: ['WEB'] })).toBeNull()
  })

  test('a lowercase Linear ID typed into /peek resolves to the uppercase address', () => {
    expect(parseRef('ai-711', { teamKeys: ['AI'], workspace: 'acme' })?.address).toBe('https://linear.app/acme/issue/AI-711')
    expect(parseRef('utf-8', { teamKeys: ['AI'], workspace: 'acme' })).toBeNull()
  })

  test('file links, paths and junk are not remote', () => {
    expect(parseRef(fileHref('/a/b.md'))).toBeNull()
    expect(parseRef('docs/plan.md')).toBeNull()
    expect(parseRef('mailto:a@b.c')).toBeNull()
  })

  test('a pull request and an issue URL for one number share an item key', () => {
    expect(itemKey('https://github.com/o/r/pull/12')).toBe(itemKey('https://github.com/o/r/issues/12'))
    expect(itemKey('https://example.com/a')).toBe('https://example.com/a')
  })
})

describe('linkify with references', () => {
  test('covers AE2: only the real team key links', () => {
    expect(linkify('UTF-8 SHA-256 WEB-2757', none, ctx)).toBe('UTF-8 SHA-256 [WEB-2757](https://linear.app/acme/issue/WEB-2757)')
  })

  test('no team keys loaded links no Linear IDs', () => {
    expect(linkify('see WEB-2757', none, { teamKeys: [], workspace: 'acme' })).toBe('see WEB-2757')
  })

  test('owner/repo#N and #N link as GitHub numbers', () => {
    expect(linkify('fixed in a/b#3 and #12.', none, ctx)).toBe(
      'fixed in [a/b#3](https://github.com/a/b/issues/3) and [#12](https://github.com/o/r/issues/12).',
    )
  })

  test('#N with no repo context stays text', () => {
    expect(linkify('see #12', none, { teamKeys: [] })).toBe('see #12')
  })

  test('references in fenced code stay text; a code span holding only a reference links', () => {
    expect(linkify('```\no/r#12\n```', none, ctx)).toBe('```\no/r#12\n```')
    expect(linkify('see `o/r#12`', none, ctx)).toBe('see [`o/r#12`](https://github.com/o/r/issues/12)')
  })

  test('existing links, headings, URLs and HTML entities are left alone', () => {
    const text = '[text](https://github.com/o/r/pull/12) https://x.dev/#12 &#123; ## Heading'
    expect(linkify(text, none, ctx)).toBe(text)
  })

  test('a path link and a reference on one line both link', () => {
    const always = (raw: string) => fileHref(`/repo/${raw}`)
    expect(linkify('edit a.md for WEB-1', always, ctx)).toBe('edit [a.md](file:///repo/a.md) for [WEB-1](https://linear.app/acme/issue/WEB-1)')
  })

  test('refHref returns null for text that is not a whole reference', () => {
    expect(refHref('o/r#12 x', ctx)).toBeNull()
    expect(refHref('o/r#12', ctx)).toBe('https://github.com/o/r/issues/12')
  })
})
