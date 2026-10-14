import type { RenderChildren } from 'claude-code'

import type { View } from '../../../../types'
import type { CardItem, Detail, PageAction, PageListItem, RecipePage, RecipeReview, ReviewRefusal } from '../../../../types/recipes'
import { clip } from '../../../format'
import { pixels } from '../../../images'
import { isWebUrl } from '../../../live'
import { linkify } from '../../../markdown'
import { estimateRows, imageBox } from '../../../measure'
import { openFromPage, paneHref, refContext, show, starKeyOf } from '../../../navigation'
import type { NavIo } from '../../../navigation'
import { PAGE_CAPS, itemsOf } from '../../../recipes/page'
import type { Page } from '../../../recipes/page'
import { approveRecipe, toggleReviewFiles } from '../../../recipes/session'
import { recipeLabel } from '../../../recipes/state'
import { columnWidths, fitCell } from '../../../tabular'
import { ICON } from '../../../theme'
import { CARD_GAP, CARD_MIN, CARD_ROWS, LIST_CHUNK, chunked } from '../../layout'
import type { ItemLook } from '../../look'
import type { Action, Crumb, DrawContext, NavItem, PaneActions, PictureBudget } from '../../types'
import { HoverLayer, ItemCard, ItemRow, SectionRule, fitPicture } from '../../widgets'
import { Embed, newBlocks, pictureRowsOf, settleBlocks } from './blocks'
import type { Blocks, ViewBody } from './blocks'
import { drawProse } from './prose'
import type { PictureSlot } from './prose'

export const EMPTY_PAGE = 'This page has no sections.'
export const EMPTY_SECTION = 'Nothing in this section.'
// Media blocks key their pictures from here and markdown pictures count from 0 in the same draw; a markdown block
// (100,000 characters at most) holds far fewer than 10,000, so the ranges never meet.
export const PAGE_MEDIA_BASE = 10_000
const NOTICE_TEXT = 60
const LABEL_MAX = 24
const REVIEW_HEADING = 'Approve'
const FILE_LINES_PER_TEXT = 200

type Ready = Extract<RecipePage, { phase: 'ready' }>
type Media = NonNullable<Ready['media']>
type Pictures = NonNullable<Ready['pictures']>

export function pageCrumbs(ctx: DrawContext, current: View, page: RecipePage): Crumb[] {
  const { C } = ctx
  return [
    { label: `${ICON.recipe} ${recipeLabel(page)}`, fg: C.subtext0 as string, bg: C.surface1 as string, canShrink: true },
    { label: `${ICON.web} ${current.title}`, fg: C.appBg, bg: C.accent, bold: true },
  ]
}

