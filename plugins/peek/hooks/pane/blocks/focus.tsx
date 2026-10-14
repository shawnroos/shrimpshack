import type { Item } from '../../views/items'
import { focus, sectioned } from '../../views/select'
import type { BlockDraw, BlockEnv } from './row'
import { drawShelves } from './sections'

const BUCKETS = ['now', 'next', 'later'] as const
const BUCKET_PROP = '\u0000focus'

// The buckets come from focus(); sectioned() then nests each bucket by parent like any other split, so a child
// whose parent sits in another bucket draws with the parent named.
export function drawFocus(env: BlockEnv, items: readonly Item[]): BlockDraw {
  const buckets = focus(items)
  const tagged = BUCKETS.flatMap(bucket => buckets[bucket].map(item => ({ ...item, props: { ...item.props, [BUCKET_PROP]: bucket } })))
  const { sections } = sectioned(tagged, { split: BUCKET_PROP, values: BUCKETS, parentProp: env.nestProp })
  return drawShelves(env, BUCKETS.map(bucket => ({ key: bucket, label: bucket.toUpperCase(), roots: sections.find(section => section.key === bucket)?.roots ?? [] })))
}
