import type { RenderChildren } from 'claude-code'

import { fetchedAge } from '../../../format'
import { diagramType, plainInline, segmentsOf } from '../../../markdown'
import type { DocPart } from '../../../markdown'
import { chunkMarkdown, estimateRows, taskRows } from '../../../measure'
import { paneHref, pressLink } from '../../../navigation'
import type { NavIo } from '../../../navigation'
import { ICON } from '../../../theme'
import { matches } from '../../../views/definition'
import type { Definition } from '../../../views/definition'
import type { Item } from '../../../views/items'
import { recipeBlock } from '../../../views/recipe-source'
import type { RecipeBlock } from '../../../views/recipe-source'
import { select } from '../../../views/select'
import type { Rule } from '../../../views/select'
import { drawBoard } from '../../blocks/board'
import { drawCards } from '../../blocks/cards'
import { RECORD_BLOCKS, blockSpec, getPlace, placeKey } from '../../blocks/common'
import type { BlockSpec } from '../../blocks/common'
import { drawFocus } from '../../blocks/focus'
import { drawList } from '../../blocks/list'
import { DimLine, ItemLine } from '../../blocks/row'
import type { BlockDraw, BlockEnv, BlockNav } from '../../blocks/row'
import { drawSections } from '../../blocks/sections'
import { drawTree } from '../../blocks/tree'
import type { DrawContext } from '../../types'
import { DiagramEmbed, Embed, ListBlock, TableBlock } from './blocks'
import type { Blocks } from './blocks'

export type PictureSlot = { child: RenderChildren; rows: number; isVideo?: boolean }

export type ProseOptions = {
  // Each page loads pictures its own way: a local file, a pre-downloaded remote one, a Slack file.
  picture: (alt: string, src: string, key: string, width: number) => PictureSlot | null | Promise<PictureSlot | null>
  // Only a local file's tasks can be ticked; elsewhere a linked task is drawn read-only.
  canTickTasks?: boolean
  indent?: number
  // What a collection block draws from; a page without one draws each block's empty row.
  items?: (rule: Rule, options: Record<string, string>) => readonly Item[] | Promise<readonly Item[]>
  // Shares one cache read per draw; it must only read, since a block never runs its recipe.
  recipe?: (id: string, url: string | undefined) => Promise<RecipeBlock>
  // The loaded definitions, so a row takes the colors its own type declares.
  definitions?: () => readonly Definition[] | Promise<readonly Definition[]>
  // The page's keyboard row the first block row takes, when earlier prose on the page already claimed rows.
  navStart?: number
  // A record page draws the record blocks (header, fields, media, comments) from its record; elsewhere each is a note.
  record?: (lang: RecordBlock, options: Record<string, string>, navStart: number) => Promise<ProsePart[]>
}

export type RecordBlock = (typeof RECORD_BLOCKS)[number]

export type ProsePart = { node: RenderChildren; rows: number; heading?: string; nav?: BlockNav[] }

const INFO_OPTION = /^([\w.-]+)=(.*)$/

const isRecordBlock = (lang: string): lang is RecordBlock => (RECORD_BLOCKS as readonly string[]).includes(lang)

const infoOptions = (info: string): Record<string, string> =>
  Object.fromEntries(info.split(/\s+/).flatMap(token => {
    const option = INFO_OPTION.exec(token)
    return option?.[1] && option[2] !== undefined ? [[option[1], option[2]]] : []
  }))

const MAX_PARSED = 300
const parsed = new Map<string, DocPart[]>()

function partsOf(text: string): DocPart[] {
  const cached = parsed.get(text)
  if (cached) return cached
  if (parsed.size > MAX_PARSED) parsed.clear()
  const parts = segmentsOf(text)
  parsed.set(text, parts)
  return parts
}

