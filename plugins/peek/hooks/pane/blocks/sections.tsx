import type { RenderChildren } from 'claude-code'

import { sectioned } from '../../views/select'
import type { Item } from '../../views/items'
import type { TreeNode } from '../../views/select'
import { STATUS_VALUES } from '../../tasks/status-words'
import { SectionRule } from '../widgets'
import { DimLine, countNodes } from './row'
import type { BlockDraw, BlockEnv } from './row'
import { treeLines } from './tree'

export type Shelf = { key: string; label: string; roots: readonly TreeNode[] }

function splitOf(options: Record<string, string>): { split: string; values: readonly string[] } {
  const split = options.split || 'status'
  const values = options.values ? options.values.split(',').map(one => one.trim()).filter(Boolean) : split === 'status' ? STATUS_VALUES : []
  return { split, values }
}

export function shelvesOf(env: BlockEnv, items: readonly Item[], options: Record<string, string>): Shelf[] {
  return sectioned(items, { ...splitOf(options), parentProp: env.nestProp }).sections.map(section => ({ key: section.key, label: section.key.toUpperCase(), roots: section.roots }))
}

// Each shelf is a rule line over its rows; a shelf with nothing in it draws a dim "none" row.
export function drawShelves(env: BlockEnv, shelves: readonly Shelf[]): BlockDraw {
  const { Box } = env.ctx
  const lines: RenderChildren[] = []
  for (const shelf of shelves) {
    lines.push(SectionRule(env.ctx, shelf.label, String(countNodes(shelf.roots)), env.width, `${env.key}-${shelf.key}-rule`))
    const rows = treeLines(env, shelf.roots)
    lines.push(...(rows.length ? rows : [DimLine(env.ctx, `${env.key}-${shelf.key}-none`, 'none', env.width)]))
  }
  return {
    node: (
      <Box key={env.key} flexDirection="column" width={env.width}>
        {lines}
      </Box>
    ),
    rows: lines.length,
  }
}

export const drawSections = (env: BlockEnv, items: readonly Item[], options: Record<string, string>): BlockDraw => drawShelves(env, shelvesOf(env, items, options))
