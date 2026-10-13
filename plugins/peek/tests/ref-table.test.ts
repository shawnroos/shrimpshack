import { describe, expect, test } from 'claude-code/testing'

import { itemKey, keyOf, parseRef } from '../hooks/refs'
import type { RefContext } from '../hooks/refs'

// Recorded from 0755bdc: input, context, kind, canonical address, itemKey of the raw input, itemKey of the address.
const TABLE: [string, RefContext | undefined, string | null, string | null, string, string | null][] = [
  ['https://github.com/o/r/pull/12', undefined, 'gh-pr', 'https://github.com/o/r/pull/12', 'https://github.com/o/r#12', 'https://github.com/o/r#12'],
  ['https://github.com/o/r/issues/12', undefined, 'gh-issue', 'https://github.com/o/r/issues/12', 'https://github.com/o/r#12', 'https://github.com/o/r#12'],
  ['https://github.com/o/r/pull/12/files#discussion_r1', undefined, 'gh-pr', 'https://github.com/o/r/pull/12', 'https://github.com/o/r/pull/12/files#discussion_r1', 'https://github.com/o/r#12'],
  ['http://www.github.com/o/r/issues/7?foo=1', undefined, 'gh-issue', 'https://github.com/o/r/issues/7', 'http://www.github.com/o/r/issues/7?foo=1', 'https://github.com/o/r#7'],
  ['https://github.com/o/r', undefined, 'gh-repo', 'https://github.com/o/r', 'https://github.com/o/r', 'https://github.com/o/r'],
  ['https://github.com/o/r/', undefined, 'gh-repo', 'https://github.com/o/r', 'https://github.com/o/r/', 'https://github.com/o/r'],
  ['https://github.com/o/r.git', undefined, 'gh-repo', 'https://github.com/o/r', 'https://github.com/o/r.git', 'https://github.com/o/r'],
  ['https://github.com/o/r/blob/main/a.ts', undefined, 'web', 'https://github.com/o/r/blob/main/a.ts', 'https://github.com/o/r/blob/main/a.ts', 'https://github.com/o/r/blob/main/a.ts'],
  ['https://github.com/settings/profile', undefined, 'web', 'https://github.com/settings/profile', 'https://github.com/settings/profile', 'https://github.com/settings/profile'],
  ['https://github.com/', undefined, 'web', 'https://github.com/', 'https://github.com/', 'https://github.com/'],
  ['https://github.com/acme/widgets/pull/42/files#r1', undefined, 'gh-pr', 'https://github.com/acme/widgets/pull/42', 'https://github.com/acme/widgets/pull/42/files#r1', 'https://github.com/acme/widgets#42'],
  ['https://github.com/o/r#42', undefined, 'gh-repo', 'https://github.com/o/r', 'https://github.com/o/r#42', 'https://github.com/o/r'],
  ['https://github.com/user-attachments/assets/0b1c2d3e-aaaa-bbbb-cccc-1234567890ab', undefined, 'web', 'https://github.com/user-attachments/assets/0b1c2d3e-aaaa-bbbb-cccc-1234567890ab', 'https://github.com/user-attachments/assets/0b1c2d3e-aaaa-bbbb-cccc-1234567890ab', 'https://github.com/user-attachments/assets/0b1c2d3e-aaaa-bbbb-cccc-1234567890ab'],
  ['https://github.com/acme/widgets/blob/main/docs/guide.md', undefined, 'web', 'https://github.com/acme/widgets/blob/main/docs/guide.md', 'https://github.com/acme/widgets/blob/main/docs/guide.md', 'https://github.com/acme/widgets/blob/main/docs/guide.md'],
  ['o/r#12', undefined, 'gh-number', 'https://github.com/o/r/issues/12', 'o/r#12', 'https://github.com/o/r#12'],
  ['acme/widgets#42', undefined, 'gh-number', 'https://github.com/acme/widgets/issues/42', 'acme/widgets#42', 'https://github.com/acme/widgets#42'],
  ['#12', {'repo': 'o/r'}, 'gh-number', 'https://github.com/o/r/issues/12', '#12', 'https://github.com/o/r#12'],
  ['#12', undefined, null, null, '#12', null],
  ['settings/x#3', undefined, null, null, 'settings/x#3', null],
  ['  o/r#12  ', undefined, 'gh-number', 'https://github.com/o/r/issues/12', '  o/r#12  ', 'https://github.com/o/r#12'],
  ['https://linear.app/acme/issue/WEB-2757', undefined, 'linear-issue', 'https://linear.app/acme/issue/WEB-2757', 'https://linear.app/acme/issue/WEB-2757', 'https://linear.app/acme/issue/WEB-2757'],
  ['https://linear.app/acme/issue/web-2757/fix-the-thing', undefined, 'linear-issue', 'https://linear.app/acme/issue/WEB-2757', 'https://linear.app/acme/issue/web-2757/fix-the-thing', 'https://linear.app/acme/issue/WEB-2757'],
  ['https://linear.app/acme/issue/WEB-2757/remove-logo', undefined, 'linear-issue', 'https://linear.app/acme/issue/WEB-2757', 'https://linear.app/acme/issue/WEB-2757/remove-logo', 'https://linear.app/acme/issue/WEB-2757'],
  ['https://linear.app/acme/project/peek-remote-1a2b3c4d5e6f', undefined, 'linear-project', 'https://linear.app/acme/project/peek-remote-1a2b3c4d5e6f', 'https://linear.app/acme/project/peek-remote-1a2b3c4d5e6f', 'https://linear.app/acme/project/peek-remote-1a2b3c4d5e6f'],
  ['https://linear.app/acme/project/peek-remote-1a2b3c4d5e6f/overview', undefined, 'linear-project', 'https://linear.app/acme/project/peek-remote-1a2b3c4d5e6f', 'https://linear.app/acme/project/peek-remote-1a2b3c4d5e6f/overview', 'https://linear.app/acme/project/peek-remote-1a2b3c4d5e6f'],
  ['https://linear.app/acme/project/p-1', undefined, 'linear-project', 'https://linear.app/acme/project/p-1', 'https://linear.app/acme/project/p-1', 'https://linear.app/acme/project/p-1'],
  ['https://linear.app/other/issue/ZZQ-9', undefined, 'linear-issue', 'https://linear.app/other/issue/ZZQ-9', 'https://linear.app/other/issue/ZZQ-9', 'https://linear.app/other/issue/ZZQ-9'],
  ['https://linear.app/acme/issue/ABCDEFGHIJK-1', undefined, 'web', 'https://linear.app/acme/issue/ABCDEFGHIJK-1', 'https://linear.app/acme/issue/ABCDEFGHIJK-1', 'https://linear.app/acme/issue/ABCDEFGHIJK-1'],
  ['https://linear.app/acme/issue/ABCDEFGHIJ-1', undefined, 'linear-issue', 'https://linear.app/acme/issue/ABCDEFGHIJ-1', 'https://linear.app/acme/issue/ABCDEFGHIJ-1', 'https://linear.app/acme/issue/ABCDEFGHIJ-1'],
  ['WEB-2757', {'teamKeys': ['WEB'], 'workspace': 'acme'}, 'linear-issue', 'https://linear.app/acme/issue/WEB-2757', 'WEB-2757', 'https://linear.app/acme/issue/WEB-2757'],
  ['web-2757', {'teamKeys': ['WEB'], 'workspace': 'acme'}, 'linear-issue', 'https://linear.app/acme/issue/WEB-2757', 'web-2757', 'https://linear.app/acme/issue/WEB-2757'],
  ['WEB-2757', {'teamKeys': ['WEB']}, null, null, 'WEB-2757', null],
  ['WEB-2757', undefined, null, null, 'WEB-2757', null],
  ['UTF-8', {'teamKeys': ['WEB'], 'workspace': 'acme'}, null, null, 'UTF-8', null],
  ['https://acme.slack.com/archives/C0123ABCD/p1791759796763609', undefined, 'slack-thread', 'https://acme.slack.com/archives/C0123ABCD/p1791759796763609', 'https://acme.slack.com/archives/C0123ABCD/p1791759796763609', 'https://acme.slack.com/archives/C0123ABCD/p1791759796763609'],
  ['https://acme.slack.com/archives/C0123ABCD/p1791761128357239?thread_ts=1791759796.763609&cid=C0123ABCD', undefined, 'slack-thread', 'https://acme.slack.com/archives/C0123ABCD/p1791759796763609', 'https://acme.slack.com/archives/C0123ABCD/p1791759796763609', 'https://acme.slack.com/archives/C0123ABCD/p1791759796763609'],
  ['https://acme.slack.com/archives/C0123ABCD/p1791761128357239?thread_ts=1791759796.763609', undefined, 'slack-thread', 'https://acme.slack.com/archives/C0123ABCD/p1791759796763609', 'https://acme.slack.com/archives/C0123ABCD/p1791759796763609', 'https://acme.slack.com/archives/C0123ABCD/p1791759796763609'],
  ['https://acme.slack.com/archives/C0123ABCD/p1791761128357239', undefined, 'slack-thread', 'https://acme.slack.com/archives/C0123ABCD/p1791761128357239', 'https://acme.slack.com/archives/C0123ABCD/p1791761128357239', 'https://acme.slack.com/archives/C0123ABCD/p1791761128357239'],
  ['https://acme.slack.com/archives/C0123ABCD/p1791761128357239?thread_ts=junk', undefined, 'slack-thread', 'https://acme.slack.com/archives/C0123ABCD/p1791761128357239', 'https://acme.slack.com/archives/C0123ABCD/p1791761128357239', 'https://acme.slack.com/archives/C0123ABCD/p1791761128357239'],
  ['https://acme.slack.com/archives/C0123ABCD', undefined, 'web', 'https://acme.slack.com/archives/C0123ABCD', 'https://acme.slack.com/archives/C0123ABCD', 'https://acme.slack.com/archives/C0123ABCD'],
  ['https://acme.slack.com/archives/C0123ABCD/p123', undefined, 'web', 'https://acme.slack.com/archives/C0123ABCD/p123', 'https://acme.slack.com/archives/C0123ABCD/p123', 'https://acme.slack.com/archives/C0123ABCD/p123'],
  ['https://slack.com/archives/C0123ABCD/p1791759796763609', undefined, 'web', 'https://slack.com/archives/C0123ABCD/p1791759796763609', 'https://slack.com/archives/C0123ABCD/p1791759796763609', 'https://slack.com/archives/C0123ABCD/p1791759796763609'],
  ['https://github.com/settings/issues/5', undefined, 'web', 'https://github.com/settings/issues/5', 'https://github.com/settings/issues/5', 'https://github.com/settings/issues/5'],
  ['https://github.com/o%20x/r/pull/5', undefined, 'web', 'https://github.com/o%20x/r/pull/5', 'https://github.com/o%20x/r#5', 'https://github.com/o%20x/r#5'],
  ['https://example.com', undefined, 'web', 'https://example.com/', 'https://example.com', 'https://example.com/'],
  ['https://example.com/a?b=1#top', undefined, 'web', 'https://example.com/a?b=1', 'https://example.com/a?b=1#top', 'https://example.com/a?b=1'],
  ['https://example.com/a#top', undefined, 'web', 'https://example.com/a', 'https://example.com/a#top', 'https://example.com/a'],
  ['https://x.dev', undefined, 'web', 'https://x.dev/', 'https://x.dev', 'https://x.dev/'],
  ['http://127.0.0.1/notes.md', undefined, 'web', 'http://127.0.0.1/notes.md', 'http://127.0.0.1/notes.md', 'http://127.0.0.1/notes.md'],
  ['/a/b.md', undefined, null, null, '/a/b.md', null],
  ['docs/plan.md', undefined, null, null, 'docs/plan.md', null],
  ['notes/todo.md', undefined, null, null, 'notes/todo.md', null],
  ['mailto:a@b.c', undefined, null, null, 'mailto:a@b.c', null],
  ['file:///a/b.md', undefined, null, null, 'file:///a/b.md', null],
  ['', undefined, null, null, '', null],
]

describe('ref identity table', () => {
  for (const [text, context, kind, address, rawKey, addressKey] of TABLE) {
    test(`${JSON.stringify(text)} ${context ? JSON.stringify(context) : ''}`, () => {
      const ref = parseRef(text, context)
      expect(ref?.kind ?? null).toBe(kind)
      expect(ref?.address ?? null).toBe(address)
      expect(itemKey(text)).toBe(rawKey)
      expect(ref ? itemKey(ref.address) : null).toBe(addressKey)
      expect(ref ? keyOf(ref) : null).toBe(addressKey)
    })
  }
})