// The one markdown drawing for every page: files, pull requests, issues, Linear, comments and Slack.
export async function proseParts(ctx: DrawContext, io: NavIo, key: string, text: string, options: ProseOptions): Promise<ProsePart[]> {
  const indent = options.indent ?? 0
  const width = ctx.textWidth - indent
  const inner: DrawContext = indent ? { ...ctx, textWidth: width } : ctx
  const { Box, Button, Markdown, Client, C, isMenuOpen } = inner
  const onLink = (href: string) => void pressLink(io, href)
  const out: ProsePart[] = []
  const add = (node: RenderChildren, rows: number, heading?: string, nav?: BlockNav[]) =>
    out.push({ node: indent ? <Box key={`${key}-in-${out.length}`} marginLeft={indent}>{node}</Box> : node, rows, heading, ...(nav?.length ? { nav } : {}) })
  let cursor: number | undefined
  let definitions: readonly Definition[] | undefined
  let navCount = options.navStart ?? 0
  let chunkIndex = 0
  for (const [index, part] of partsOf(text).entries()) {
    const at = `${key}-${index}`
    const spec = part.kind === 'code' ? blockSpec(part.lang, part.info, part.text) : null
    if (part.kind === 'markdown') {
      for (const chunk of chunkMarkdown(part.text)) {
        add(<Markdown dimColor={isMenuOpen} key={`${key}-md-${chunkIndex++}`} text={chunk} onLinkPress={link => onLink(link.href)} />, estimateRows(chunk, width))
      }
    } else if (part.kind === 'heading') {
      add(Heading(inner, `${at}-heading`, part.level, part.text), part.level === 1 ? 2 : 1, part.text)
    } else if (part.kind === 'code' && isRecordBlock(part.lang) && options.record) {
      for (const drawn of await options.record(part.lang, infoOptions(part.info), navCount)) {
        navCount += drawn.nav?.length ?? 0
        add(drawn.node, drawn.rows, drawn.heading, drawn.nav)
      }
    } else if (part.kind === 'code' && isRecordBlock(part.lang)) {
      add(DimLine(inner, `${at}-record`, `${part.lang} · drawn on a record page`, width), 1)
    } else if (spec) {
      cursor ??= await io.cursor.read()
      definitions ??= (await options.definitions?.()) ?? []
      const known = definitions
      const nav: BlockNav[] = []
      const env: BlockEnv = {
        ctx: inner,
        key: at,
        width,
        place: placeKey(ctx.current?.href ?? '', at),
        layout: spec.layout,
        nestProp: spec.options.nest || 'parent',
        folded: new Set(),
        cursor,
        navStart: navCount,
        nav,
        open: href => void pressLink(io, paneHref(href)),
        colorsOf: item => known.find(one => matches(one, { path: item.href, props: item.props }))?.colors,
      }
      const how = { rule: spec.rule, ...(spec.cap === undefined ? {} : { cap: spec.cap }) }
      const recipe = spec.options.recipe
      // A recipe fence never falls through to the page's items: its rule is empty, so it would select every task.
      const drawn =
        recipe === undefined
          ? collection(env, spec, select((await options.items?.(spec.rule, spec.options)) ?? [], how))
          : recipeCollection(env, spec, recipe, await (options.recipe ?? ((id, url) => recipeBlock(io, id, url)))(recipe, spec.options.url), how, await io.now())
      navCount += nav.length
      add(drawn.node, drawn.rows, undefined, nav)
    } else if (part.kind === 'code') {
      add(CodePart(inner, at, part), part.text.split('\n').length + 4)
    } else if (part.kind === 'quote') {
      add(
        <Box key={`${at}-quote`} flexDirection="row" backgroundColor={C.surface0}>
          <Box width={1} backgroundColor={C.accent} />
          <Box flexDirection="column" paddingX={1} flexShrink={1}>
            <Markdown
              dimColor={isMenuOpen}
              key={`${at}-quote-text`}
              text={part.text.split('\n').map(line => (line.trim() ? `*${line.trim()}*` : '')).join('\n')}
              onLinkPress={link => onLink(link.href)}
            />
          </Box>
        </Box>,
        estimateRows(part.text, width - 3),
      )
    } else if (part.kind === 'table') {
      const table = TableBlock(inner, `${at}-table`, part)
      add(table.node, table.rows)
    } else if (part.kind === 'list') {
      const list = ListBlock(inner, `${at}-list`, part.items, onLink)
      add(list.node, list.rows)
    } else if (part.kind === 'tasks' && !options.canTickTasks) {
      const items = part.items.map(item => ({ depth: item.depth, marker: item.isDone ? ('done' as const) : ('open' as const), text: item.text }))
      const list = ListBlock(inner, `${at}-list`, items, onLink)
      add(list.node, list.rows)
    } else if (part.kind === 'tasks' && Client) {
      const rowCount = taskRows(part.items, width).length
      add(<Client key={`tasks-${index + 1}`} module="../../../tasks.tsx" props={{ muted: isMenuOpen, width, items: part.items }} width={width} height={rowCount} />, rowCount)
    } else if (part.kind === 'tasks') {
      add(
        <Box key={`tasks-${index + 1}`} flexDirection="column" width={width}>
          {part.items.map(item => {
            const toggle = () => onLink(`${item.href}#task-${item.line}`)
            const scope = `task-${item.line}`
            return (
              <Box key={`task-row-${item.line}`} flexDirection="row" marginLeft={item.depth * 2}>
                <Button key={`task-box-${item.line}`} label={item.isDone ? '\u{f0135} ' : '\u{f0131} '} plain dimColor={item.isDone} hover={{ scope, color: C.accent }} onPress={toggle} />
                <Box flexShrink={1}>
                  <Button key={`task-${item.line}`} label={plainInline(item.text)} plain dimColor={item.isDone} hover={{ scope, color: C.accent, strikethrough: !item.isDone }} onPress={toggle} />
                </Box>
              </Box>
            )
          })}
        </Box>,
        part.items.reduce((rows, item) => rows + Math.max(1, Math.ceil(item.text.length / Math.max(10, width - 2 - item.depth * 2))), 0),
      )
    } else if (part.kind === 'image') {
      const slot = await options.picture(part.alt, part.src, `${at}-picture`, width - 2)
      const shown = slot ?? {
        child: <Markdown dimColor={isMenuOpen} key={`${at}-picture-link`} text={`[open ${part.alt || 'image'}](${part.src})`} onLinkPress={link => onLink(link.href)} />,
        rows: 1,
      }
      add(
        Embed(inner, `${at}-image`, shown.isVideo ? '\u{f03d}' : ICON.image, shown.isVideo ? 'VIDEO' : 'IMAGE', part.alt || part.src, C.teal, shown.child),
        shown.rows + 4,
      )
    }
  }
  return out
}

