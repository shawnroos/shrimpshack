import { describe, expect, test } from 'claude-code/testing'

import { describeAge, describeSize } from '../hooks/format'
import { kindLabel } from '../hooks/kinds'

test('size, age and kind labels read plainly', () => {
  expect(describeSize(12_700)).toBe('12.4 KB')
  expect(describeAge(0, 3 * 3600_000)).toBe('3h ago')
  expect(kindLabel('mermaid').label).toBe('Diagram')
})
