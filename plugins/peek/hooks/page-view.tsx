import type { BoxProps, ButtonProps, ElementConstructor, TextProps } from 'claude-code'

import { columnWidths, fitCell } from './lib'
import { PAGE_CAPS } from './page'
import type { Action, Block, CardItem, Detail, ListItem, Page, TableBlock } from './page'
import { ICON } from './theme'

export const EMPTY_PAGE = 'This page has no sections.'
export const EMPTY_SECTION = 'Nothing in this section.'
// mediaBlock keys its play Button `media-play-${index}`, and markdownBlocks counts its own pictures from 0 in the
// same writer set; a markdown block (100,000 characters at most) holds far fewer than 10,000, so the ranges never meet.
export const PAGE_MEDIA_BASE = 10_000
const NOTICE_TEXT = 60
const LABEL_MAX = 24

export type PageNavItem = { href: string; key: string; line: number; col: number }
export type PageNavSink = { nav: PageNavItem[]; keys: string[]; starts: number[]; cursor: number; line: number; selected: number }
export type PageItemLook = { href: string; isStarred: boolean; favicon: string | undefined; icon: string; name: string; folder: string; detail: string }
export type PageKey = { key: string; label: string; hotkey: string; onPress: () => void; menu?: string }
export type PagePartSink = { drawnParts: unknown[]; note: (rows: number, heading?: string) => void }
export type PageBlockWriters = {
  sectionRule: (key: string, label: string, right?: string) => void
  fitsPane: (png: string) => boolean
  mediaBlock: (index: number, alt: string, url: string, heading: string) => void
  markdownBlocks: (key: string, text: string, heading: string, indent?: number) => void
}
export type PageItemBuilder = <T>(sink: PageNavSink, lookOf: (one: T) => PageItemLook) => (items: readonly T[], prefix: string) => unknown[]
export type PageColors = { accent: string; text: string; subtext0: string; overlay0: string; overlay1: string; surface0: string; surface1: string }
export type PageWriters = {
  elements: { Box: ElementConstructor<BoxProps>; Text: ElementConstructor<TextProps>; Button: ElementConstructor<ButtonProps> }
  colors: PageColors
  blocks: (sink: PagePartSink) => PageBlockWriters
  cards: PageItemBuilder
  rows: PageItemBuilder
  isStarred: (href: string) => boolean
  picture?: (url: string) => string | undefined
  pick: (index: number) => void
  open: (href: string) => void
  copy: (text: string) => void
  notice: (text: string) => void
}
export type DrawnPage = { parts: unknown[]; rows: number[]; headings: string[]; nav: PageNavItem[]; keys: PageKey[] }

const isEmpty = (block: Block) => {
  switch (block.type) {
    case 'markdown': {
      return block.text.trim() === ''
    }
    case 'table':
    case 'fields': {
      return block.rows.length === 0
    }
    default: {
      return block.items.length === 0
    }
  }
}

function placeOf(href: string | undefined): string {
  if (!href) return ''
  if (href.startsWith('/')) return href
  try {
    return new URL(href).host
  } catch {
    return href
  }
}

const iconOf = (href: string | undefined) => (!href ? ICON.text : href.startsWith('/') ? ICON.file : ICON.web)
const shorten = (text: string) => (text.length > NOTICE_TEXT ? `${text.slice(0, NOTICE_TEXT - 1)}…` : text)

