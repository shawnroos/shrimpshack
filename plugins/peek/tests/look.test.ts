import { expect, test } from 'claude-code/testing'
import type { View } from '../types'
import { canGoLive } from '../hooks/pane/look'

const WEB: View = { href: 'https://example.com/page', title: 'Page', location: 'example.com' }
const CTX = { surface: 'terminal' as const, Image: (() => null) as never }

test('canGoLive is false for a web view whose record has not loaded, true once it has', () => {
  expect(canGoLive(CTX, WEB)).toBe(false)
  expect(canGoLive(CTX, { ...WEB, remote: { tier: 'api' } })).toBe(true)
})
