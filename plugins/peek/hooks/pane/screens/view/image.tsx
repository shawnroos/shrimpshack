import type { ElementConstructor, ImageProps } from 'claude-code'

import type { View } from '../../../../types'
import { imageBox } from '../../../measure'
import { FOOTER_ROWS, PAGE_TOP } from '../../chrome'
import type { DrawContext } from '../../types'
import { noJumps } from './blocks'
import type { ViewBody } from './blocks'

export function imageBody(ctx: DrawContext, Image: ElementConstructor<ImageProps>, current: View, image: NonNullable<View['image']>, png: string): ViewBody {
  const { textWidth } = ctx
  const body = (
    <Image
      key="picture"
      source={{ png }}
      {...imageBox(image.width, image.height, textWidth, Math.max(4, ctx.bodyRows - PAGE_TOP - FOOTER_ROWS - 2))}
      alt={`${current.title} (this terminal cannot draw images: press o to open it)`}
    />
  )
  return { body, jumps: noJumps(), position: '', layout: { blockStarts: [] } }
}