export function drawPage(writers: PageWriters, page: Page, view: { width: number; selected: number }): DrawnPage {
  const { Box, Text, Button } = writers.elements
  const C = writers.colors
  const { width, selected } = view
  const parts: unknown[] = []
  const rows: number[] = []
  const headings: string[] = []
  const note = (count: number, heading = '') => {
    while (rows.length < parts.length) {
      rows.push(count)
      headings.push(heading)
    }
  }
  const blocks = writers.blocks({ drawnParts: parts, note })
  const sink: PageNavSink = { nav: [], keys: [], starts: [], cursor: 0, line: 0, selected }

  const lookOf = (one: CardItem | ListItem): PageItemLook => {
    const png = 'image' in one && one.image ? writers.picture?.(one.image) : undefined
    return {
      href: one.href ?? '',
      isStarred: one.href ? writers.isStarred(one.href) : false,
      favicon: png && blocks.fitsPane(png) ? png : undefined,
      icon: iconOf(one.href),
      name: one.title,
      folder: placeOf(one.href),
      detail: one.meta ?? '',
    }
  }
  const cardGrid = writers.cards(sink, lookOf)
  const rowList = writers.rows(sink, lookOf)

  const fieldRows = (key: string, list: readonly Detail[], heading: string) => {
    const labelWidth = Math.min(LABEL_MAX, Math.max(0, ...list.map(one => one.label.length))) + 2
    parts.push(
      <Box key={key} flexDirection="column" width={width}>
        {list.map((one, i) => (
          <Text key={`${key}-${i}`} wrap="truncate-end">
            <Text color={C.overlay0}>{fitCell(one.label, labelWidth - 2).trimEnd().padEnd(labelWidth)}</Text>
            <Text color={C.text}>{one.value}</Text>
          </Text>
        ))}
      </Box>,
    )
    note(list.length, heading)
  }

  const items = (key: string, drawn: unknown[], before: number, heading: string) => {
    parts.push(
      <Box key={key} flexDirection="column" width={width}>
        {drawn as never}
      </Box>,
    )
    note(Math.max(1, sink.cursor - before), heading)
  }

  const table = (key: string, block: TableBlock, heading: string) => {
    const room = Math.max(1, width - 2)
    const widths = columnWidths([block.columns, ...block.rows.map(one => one.cells)], room)
    const line = (cells: readonly string[]) => widths.map((w, c) => fitCell(cells[c] ?? '', w)).join('  ')
    parts.push(
      <Box key={key} flexDirection="column" width={width}>
        <Text key={`${key}-head`} color={C.accent} bold wrap="truncate-end">{`  ${line(block.columns)}`}</Text>
        <Text key={`${key}-rule`} color={C.surface1} wrap="truncate-end">{`  ${widths.map(w => '─'.repeat(w)).join('  ')}`}</Text>
        {block.rows.map((row, r) => {
          const index = sink.nav.length
          const rowKey = `${key}-row-${r}`
          sink.nav.push({ href: row.href ?? '', key: rowKey, line: sink.line++, col: 0 })
          const isSelected = index === selected
          return (
            <Box key={rowKey} flexDirection="row" height={1} width={width} backgroundColor={isSelected ? C.surface0 : undefined} hover={{ backgroundColor: C.surface0 }}>
              <Button key={`item-${index}`} label={isSelected ? '›' : ' '} plain autoFocus={isSelected ? true : undefined} onPress={() => writers.pick(index)} />
              <Text color={isSelected ? C.accent : C.text} wrap="truncate-end">{` ${line(row.cells)}`}</Text>
            </Box>
          )
        })}
      </Box>,
    )
    note(block.rows.length + 2, heading)
  }

  parts.push(
    <Text key="page-title" color={C.text} bold>
      {page.title}
    </Text>,
  )
  note(Math.max(1, Math.ceil(page.title.length / Math.max(1, width))), page.title)
  if (page.details?.length) fieldRows('page-details', page.details, 'Details')

  if (page.sections.length === 0) {
    parts.push(
      <Text key="page-empty" color={C.overlay0}>
        {EMPTY_PAGE}
      </Text>,
    )
    note(1)
  }

  let mediaIndex = PAGE_MEDIA_BASE
  for (const [i, { heading = '', block }] of page.sections.entries()) {
    const key = `section-${i}`
    if (heading) blocks.sectionRule(`${key}-rule`, heading)
    if (isEmpty(block)) {
      parts.push(
        <Text key={`${key}-empty`} color={C.overlay0}>
          {EMPTY_SECTION}
        </Text>,
      )
      note(1, heading)
      continue
    }
    switch (block.type) {
      case 'markdown': {
        blocks.markdownBlocks(`${key}-md`, block.text, heading)
        break
      }
      case 'media': {
        for (const one of block.items) blocks.mediaBlock(mediaIndex++, one.alt ?? '', one.url, heading)
        break
      }
      case 'table': {
        table(key, block, heading)
        break
      }
      case 'cards': {
        const before = sink.cursor
        items(`${key}-items`, cardGrid(block.items, key), before, heading)
        break
      }
      case 'list': {
        const before = sink.cursor
        items(`${key}-items`, rowList(block.items, key), before, heading)
        break
      }
      case 'fields': {
        fieldRows(key, block.rows, heading)
        break
      }
    }
  }

  const keys = (page.actions ?? []).slice(0, PAGE_CAPS.actions).map((action: Action, i): PageKey => ({
    key: `action-${i}`,
    label: action.label,
    hotkey: String(i + 1),
    menu: action.label,
    onPress: () => {
      if ('open' in action) {
        writers.open(action.open)
        return
      }
      writers.copy(action.copy)
      writers.notice(`Copied ${shorten(action.copy)}`)
    },
  }))

  return { parts, rows, headings, nav: sink.nav, keys }
}
