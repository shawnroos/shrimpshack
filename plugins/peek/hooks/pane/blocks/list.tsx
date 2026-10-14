import { order } from '../../views/select'
import type { Item } from '../../views/items'
import { ItemLine } from './row'
import type { BlockDraw, BlockEnv } from './row'

export function drawList(env: BlockEnv, items: readonly Item[]): BlockDraw {
  const { Box } = env.ctx
  const lines = order(items).items.map(item => ItemLine(env, item, { branch: '', fold: '', count: 0 }))
  return {
    node: (
      <Box key={env.key} flexDirection="column" width={env.width}>
        {lines}
      </Box>
    ),
    rows: lines.length,
  }
}
