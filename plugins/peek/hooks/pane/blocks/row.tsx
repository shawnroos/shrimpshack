import type { RenderChildren } from 'claude-code'

import { fitRow } from '../../measure'
import type { RowPart } from '../../measure'
import type { Layout } from '../../views/definition'
import type { Item } from '../../views/items'
import type { TreeNode } from '../../views/select'
import type { DrawContext } from '../types'
import { noteRow } from './common'

// The prop the agent-list mirror sets on an open task whose session ended without anyone adopting it.
export const SESSION_ENDED_PROP = 'session_ended'

export type BlockNav = { href: string; key: string }

export type BlockEnv = {
  ctx: DrawContext
  key: string
  width: number
  place: string
  layout: Layout
  nestProp: string
  folded: ReadonlySet<string>
  cursor: number
  navStart: number
  nav: BlockNav[]
  open: (href: string) => void
}

export type BlockDraw = { node: RenderChildren; rows: number }

export type RowShape = { branch: string; fold: string; count: number; parentName?: string }

const STATUS_GLYPH: Record<string, string> = { todo: '○', doing: '◐', done: '●', cancelled: '⊘' }
const PARENT_ROOM = 12

const textProp = (item: Item, key: string) => {
  const value = item.props[key]
  return typeof value === 'string' && value.trim() ? value.trim() : ''
}

export const statusOf = (item: Item) => textProp(item, 'status')

export const isEnded = (item: Item) => item.props[SESSION_ENDED_PROP] === true

export function glyphOf(ctx: DrawContext, item: Item): { glyph: string; color: string } {
  const { C } = ctx
  const status = statusOf(item)
  const color = status === 'doing' ? C.yellow : status === 'done' ? C.green : status === 'cancelled' ? C.overlay0 : C.overlay1
  return { glyph: STATUS_GLYPH[status] ?? '·', color }
}

// In drop order: the due date gives way first, then the creator, then "session ended"; the flag never does.
export function rightParts(item: Item): RowPart[] {
  const ended = isEnded(item) ? [{ text: 'session ended' }] : []
  const creator = textProp(item, 'creator')
  const due = textProp(item, 'due')
  return [...ended, ...(creator ? [{ text: creator }] : []), ...(due ? [{ text: due }] : []), ...(item.missing?.length ? [{ text: '⚑', keep: true }] : [])]
}

// Claims the next keyboard row of the page for `item`: its scroll key, and whether the cursor sits on it.
export function claimRow(env: BlockEnv, item: Item, hasChildren: boolean) {
  const index = env.navStart + env.nav.length
  const key = `${env.key}-row-${env.nav.length}`
  env.nav.push({ href: item.href, key })
  noteRow(key, { place: env.place, id: item.id, layout: env.layout, hasChildren })
  return { key, buttonKey: `item-${index}`, isSelected: env.cursor === index }
}

export function ItemLine(env: BlockEnv, item: Item, shape: RowShape, width = env.width): RenderChildren {
  const { Box, Text, Button, C } = env.ctx
  const row = claimRow(env, item, shape.fold !== '')
  const { glyph, color } = glyphOf(env.ctx, item)
  const parent = shape.parentName ? `${shape.parentName.length > PARENT_ROOM ? `${shape.parentName.slice(0, PARENT_ROOM - 1)}…` : shape.parentName} › ` : ''
  const count = shape.count ? ` (${shape.count})` : ''
  const lead = shape.branch.length + shape.fold.length + glyph.length + 1 + parent.length + count.length
  const fitted = fitRow(item.name, rightParts(item), width - lead)
  const isEndedPart = (text: string) => text === 'session ended'
  return (
    <Box key={row.key} flexDirection="row" height={1} width={width} overflow="hidden" backgroundColor={row.isSelected ? C.surface0 : undefined}>
      {shape.branch && <Text color={C.surface1}>{shape.branch}</Text>}
      {shape.fold && <Text color={C.accent}>{shape.fold}</Text>}
      <Text color={color}>{`${glyph} `}</Text>
      {parent && <Text color={C.overlay0} dimColor>{parent}</Text>}
      <Button key={row.buttonKey} label={fitted.name} plain {...(row.isSelected ? { autoFocus: true } : {})} onPress={() => env.open(item.href)} />
      {count && <Text color={C.overlay0}>{count}</Text>}
      <Box flexGrow={1} />
      {fitted.right.map(text => (
        <Text key={`${row.key}-${text}`} color={text === '⚑' ? C.red : C.overlay0} {...(isEndedPart(text) ? { dimColor: true } : {})}>{`  ${text}`}</Text>
      ))}
    </Box>
  )
}

export function DimLine(ctx: DrawContext, key: string, text: string, width: number): RenderChildren {
  const { Text, C } = ctx
  return (
    <Text key={key} color={C.overlay0} dimColor wrap="truncate-end">{text.length > width ? `${text.slice(0, Math.max(1, width - 1))}…` : text}</Text>
  )
}

export const countNodes = (nodes: readonly TreeNode[]): number => nodes.reduce((sum, node) => sum + 1 + countNodes(node.children), 0)
