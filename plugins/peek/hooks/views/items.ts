import type { PropValue } from '../../types'

export type ItemSource = 'task-folder' | 'deliverable' | 'mirrored' | 'record'
export type Item = {
  id: string
  href: string
  type: string
  name: string
  props: Record<string, PropValue>
  source: ItemSource
  worktree?: string
  missing?: string[]
}
export type ItemDoc = { path: string; props?: Record<string, PropValue>; worktree?: string; mtimeMs?: number }
export type ItemRecord = { id: string; href: string; type: string; name?: string; props?: Record<string, PropValue> }

const textProp = (props: Record<string, PropValue>, key: string): string | undefined => {
  const value = props[key]
  return typeof value === 'string' && value.trim() ? value : undefined
}

const baseName = (path: string): string => (path.split('/').pop() ?? path).replace(/\.md$/i, '')

export function itemFromDoc(doc: ItemDoc, how: { type: string; source: Exclude<ItemSource, 'record'>; missing?: string[] }): Item {
  const props = doc.props ?? {}
  return {
    id: textProp(props, 'id') ?? doc.path,
    href: doc.path,
    type: how.type,
    name: textProp(props, 'name') ?? baseName(doc.path),
    props,
    source: how.source,
    ...(doc.worktree === undefined ? {} : { worktree: doc.worktree }),
    ...(how.missing === undefined ? {} : { missing: how.missing }),
  }
}

export function itemFromRecord(record: ItemRecord): Item {
  const props = record.props ?? {}
  return { id: record.id, href: record.href, type: record.type, name: record.name ?? textProp(props, 'name') ?? record.id, props, source: 'record' }
}
