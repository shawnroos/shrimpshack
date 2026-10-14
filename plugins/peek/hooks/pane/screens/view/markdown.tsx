import type { View } from '../../../../types'
import { docImage } from '../../../images'
import { IMAGE_ROWS, imageBox } from '../../../measure'
import { fullText } from '../../../loaders'
import { pressLink } from '../../../navigation'
import type { NavIo } from '../../../navigation'
import { baseName, fileHref } from '../../../paths'
import { problemLine } from '../../../views/definition'
import { fillTemplate } from '../../../views/fill'
import type { Item } from '../../../views/items'
import { problemsFor } from '../../../views/registry'
import { definitionIn, taskItems } from '../../task-data'
import type { DrawData } from '../../task-data'
import type { DrawContext } from '../../types'
import { newBlocks, settleBlocks } from './blocks'
import type { ViewBody } from './blocks'
import { drawProse } from './prose'
import type { ProseOptions } from './prose'

const NO_TASKS = 'No tasks yet. Tell the agent: "task: ..."'
const TASKS_PAGE = '```peek-focus\n```'

// Read once per draw, and only when a block asks.
export function itemsOnce(io: NavIo): NonNullable<ProseOptions['items']> {
  let loaded: Promise<Item[]> | null = null
  return () => (loaded ??= taskItems(io))
}

const definitionsOnce = (draw: DrawData): NonNullable<ProseOptions['definitions']> => async () => (await draw.views()).definitions

export async function markdownBody(ctx: DrawContext, io: NavIo, current: View, markdown: string, path: string, draw: DrawData): Promise<ViewBody> {
  const { Box, Text, Image, Markdown, C, isMenuOpen, textWidth } = ctx
  const source = fullText.get(current.href) ?? markdown
  const blocks = newBlocks()
  const options: ProseOptions = {
    canTickTasks: true,
    items: draw.items,
    recipe: draw.recipe,
    definitions: definitionsOnce(draw),
    picture: async (alt, src, key, width) => {
      const picture = await docImage(io, src, path)
      if (picture?.png && Image) {
        const box = imageBox(picture.width, picture.height, width - 2, IMAGE_ROWS - 2)
        return {
          child: <Image key={key} source={{ png: picture.png }} {...box} alt={`${alt || 'image'} (this terminal cannot draw images)`} />,
          rows: box.rows,
        }
      }
      return {
        child: (
          <Markdown dimColor={isMenuOpen}
            key={key}
            text={picture ? `[open ${src}](${fileHref(picture.abs)})` : `*not found: ${src}*`}
            onLinkPress={link => void pressLink(io, link.href)}
          />
        ),
        rows: 1,
      }
    },
  }
  const props = current.props
  const problems = problemsFor(await draw.views(), { path, props: props ?? {} }).map(problemLine)
  if (problems.length) {
    blocks.drawnParts.push(
      <Box key="view-problems" flexDirection="column" width={textWidth}>
        {problems.map((line, i) => (
          <Text key={`view-problem-${i}`} color={C.red} wrap="truncate-end">{line}</Text>
        ))}
      </Box>,
    )
    blocks.note(problems.length)
  }
  const definition = props ? definitionIn(await draw.views(), { path, props }) : null
  if (!props || !definition) {
    await drawProse(ctx, io, blocks, 'body', source, options)
    return settleBlocks(ctx, io, blocks)
  }
  const name = typeof props.name === 'string' && props.name.trim() ? props.name : baseName(path).replace(/\.md$/i, '')
  const values = { ...props, name, id: typeof props.id === 'string' ? props.id : path }
  for (const [index, part] of fillTemplate(definition.template, values, { description: source, body: source }).entries()) {
    await drawProse(ctx, io, blocks, `page-${index}`, part.text, options)
  }
  return settleBlocks(ctx, io, blocks)
}

export async function tasksPageBody(ctx: DrawContext, io: NavIo, items: readonly Item[], shown: readonly Item[], draw: DrawData): Promise<ViewBody> {
  const { Text, C } = ctx
  const blocks = newBlocks()
  if (!items.length) {
    blocks.drawnParts.push(<Text key="no-tasks" color={C.overlay1}>{NO_TASKS}</Text>)
    blocks.note(1)
  } else {
    await drawProse(ctx, io, blocks, 'tasks', TASKS_PAGE, { picture: () => null, items: () => shown, definitions: definitionsOnce(draw) })
  }
  return settleBlocks(ctx, io, blocks)
}
