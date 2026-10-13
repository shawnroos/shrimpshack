import type { RenderChildren } from 'claude-code'

import { diagramType, plainInline, segmentsOf } from '../../../markdown'
import type { DocPart } from '../../../markdown'
import { chunkMarkdown, estimateRows, taskRows } from '../../../measure'
import { pressLink } from '../../../navigation'
import type { NavIo } from '../../../navigation'
import { ICON } from '../../../theme'
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
}

export type ProsePart = { node: RenderChildren; rows: number; heading?: string }

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
  const add = (node: RenderChildren, rows: number, heading?: string) =>
    out.push({ node: indent ? <Box key={`${key}-in-${out.length}`} marginLeft={indent}>{node}</Box> : node, rows, heading })
  let chunkIndex = 0
  for (const [index, part] of partsOf(text).entries()) {
    const at = `${key}-${index}`
    if (part.kind === 'markdown') {
      for (const chunk of chunkMarkdown(part.text)) {
        add(<Markdown dimColor={isMenuOpen} key={`${key}-md-${chunkIndex++}`} text={chunk} onLinkPress={link => onLink(link.href)} />, estimateRows(chunk, width))
      }
    } else if (part.kind === 'heading') {
      add(Heading(inner, `${at}-heading`, part.level, part.text), part.level === 1 ? 2 : 1, part.text)
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
  for (const part of await proseParts(ctx, io, key, text, options)) {
    blocks.drawnParts.push(part.node)
    blocks.note(part.rows, part.heading ?? options.heading)
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
