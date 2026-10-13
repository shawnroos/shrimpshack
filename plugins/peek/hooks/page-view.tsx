import type { BoxProps, ButtonProps, ClientProps, ElementConstructor, TextProps } from 'claude-code'

import { clip, columnWidths, fitCell } from './lib'
import { PAGE_CAPS, itemsOf } from './page'
import type { RecipeReview, ReviewRefusal } from '../types'
import type { Action, CardItem, Detail, ListItem, Page, TableBlock } from './page'
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
  elements: { Box: ElementConstructor<BoxProps>; Text: ElementConstructor<TextProps>; Button: ElementConstructor<ButtonProps>; Client?: ElementConstructor<ClientProps> }
  colors: PageColors
  blocks: (sink: PagePartSink) => PageBlockWriters
  cards: PageItemBuilder
  rows: PageItemBuilder
  isStarred: (href: string) => boolean
  link?: (href: string) => string
  picture?: (url: string) => string | undefined
  pick: (index: number) => void
  open: (href: string) => void
  copy: (text: string) => void
  notice: (text: string) => void
}
export type DrawnPage = { parts: unknown[]; rows: number[]; headings: string[]; nav: PageNavItem[]; keys: PageKey[] }

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

export function drawPage(writers: PageWriters, page: Page, view: { width: number; selected: number }): DrawnPage {
  const { Box, Text, Button, Client } = writers.elements
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

  const linkOf = (href: string | undefined) => (href ? (writers.link?.(href) ?? href) : '')
  const lookOf = (one: CardItem | ListItem): PageItemLook => {
    const png = 'image' in one && one.image ? writers.picture?.(one.image) : undefined
    const href = linkOf(one.href)
    return {
      href,
      isStarred: href ? writers.isStarred(href) : false,
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
    const hrefs = block.rows.map(row => linkOf(row.href))
    parts.push(
      <Box key={key} flexDirection="column" width={width}>
        {Client && (
          <Box position="absolute" top={2} left={0} width={width} height={block.rows.length}>
            <Client
              key={`hover-${key}`}
              module="./hover-layer.tsx"
              props={{ kind: 'rows', width, height: block.rows.length, starX: 0, starY: 0, items: hrefs.map(href => ({ href, isStarred: href ? writers.isStarred(href) : false })) }}
              width={width}
              height={block.rows.length}
            />
          </Box>
        )}
        <Text key={`${key}-head`} color={C.accent} bold wrap="truncate-end">{`  ${line(block.columns)}`}</Text>
        <Text key={`${key}-rule`} color={C.surface1} wrap="truncate-end">{`  ${widths.map(w => '─'.repeat(w)).join('  ')}`}</Text>
        {block.rows.map((row, r) => {
          const index = sink.nav.length
          const rowKey = `${key}-row-${r}`
          sink.nav.push({ href: hrefs[r] ?? '', key: rowKey, line: sink.line++, col: 0 })
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
    if (itemsOf(block) === 0) {
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
      writers.notice(`Copied ${clip(action.copy, NOTICE_TEXT)}`)
    },
  }))

  return { parts, rows, headings, nav: sink.nav, keys }
}

export type ReviewColors = PageColors & { red: string; yellow: string }
export type DrawnReview = { parts: unknown[]; rows: number[]; headings: string[] }

const REVIEW_HEADING = 'Approve'
const FILE_LINES_PER_TEXT = 200

const rowsOf = (lines: readonly string[], width: number) => lines.reduce((sum, line) => sum + Math.max(1, Math.ceil(line.length / Math.max(1, width))), 0)

function refusalText(refusal: ReviewRefusal): string {
  if (refusal.kind === 'changed') return "Changed since preview: the recipe's files are not the ones this page shows. Preview again to read them."
  if (refusal.kind === 'overlap') return `Not approved: its links overlap approved recipe "${refusal.id}". Change one recipe's match so only one claims a link.`
  return `Not approved: ${refusal.message}`
}

// Approve has no hotkey and no keybinding action, and sits in no footer or menu: only a press on the Button itself,
// which the plugin API cannot raise, records an approval.
export function drawApproval(
  elements: { Box: ElementConstructor<BoxProps>; Text: ElementConstructor<TextProps>; Button: ElementConstructor<ButtonProps> },
  C: ReviewColors,
  review: RecipeReview,
  view: { width: number },
  on: { approve: () => void; previewAgain: () => void; toggleFiles: () => void },
): DrawnReview {
  const { Box, Text, Button } = elements
  const { width } = view
  const parts: unknown[] = []
  const rows: number[] = []
  const headings: string[] = []
  const add = (part: unknown, count: number) => {
    parts.push(part)
    rows.push(count)
    headings.push(REVIEW_HEADING)
  }

  const facts: Detail[] = [
    { label: 'Runs', value: review.runs },
    { label: 'Matches', value: review.match.join(', ') },
    { label: 'Overrides', value: review.overrides.length ? review.overrides.join(', ') : 'none' },
    { label: 'Refresh', value: review.refreshMinutes > 0 ? `every ${review.refreshMinutes} minutes while on screen` : 'only when opened or refreshed' },
    { label: 'Env', value: review.env.length ? review.env.join(', ') : 'none' },
  ]
  const factLines = facts.map(one => `${one.label}: ${one.value}`)
  add(
    <Box key="review-facts" flexDirection="column" width={width}>
      <Text color={C.yellow} bold>Draft recipe: not approved</Text>
      <Text color={C.subtext0}>Show files to read what it runs. Approve sends it live for every link it matches; b leaves it a draft.</Text>
      {factLines.map((line, i) => (
        <Text key={`review-fact-${i}`} color={C.text}>{line}</Text>
      ))}
    </Box>,
    2 + rowsOf(factLines, width),
  )

  const alerts = [...(review.overlap ? [`Overlaps approved recipe "${review.overlap}": Approve will refuse until one match changes`] : []), ...review.warnings]
  if (alerts.length) {
    add(
      <Box key="review-warnings" flexDirection="column" width={width}>
        {alerts.map((line, i) => (
          <Text key={`review-warning-${i}`} color={C.red}>{`⚠ ${line}`}</Text>
        ))}
      </Box>,
      rowsOf(alerts, width - 2),
    )
  }

  if (review.isStructureOnly) {
    add(
      <Text key="review-structure" color={C.yellow}>Folder structure changed: a folder was added or removed since the last approval, and no file's text changed.</Text>,
      2,
    )
  }
  const hasText = review.files.some(file => file.text !== undefined)
  for (const [i, file] of review.files.entries()) {
    const label = file.text === undefined ? `Binary file: ${file.path} (${file.size} bytes)` : `${file.change === 'new' ? 'New' : 'Changed'} file: ${file.path} · ${file.size} bytes`
    const lines = file.text === undefined || !review.isShowingFiles ? [] : file.text.replace(/\n$/, '').split('\n')
    const chunks: string[][] = []
    for (let at = 0; at < lines.length; at += FILE_LINES_PER_TEXT) chunks.push(lines.slice(at, at + FILE_LINES_PER_TEXT))
    add(
      <Box key={`review-file-${i}`} flexDirection="column" width={width}>
        <Text color={C.accent} bold>{label}</Text>
        {chunks.map((chunk, c) => (
          <Box key={`review-file-${i}-${c}`} marginLeft={2} width={Math.max(1, width - 2)}>
            <Text color={C.text}>{chunk.join('\n')}</Text>
          </Box>
        ))}
      </Box>,
      1 + rowsOf(lines, width - 2),
    )
  }
  if (hasText) {
    add(<Button key="review-toggle-files" label={review.isShowingFiles ? 'Hide files' : 'Show files'} plain onPress={on.toggleFiles} />, 1)
  }
  if (review.removed.length) {
    add(
      <Box key="review-removed" flexDirection="column" width={width}>
        {review.removed.map((path, i) => (
          <Text key={`review-removed-${i}`} color={C.overlay1}>{`Removed file: ${path}`}</Text>
        ))}
      </Box>,
      review.removed.length,
    )
  }

  const isStale = review.refusal?.kind === 'changed'
  add(
    <Box key="review-press" flexDirection="column" width={width}>
      {review.refusal && <Text color={C.red}>{refusalText(review.refusal)}</Text>}
      <Box flexDirection="row" columnGap={2}>
        {isStale && <Button key="preview-again" label="Preview again" autoFocus onPress={on.previewAgain} />}
        <Button key="approve" label="Approve" autoFocus={isStale ? undefined : true} onPress={on.approve} />
      </Box>
    </Box>,
    review.refusal ? 3 : 1,
  )
  return { parts, rows, headings }
}
