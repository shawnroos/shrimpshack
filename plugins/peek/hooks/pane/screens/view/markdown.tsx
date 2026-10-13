import type { View } from '../../../../types'
import { docImage } from '../../../images'
import { IMAGE_ROWS, imageBox } from '../../../measure'
import { fullText } from '../../../loaders'
import { pressLink } from '../../../navigation'
import type { NavIo } from '../../../navigation'
import { fileHref } from '../../../paths'
import type { DrawContext } from '../../types'
import { newBlocks, settleBlocks } from './blocks'
import type { ViewBody } from './blocks'
import { drawProse } from './prose'

export async function markdownBody(ctx: DrawContext, io: NavIo, current: View, markdown: string, path: string): Promise<ViewBody> {
  const { Image, Markdown, isMenuOpen } = ctx
  const source = fullText.get(current.href) ?? markdown
  const blocks = newBlocks()
  await drawProse(ctx, io, blocks, 'body', source, {
    canTickTasks: true,
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
  })
  return settleBlocks(ctx, io, blocks)
}