export async function drawProse(ctx: DrawContext, io: NavIo, blocks: Blocks, key: string, text: string, options: ProseOptions & { heading?: string }) {
  for (const part of await proseParts(ctx, io, key, text, { navStart: blocks.nav.length, ...options })) {
    blocks.drawnParts.push(part.node)
    blocks.nav.push(...(part.nav ?? []))
    blocks.note(part.rows, part.heading ?? options.heading)
  }
}

// The layout chosen for this place (y) wins over the fence's own.
function collection(base: BlockEnv, spec: BlockSpec, items: readonly Item[]): BlockDraw {
  const chosen = getPlace(base.place)
  const env: BlockEnv = { ...base, layout: chosen?.layout ?? spec.layout, folded: new Set(chosen?.folded ?? []) }
  if (!items.length) return { node: DimLine(env.ctx, env.key, spec.selects ? `no items · ${spec.selects}` : 'no items', env.width), rows: 1 }
  if (env.layout === 'cards') return drawCards(env, items)
  if (env.layout === 'tree') return drawTree(env, items)
  if (env.layout === 'sections') return drawSections(env, items, spec.options)
  if (env.layout === 'board') return drawBoard(env, items, spec.options)
  if (env.layout === 'focus') return drawFocus(env, items)
  return drawList(env, items)
}

function recipeCollection(env: BlockEnv, spec: BlockSpec, recipe: string, block: RecipeBlock, how: Parameters<typeof select>[1], now: number): BlockDraw {
  const { Box, Text, C } = env.ctx
  if (block.kind === 'error') return { node: <Text key={env.key} color={C.red} wrap="truncate-end">{block.text}</Text>, rows: 1 }
  if (block.kind === 'load') {
    const row: Item = { id: `${recipe}#load`, href: block.link, type: 'recipe', name: 'Open to load', props: {}, source: 'record' }
    return { node: <Box key={env.key} flexDirection="column" width={env.width}>{ItemLine(env, row, { branch: '', fold: '', count: 0 })}</Box>, rows: 1 }
  }
  const drawn = collection(env, spec, select(block.items, how))
  return {
    node: (
      <Box key={env.key} flexDirection="column" width={env.width}>
        {drawn.node}
        {DimLine(env.ctx, `${env.key}-fetched`, `recipe ${recipe} · fetched ${fetchedAge(block.fetchedAt, now)}`, env.width)}
      </Box>
    ),
    rows: drawn.rows + 1,
  }
}

function Heading(ctx: DrawContext, key: string, level: number, text: string) {
  const { Box, Text, C, textWidth } = ctx
  if (level === 1) {
    return (
      <Box key={key} flexDirection="column">
        <Text color={C.accent} bold wrap="truncate-end">{text.toUpperCase()}</Text>
        <Text color={C.surface1} wrap="truncate-end">{'━'.repeat(textWidth)}</Text>
      </Box>
    )
  }
  if (level === 2) {
    const label = `${text.toUpperCase()} `
    return (
      <Box key={key}>
        <Text wrap="truncate-end">
          <Text color={C.accent} bold>{label}</Text>
          <Text color={C.surface1}>{'─'.repeat(Math.max(1, textWidth - label.length))}</Text>
        </Text>
      </Box>
    )
  }
  return (
    <Box key={key}>
      <Text wrap="truncate-end">
        {level === 3 && <Text color={C.accent}>▸ </Text>}
        <Text color={level === 3 ? C.text : C.overlay1} bold>{text}</Text>
      </Text>
    </Box>
  )
}

function CodePart(ctx: DrawContext, key: string, part: Extract<DocPart, { kind: 'code' }>) {
  const { Text, Code, C, isMenuOpen } = ctx
  if (part.lang === 'peek-diagram') return DiagramEmbed(ctx, `${key}-diagram`, part.info, part.text)
  if (part.lang === 'mermaid') {
    return Embed(ctx, `${key}-diagram`, ICON.mermaid, 'DIAGRAM', `${diagramType(part.text)} · press o to see it rendered`, C.mauve, (
      isMenuOpen ? <Text color={C.overlay1}>{part.text}</Text> : <Code source={part.text} language="mermaid" wrap="truncate-end" />
    ))
  }
  return Embed(ctx, `${key}-code`, ICON.text, 'CODE', part.lang || 'text', C.blue, (
    isMenuOpen ? <Text color={C.overlay1}>{part.text || ' '}</Text> : <Code source={part.text || ' '} language={part.lang || undefined} wrap="truncate-end" />
  ))
}
