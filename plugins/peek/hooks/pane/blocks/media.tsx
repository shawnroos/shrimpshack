import type { View } from '../../../types'
import { pixels } from '../../images'
import { isWebUrl } from '../../live'
import { imageBox } from '../../measure'
import { pressLink } from '../../navigation'
import type { NavIo } from '../../navigation'
import { pictureRowsOf } from '../screens/view/blocks'
import { drawProse } from '../screens/view/prose'
import type { ProseOptions } from '../screens/view/prose'
import type { DrawContext, PictureBudget } from '../types'
import { fitPicture } from '../widgets'
import { fieldOf, sectionRule } from './header'
import type { RecordEnv } from './header'

// One per page draw: the media keys count up across the body and every comment.
export function recordPictures(ctx: DrawContext, io: NavIo, remote: NonNullable<View['remote']>, budget: PictureBudget): ProseOptions['picture'] {
  const { Box, Button, Markdown, Image, isMenuOpen } = ctx
  const record = remote.record
  let mediaCount = 0
  return (alt, url, _key, width) => {
    const one = record?.media?.[url]
    if (!one) return null
    const index = mediaCount++
    const key = `media-${index}`
    const shot = remote.pictures?.[url]
    const png = fitPicture(budget, shot && pixels.get(shot.file))
    const box = png && Image && shot ? imageBox(shot.width, shot.height, width, pictureRowsOf(ctx)) : null
    return {
      isVideo: Boolean(one.play),
      rows: (box?.rows ?? 1) + (one.play ? 1 : 0),
      child: (
        <Box flexDirection="column">
          {box && png && Image ? (
            <Image key={`${key}-image`} source={{ png }} {...box} alt={alt || 'image'} />
          ) : (
            !one.play && <Markdown dimColor={isMenuOpen} key={`${key}-link`} text={`[open image](${url})`} onLinkPress={link => void pressLink(io, link.href)} />
          )}
          {one.play && (
            <Button key={`media-play-${index}`} label="\u{f04b} Play video" plain onPress={() => void (isWebUrl(url) && io.run(['open', url]).catch(() => undefined))} />
          )}
        </Box>
      ),
    }
  }
}

export async function drawMedia(env: RecordEnv, options: Record<string, string>) {
  const from = options.from ?? ''
  const text = fieldOf(env.record, from)
  if (typeof text !== 'string' || !text.trim()) return
  const title = options.title ?? from
  sectionRule(env, `${from}-head`, title)
  await drawProse(env.ctx, env.io, env.blocks, from, env.linked(text), { picture: env.picture, heading: title, navStart: env.navBase + env.blocks.nav.length })
}
