import type { RenderChildren } from 'claude-code'

import { nest } from '../../views/select'
import type { TreeNode } from '../../views/select'
import type { Item } from '../../views/items'
import { ItemLine } from './row'
import type { BlockDraw, BlockEnv } from './row'

// One line per shown node: branch lines from the depth, a fold mark on a parent with children here, and the
// parent's full child count even when some children draw in another section.
export function treeLines(env: BlockEnv, roots: readonly TreeNode[], width = env.width): RenderChildren[] {
  const lines: RenderChildren[] = []
  const walk = (nodes: readonly TreeNode[], depth: number, guides: string) => {
    nodes.forEach((node, index) => {
      const isLast = index === nodes.length - 1
      const isFolded = env.folded.has(node.item.id)
      const fold = node.children.length ? (isFolded ? '▸ ' : '▾ ') : ''
      const branch = depth === 0 ? '' : `${guides}${isLast ? '└─ ' : '├─ '}`
      lines.push(ItemLine(env, node.item, { branch, fold, count: node.childCount, ...(node.parentName ? { parentName: node.parentName } : {}) }, width))
      if (!isFolded) walk(node.children, depth + 1, depth === 0 ? '' : `${guides}${isLast ? '   ' : '│  '}`)
    })
  }
  walk(roots, 0, '')
  return lines
}

export function drawTree(env: BlockEnv, items: readonly Item[]): BlockDraw {
  const { Box } = env.ctx
  const lines = treeLines(env, nest(items, env.nestProp).roots)
  return {
    node: (
      <Box key={env.key} flexDirection="column" width={env.width}>
        {lines}
      </Box>
    ),
    rows: lines.length,
  }
}