export function pageNotice(ctx: DrawContext, page: RecipePage): RenderChildren {
  const { Box, Text, C } = ctx
  if (page.phase !== 'conflict' && page.isRefreshing) {
    return (
      <Box key="page-refreshing" marginBottom={1}>
        <Text color={C.overlay1}>Refreshing…</Text>
      </Box>
    )
  }
  if (page.phase === 'ready' && page.refreshFailure) {
    return (
      <Box key="page-refresh-failed" marginBottom={1}>
        <Text color={C.red}>{`Refresh failed: ${page.refreshFailure}`}</Text>
      </Box>
    )
  }
  return null
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

const rowsOf = (lines: readonly string[], width: number) => lines.reduce((sum, line) => sum + Math.max(1, Math.ceil(line.length / Math.max(1, width))), 0)

export type PageBody = ViewBody & { keys: Action[] }

type PageDraw = {
  ctx: DrawContext
  io: NavIo
  actions: PaneActions
  blocks: Blocks
  nav: NavItem[]
  selected: number
  budget: PictureBudget
  media: Media | undefined
  pictures: Pictures | undefined
  isStarred: (href: string) => boolean
  line: number
}

function mediaChild(draw: PageDraw, index: number, alt: string, url: string, width: number): PictureSlot {
  const { Box, Button, Markdown, Image, isMenuOpen } = draw.ctx
  const key = `media-${index}`
  const one = draw.media?.[url]
  const shot = draw.pictures?.[url]
  const png = fitPicture(draw.budget, shot && pixels.get(shot.file))
  const box = png && Image && shot ? imageBox(shot.width, shot.height, width, pictureRowsOf(draw.ctx)) : null
  return {
    isVideo: Boolean(one?.play),
    rows: (box?.rows ?? 1) + (one?.play ? 1 : 0),
    child: (
      <Box flexDirection="column">
        {box && png && Image ? (
          <Image key={`${key}-image`} source={{ png }} {...box} alt={alt || 'image'} />
        ) : (
          !one?.play && <Markdown dimColor={isMenuOpen} key={`${key}-link`} text={`[open image](${url})`} onLinkPress={link => void openFromPage(draw.io, paneHref(link.href))} />
        )}
        {one?.play && (
          <Button key={`media-play-${index}`} label={'\u{f04b} Play video'} plain onPress={() => void (isWebUrl(url) && draw.io.run(['open', url]).catch(() => undefined))} />
        )}
      </Box>
    ),
  }
}

function lookOf(draw: PageDraw, one: CardItem, index: number): ItemLook & { isStarred: boolean } {
  const href = one.href ? paneHref(one.href) : ''
  const shot = one.image ? draw.pictures?.[one.image] : undefined
  return {
    key: `item-${index}`,
    href,
    name: one.title,
    kind: 'web',
    where: placeOf(one.href),
    state: 'ok',
    favicon: fitPicture(draw.budget, shot && pixels.get(shot.file)),
    isStarred: href ? draw.isStarred(href) : false,
  }
}

function iconSlot(draw: PageDraw, look: ItemLook & { isStarred: boolean }, index: number, raw: string | undefined) {
  const isSelected = index === draw.selected
  return {
    isStarred: look.isStarred,
    ...(look.favicon ? { png: look.favicon } : {}),
    icon: iconOf(raw),
    imageKey: `favicon-${index}`,
    buttonKey: `item-${index}`,
    ...(isSelected ? { autoFocus: true as const } : {}),
    onPress: () => void draw.actions.selectAndOpen(index),
  }
}

function cardGrid(draw: PageDraw, key: string, items: readonly CardItem[], heading: string) {
  const { ctx } = draw
  const { Box, C, textWidth } = ctx
  const perRow = Math.max(1, Math.floor((textWidth + CARD_GAP) / (CARD_MIN + CARD_GAP)))
  const cardWidth = Math.floor((textWidth - (perRow - 1) * CARD_GAP) / perRow)
  const rows = chunked(items, perRow).map((row, r) => {
    const line = draw.line++
    const first = draw.nav.length
    const looks = row.map((one, c) => lookOf(draw, one, first + c))
    looks.forEach((look, col) => draw.nav.push({ href: look.href, key: `${key}-${r}`, line, col }))
    return (
      <Box key={`${key}-${r}`} flexDirection="row" columnGap={CARD_GAP} marginBottom={1} width={textWidth}>
        {looks.map((look, c) => {
          const index = first + c
          const isSelected = index === draw.selected
          return ItemCard(ctx, look, {
            key: `${key}-${r}-${c}`,
            width: cardWidth,
            height: CARD_ROWS,
            background: isSelected ? C.surface0 : C.cardBg,
            clip: false,
            icon: iconSlot(draw, look, index, row[c]?.href),
            nameKey: `name-${index}`,
            nameColor: isSelected ? C.accent : C.text,
            meta: row[c]?.meta ?? '',
            metaColor: isSelected ? C.overlay1 : C.overlay0,
          })
        })}
        {HoverLayer(ctx, `hover-${key}-${r}`, {
          kind: 'cards',
          width: textWidth,
          height: CARD_ROWS,
          cardWidth,
          cardHeight: CARD_ROWS,
          gap: CARD_GAP,
          starX: 2,
          starY: 1,
          items: looks.map(look => ({ href: look.href, isStarred: look.isStarred })),
        })}
      </Box>
    )
  })
  draw.blocks.drawnParts.push(
    <Box key={`${key}-items`} flexDirection="column" width={textWidth}>
      {rows}
    </Box>,
  )
  draw.blocks.note(rows.length * (CARD_ROWS + 1), heading)
}

function rowList(draw: PageDraw, key: string, items: readonly PageListItem[], heading: string) {
  const { ctx } = draw
  const { Box, C, textWidth } = ctx
  const chunks = chunked(items, LIST_CHUNK).map((chunk, i) => {
    const first = draw.nav.length
    const looks = chunk.map((one, j) => lookOf(draw, one, first + j))
    for (const look of looks) draw.nav.push({ href: look.href, key: `${key}-${i}`, line: draw.line++, col: 0 })
    return (
      <Box key={`${key}-${i}`} flexDirection="column" width={textWidth}>
        {looks.map((look, j) => {
          const index = first + j
          const isSelected = index === draw.selected
          return ItemRow(ctx, look, {
            key: `${key}-${i}-${j}`,
            width: textWidth,
            isSelected,
            icon: { ...iconSlot(draw, look, index, chunk[j]?.href), boxes: {} },
            nameKey: `name-${index}`,
            nameColor: isSelected ? C.accent : C.text,
            meta: chunk[j]?.meta ?? '',
            metaColor: C.overlay0,
          })
        })}
        {HoverLayer(ctx, `hover-${key}-${i}`, { kind: 'rows', width: textWidth, height: chunk.length, starX: 0, starY: 0, items: looks.map(look => ({ href: look.href, isStarred: look.isStarred })) })}
      </Box>
    )
  })
  draw.blocks.drawnParts.push(
    <Box key={`${key}-items`} flexDirection="column" width={textWidth}>
      {chunks}
    </Box>,
  )
  draw.blocks.note(items.length, heading)
}

function linkedTable(draw: PageDraw, key: string, block: { columns: string[]; rows: { cells: string[]; href?: string }[] }, heading: string) {
  const { ctx } = draw
  const { Box, Text, Button, C, textWidth: width } = ctx
  const widths = columnWidths([block.columns, ...block.rows.map(one => one.cells)], Math.max(1, width - 2))
  const line = (cells: readonly string[]) => widths.map((w, c) => fitCell(cells[c] ?? '', w)).join('  ')
  const hrefs = block.rows.map(row => (row.href ? paneHref(row.href) : ''))
  draw.blocks.drawnParts.push(
    <Box key={key} flexDirection="column" width={width}>
      <Text key={`${key}-head`} color={C.accent} bold wrap="truncate-end">{`  ${line(block.columns)}`}</Text>
      <Text key={`${key}-table-rule`} color={C.surface1} wrap="truncate-end">{`  ${widths.map(w => '─'.repeat(w)).join('  ')}`}</Text>
      <Box key={`${key}-rows`} flexDirection="column" width={width}>
        {block.rows.map((row, r) => {
          const index = draw.nav.length
          const rowKey = `${key}-row-${r}`
          draw.nav.push({ href: hrefs[r] ?? '', key: rowKey, line: draw.line++, col: 0 })
          const isSelected = index === draw.selected
          return (
            <Box key={rowKey} flexDirection="row" height={1} width={width} backgroundColor={isSelected ? C.surface0 : undefined} hover={{ backgroundColor: C.surface0 }}>
              <Button key={`item-${index}`} label={isSelected ? '›' : ' '} plain {...(isSelected ? { autoFocus: true } : {})} onPress={() => void draw.actions.selectAndOpen(index)} />
              <Text color={isSelected ? C.accent : C.text} wrap="truncate-end">{` ${line(row.cells)}`}</Text>
            </Box>
          )
        })}
        {HoverLayer(ctx, `hover-${key}`, { kind: 'rows', width, height: block.rows.length, starX: 0, starY: 0, items: hrefs.map(href => ({ href, isStarred: href ? draw.isStarred(href) : false })) })}
      </Box>
    </Box>,
  )
  draw.blocks.note(block.rows.length + 2, heading)
}

function fieldRows(draw: PageDraw, key: string, list: readonly Detail[], heading: string) {
  const { Box, Text, C, textWidth } = draw.ctx
  const labelWidth = Math.min(LABEL_MAX, Math.max(0, ...list.map(one => one.label.length))) + 2
  draw.blocks.drawnParts.push(
    <Box key={key} flexDirection="column" width={textWidth}>
      {list.map((one, i) => (
        <Text key={`${key}-${i}`} wrap="truncate-end">
          <Text color={C.overlay0}>{fitCell(one.label, labelWidth - 2).trimEnd().padEnd(labelWidth)}</Text>
          <Text color={C.text}>{one.value}</Text>
        </Text>
      ))}
    </Box>,
  )
  draw.blocks.note(list.length, heading)
}

function actionKeys(io: NavIo, list: readonly PageAction[]): Action[] {
  return list.slice(0, PAGE_CAPS.actions).map((action, i) => ({
    id: `action-${i}`,
    label: action.label,
    hotkey: String(i + 1),
    menu: action.label,
    run: () => {
      if ('open' in action) {
        void openFromPage(io, paneHref(action.open))
        return
      }
      void io.copy({ text: action.copy }).catch(() => undefined)
      io.toast(`Copied ${clip(action.copy, NOTICE_TEXT)}`)
    },
  }))
}

async function drawPage(draw: PageDraw, page: Page) {
  const { ctx, io, blocks } = draw
  const { Text, C, textWidth } = ctx
  const refs = refContext()
  blocks.drawnParts.push(<Text key="page-title" color={C.text} bold>{page.title}</Text>)
  blocks.note(Math.max(1, Math.ceil(page.title.length / Math.max(1, textWidth))), page.title)
  if (page.details?.length) fieldRows(draw, 'page-details', page.details, 'Details')
  if (page.sections.length === 0) {
    blocks.drawnParts.push(<Text key="page-empty" color={C.overlay0}>{EMPTY_PAGE}</Text>)
    blocks.note(1)
  }
  let mediaIndex = PAGE_MEDIA_BASE
  let inlineIndex = 0
  const inlinePicture = (alt: string, src: string, _key: string, width: number) => (draw.media?.[src] ? mediaChild(draw, inlineIndex++, alt, src, width) : null)
  for (const [i, { heading = '', block }] of page.sections.entries()) {
    const key = `section-${i}`
    if (heading) {
      blocks.drawnParts.push(SectionRule(ctx, heading.toUpperCase(), '', textWidth, `${key}-rule`))
      blocks.note(1, heading)
    }
    if (itemsOf(block) === 0) {
      blocks.drawnParts.push(<Text key={`${key}-empty`} color={C.overlay0}>{EMPTY_SECTION}</Text>)
      blocks.note(1, heading)
      continue
    }
    if (block.type === 'markdown') {
      await drawProse(ctx, io, blocks, `${key}-md`, linkify(block.text, () => null, refs), { picture: inlinePicture, heading })
    } else if (block.type === 'media') {
      for (const one of block.items) {
        const index = mediaIndex++
        const slot = mediaChild(draw, index, one.alt ?? '', one.url, textWidth - 2)
        const label = slot.isVideo ? 'VIDEO' : 'IMAGE'
        blocks.drawnParts.push(Embed(ctx, `media-${index}`, slot.isVideo ? '\u{f03d}' : ICON.image, label, one.alt || placeOf(one.url), C.teal, slot.child))
        blocks.note(slot.rows + 4, heading)
      }
    } else if (block.type === 'table') {
      linkedTable(draw, key, block, heading)
    } else if (block.type === 'cards') {
      cardGrid(draw, key, block.items, heading)
    } else if (block.type === 'list') {
      rowList(draw, key, block.items, heading)
    } else {
      fieldRows(draw, key, block.rows, heading)
    }
  }
  return actionKeys(io, page.actions ?? [])
}

function refusalText(refusal: ReviewRefusal): string {
  if (refusal.kind === 'changed') return "Changed since preview: the recipe's files are not the ones this page shows. Preview again to read them."
  if (refusal.kind === 'overlap') return `Not approved: its links overlap approved recipe "${refusal.id}". Change one recipe's match so only one claims a link.`
  return `Not approved: ${refusal.message}`
}

function approveBar(width: number): string {
  const label = '\u{f00c} Approve'
  const room = Math.max(label.length, width)
  const left = Math.floor((room - label.length) / 2)
  return ' '.repeat(left) + label + ' '.repeat(room - label.length - left)
}

// Approve has no hotkey and no keybinding action, and sits in no footer or menu: only a press on the Button itself,
// which the plugin API cannot raise, records an approval.
function drawApproval(ctx: DrawContext, blocks: Blocks, review: RecipeReview, on: { approve: () => void; previewAgain: () => void; toggleFiles: () => void }) {
  const { Box, Text, Button, C, textWidth: width } = ctx
  const add = (part: RenderChildren, rows: number) => {
    blocks.drawnParts.push(part)
    blocks.note(rows, REVIEW_HEADING)
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
      <Text color={C.subtext0}>Approve sends it live for every link it matches; b leaves it a draft.</Text>
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
    add(<Text key="review-structure" color={C.yellow}>Folder structure changed: a folder was added or removed since the last approval, and no file's text changed.</Text>, 2)
  }
  const hasText = review.files.some(file => file.text !== undefined)
  for (const [i, file] of review.files.entries()) {
    const label = file.text === undefined ? `Binary file: ${file.path} (${file.size} bytes)` : `${file.change === 'new' ? 'New' : 'Changed'} file: ${file.path} · ${file.size} bytes`
    const lines = file.text === undefined || !review.isShowingFiles ? [] : file.text.replace(/\n$/, '').split('\n')
    add(
      <Box key={`review-file-${i}`} flexDirection="column" width={width}>
        <Text color={C.accent} bold>{label}</Text>
        {chunked(lines, FILE_LINES_PER_TEXT).map((chunk, c) => (
          <Box key={`review-file-${i}-${c}`} marginLeft={2} width={Math.max(1, width - 2)}>
            <Text color={C.text}>{chunk.join('\n')}</Text>
          </Box>
        ))}
      </Box>,
      1 + rowsOf(lines, width - 2),
    )
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
      <Box marginTop={1} width={width}>
        <Button key="approve" label="Approve" {...(isStale ? {} : { autoFocus: true })} onPress={on.approve}>
          <Text color={C.panelBg} backgroundColor={C.green} bold>{approveBar(width)}</Text>
        </Button>
      </Box>
      <Box flexDirection="row" columnGap={2}>
        {isStale && <Button key="preview-again" label="Preview again" autoFocus onPress={on.previewAgain} />}
        {hasText && <Button key="review-toggle-files" label={review.isShowingFiles ? 'Hide files' : 'Show files'} plain onPress={on.toggleFiles} />}
      </Box>
    </Box>,
    (review.refusal ? 3 : 1) + 2,
  )
}

export async function recipePageBody(ctx: DrawContext, actions: PaneActions, current: View, state: RecipePage, selected: number): Promise<PageBody> {
  const { Box, Text, C, textWidth } = ctx
  const io = actions.io
  const href = current.href
  const blocks = newBlocks()
  if ((state.phase === 'ready' || state.phase === 'failed') && state.isDraft && state.review) {
    drawApproval(ctx, blocks, state.review, {
      approve: () => void approveRecipe(io, href),
      previewAgain: () => void show(io, state.link, false, { allowDraft: true }),
      toggleFiles: () => void toggleReviewFiles(io, href),
    })
  }
  if (state.phase === 'ready') {
    const starKeys = new Set((await io.stars.read()).map(starKeyOf))
    const draw: PageDraw = {
      ctx,
      io,
      actions,
      blocks,
      nav: [],
      selected,
      budget: { used: 0 },
      media: state.media,
      pictures: state.pictures,
      isStarred: one => starKeys.has(starKeyOf(one)),
      line: 0,
    }
    const keys = await drawPage(draw, state.page)
    const settled = settleBlocks(ctx, io, blocks)
    return { ...settled, layout: { ...settled.layout, nav: draw.nav }, keys }
  }
  if (state.phase === 'loading') {
    blocks.drawnParts.push(
      <Box key="page-loading" flexDirection="column">
        <Text color={C.overlay1}>{`Running ${state.name}…`}</Text>
        <Text color={C.overlay0} wrap="truncate-end">{state.link}</Text>
      </Box>,
    )
    blocks.note(2)
  } else {
    blocks.drawnParts.push(
      <Box key="page-failure" flexDirection="column">
        <Text color={C.red} bold>Recipe page failed</Text>
        <Text color={C.subtext0}>{state.failure}</Text>
        <Text color={C.overlay0}>Press u to try again, or o to open the link in the browser.</Text>
      </Box>,
    )
    blocks.note(estimateRows(state.failure, textWidth) + 2)
  }
  const settled = settleBlocks(ctx, io, blocks)
  return { ...settled, layout: { ...settled.layout, nav: [] }, keys: [] }
}
