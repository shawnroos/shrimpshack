import { describe, expect, test } from 'claude-code/testing'

import { parseThreadText } from '../hooks/parsers/slack-transcript'
import { THREAD_TEXT } from './fixtures/slack/mcp'

describe('parseThreadText', () => {
  test('reads the parent and every reply with author, ts and text', () => {
    const thread = parseThreadText(THREAD_TEXT)
    expect(thread?.parent).toMatchObject({ author: 'Ada Lovelace', ts: '1791759796.763609' })
    expect(thread?.parent.text).toContain('_Widgets 0.82 published_')
    expect(thread?.replies.map(one => [one.author, one.ts])).toEqual([
      ['Grace Hopper', '1791761128.357239'],
      ['Ada Lovelace', '1791763200.000100'],
    ])
    expect(thread?.replies[1]?.text).toBe('Thanks, see <https://example.com/doc>.\nReactions: +1 (1)')
  })

  test('text that is not a thread transcript is not a thread', () => {
    expect(parseThreadText('hello')).toBeNull()
  })
})
