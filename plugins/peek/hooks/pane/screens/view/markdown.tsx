import type { View } from '../../../../types'
import { docImage } from '../../../images'
import { diagramType, plainInline, segmentsOf } from '../../../markdown'
import { IMAGE_ROWS, chunkMarkdown, estimateRows, imageBox, taskRows } from '../../../measure'
import { fullText } from '../../../loaders'
import { pressLink } from '../../../navigation'
import type { NavIo } from '../../../navigation'
import { fileHref } from '../../../paths'
import { ICON } from '../../../theme'
import type { DrawContext } from '../../types'
import { DiagramEmbed, Embed, newBlocks, settleBlocks } from './blocks'
import type { ViewBody } from './blocks'

export async function markdownBody(ctx: DrawContext, io: NavIo, current: View, markdown: string, path: string): Promise<ViewBody> {
  const { Box, Text, Button, Markdown, Code, Image, Client, C, textWidth, isMenuOpen } = ctx
  const source = fullText.get(current.href) ?? markdown
  const blocks = newBlocks()
  const { drawnParts, note } = blocks
  let index = 0
  for (const part of segmentsOf(source)) {
    index += 1
    if (part.kind === 'markdown') {
      for (const [chunkIndex, chunk] of chunkMarkdown(part.text).entries()) {
        drawnParts.push(
          <Markdown dimColor={isMenuOpen} key={`body-${index}-${chunkIndex}`} text={chunk} onLinkPress={link => void pressLink(io, link.href)} />,
        )
        note(estimateRows(chunk, textWidth))
      }
      continue
    }
    if (part.kind === 'heading') {
      if (part.level === 1) {
        drawnParts.push(
          <Box key={`heading-${index}`} flexDirection="column">
            <Text color={C.accent} bold wrap="truncate-end">{part.text.toUpperCase()}</Text>
            <Text color={C.surface1} wrap="truncate-end">{'━'.repeat(textWidth)}</Text>
          </Box>,
        )
      } else if (part.level === 2) {
        const label = `${part.text.toUpperCase()} `
        drawnParts.push(
          <Box key={`heading-${index}`}>
            <Text wrap="truncate-end">
              <Text color={C.accent} bold>{label}</Text>
              <Text color={C.surface1}>{'─'.repeat(Math.max(1, textWidth - label.length))}</Text>
            </Text>
          </Box>,
        )
      } else {
        drawnParts.push(
          <Box key={`heading-${index}`}>
            <Text wrap="truncate-end">
              {part.level === 3 && <Text color={C.accent}>▸ </Text>}
              <Text color={part.level === 3 ? C.text : C.overlay1} bold>{part.text}</Text>
            </Text>
          </Box>,
        )
      }
      note(part.level === 1 ? 2 : 1, part.text)
      continue
    }
    if (part.kind === 'code') {
      if (part.lang === 'peek-diagram') {
        drawnParts.push(DiagramEmbed(ctx, `diagram-${index}`, part.info, part.text))
      } else if (part.lang === 'mermaid') {
        drawnParts.push(
          Embed(ctx, `diagram-${index}`, ICON.mermaid, 'DIAGRAM', `${diagramType(part.text)} · press o to see it rendered`, C.mauve, (
            isMenuOpen ? <Text color={C.overlay1}>{part.text}</Text> : <Code source={part.text} language="mermaid" wrap="truncate-end" />
          )),
        )
      } else {
        drawnParts.push(
          Embed(ctx, `code-${index}`, ICON.text, 'CODE', part.lang || 'text', C.blue, (
            isMenuOpen ? <Text color={C.overlay1}>{part.text || ' '}</Text> : <Code source={part.text || ' '} language={part.lang || undefined} wrap="truncate-end" />
          )),
        )
      }
      note(part.text.split('\n').length + 4)
      continue
    }
    if (part.kind === 'tasks' && Client) {
      const rowCount = taskRows(part.items, textWidth).length
      drawnParts.push(
        <Client
          key={`tasks-${index}`}
          module="../../../tasks.tsx"
          props={{ muted: isMenuOpen, width: textWidth, items: part.items }}
          width={textWidth}
          height={rowCount}
        />,
      )
      note(rowCount)
      continue
    }
    if (part.kind === 'tasks') {
      drawnParts.push(
        <Box key={`tasks-${index}`} flexDirection="column" width={textWidth}>
          {part.items.map(item => {
            const toggle = () => void pressLink(io, `${item.href}#task-${item.line}`)
            const scope = `task-${item.line}`
            return (
              <Box key={`task-row-${item.line}`} flexDirection="row" marginLeft={item.depth * 2}>
                <Button
                  key={`task-box-${item.line}`}
                  label={item.isDone ? '\u{f0135} ' : '\u{f0131} '}
                  plain
                  dimColor={item.isDone}
                  hover={{ scope, color: C.accent }}
                  onPress={toggle}
                />
                <Box flexShrink={1}>
                  <Button
                    key={`task-${item.line}`}
                    label={plainInline(item.text)}
                    plain
                    dimColor={item.isDone}
                    hover={{ scope, color: C.accent, strikethrough: !item.isDone }}
                    onPress={toggle}
                  />
                </Box>
              </Box>
            )
          })}
        </Box>,
      )
      note(part.items.reduce((rows, item) => rows + Math.max(1, Math.ceil(item.text.length / Math.max(10, textWidth - 2 - item.depth * 2))), 0))
      continue
    }
    if (part.kind === 'quote') {
      drawnParts.push(
        <Box key={`quote-${index}`} flexDirection="row" backgroundColor={C.surface0}>
          <Box width={1} backgroundColor={C.accent} />
          <Box flexDirection="column" paddingX={1} flexShrink={1}>
            <Markdown dimColor={isMenuOpen}
              key={`quote-text-${index}`}
              text={part.text
                .split('\n')
                .map(line => (line.trim() ? `*${line.trim()}*` : ''))
                .join('\n')}
              onLinkPress={link => void pressLink(io, link.href)}
            />
          </Box>
        </Box>,
      )
      note(estimateRows(part.text, textWidth - 3))
      continue
    }
    const picture = await docImage(io, part.src, path)
    const detail = part.alt || part.src
    if (picture?.png && Image) {
      drawnParts.push(
        Embed(ctx, `image-${index}`, ICON.image, 'IMAGE', detail, C.teal, (
          <Image
            key={`doc-image-${index}`}
            source={{ png: picture.png }}
            {...imageBox(picture.width, picture.height, textWidth - 4, IMAGE_ROWS - 2)}
            alt={`${part.alt || 'image'} (this terminal cannot draw images)`}
          />
        )),
      )
    } else {
      const target = picture ? fileHref(picture.abs) : part.src
      drawnParts.push(
        Embed(ctx, `image-${index}`, ICON.image, 'IMAGE', detail, C.teal, (
          <Markdown dimColor={isMenuOpen}
            key={`body-${index}`}
            text={picture ? `[open ${part.src}](${target})` : `*not found: ${part.src}*`}
            onLinkPress={link => void pressLink(io, link.href)}
          />
        )),
      )
    }
  }
  return settleBlocks(ctx, io, blocks)
}
