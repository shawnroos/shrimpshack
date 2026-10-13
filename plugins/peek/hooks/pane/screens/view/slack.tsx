import type { RenderChildren } from 'claude-code'

import type { RemoteComment, View } from '../../../../types'
import { pixels } from '../../../images'
import { isWebUrl } from '../../../live'
import { imageBox } from '../../../measure'
import type { NavIo } from '../../../navigation'
import { initials, whenLabel } from '../../../format'
import { ICON, mute, speakerColor } from '../../../theme'
import type { DrawContext, PictureBudget } from '../../types'
import { fitPicture } from '../../widgets'
import { pictureRowsOf } from './blocks'
import type { Blocks } from './blocks'
import { proseParts } from './prose'
import type { ProseOptions } from './prose'

export type RemotePage = { ctx: DrawContext; io: NavIo; remote: NonNullable<View['remote']>; blocks: Blocks; budget: PictureBudget; linked: (text: string) => string }

// Draws into the page's blocks in order, spending the page's one picture budget after the favicon and preview.
export async function slackThread(page: RemotePage, lead: RemoteComment, replies: readonly RemoteComment[]) {
  const { ctx, io, remote, blocks, budget, linked } = page
  const { Box, Text, Button, Markdown, Image, C, textWidth, isMenuOpen, now } = ctx
  const { drawnParts, note } = blocks
  const pictureRows = pictureRowsOf(ctx)
  const openInSlack = (href: string | undefined) => void (href && isWebUrl(href) && io.run(['open', href]).catch(() => undefined))
  const slackFiles = (key: string, one: RemoteComment, width: number) => {
    const rows: RenderChildren[] = []
    let height = 0
    for (const [fi, file] of (one.files ?? []).entries()) {
      const picture = remote.pictures?.[`slack-file:${file.id}`]
      const loaded = picture && pixels.get(picture.file)
      const png = Image ? fitPicture(budget, loaded) : undefined
      if (png && picture && Image) {
        const box = imageBox(picture.width, picture.height, width, pictureRows)
        rows.push(<Image key={`${key}-${fi}`} source={{ png }} {...box} alt={file.name} />)
        height += box.rows
        continue
      }
      rows.push(
        <Box key={`${key}-${fi}`} flexDirection="row" width={width}>
          <Text color={C.teal}>{`${file.type.startsWith('image/') ? ICON.image : ICON.file} `}</Text>
          <Box flexShrink={1}>
            <Text color={C.subtext0} wrap="truncate-end">{[file.name, file.type, file.size].filter(Boolean).join(' · ')}</Text>
          </Box>
          {one.href && (
            <Box flexShrink={0} marginLeft={2}>
              <Markdown dimColor={isMenuOpen} key={`${key}-${fi}-open`} text={`[open in Slack](${one.href})`} onLinkPress={link => openInSlack(link.href)} />
            </Box>
          )}
        </Box>,
      )
      height += 1
    }
    return { rows, height }
  }
  const slackMessage = async (index: number, one: RemoteComment, isReply: boolean) => {
    const key = `slack-msg-${index}`
    const width = textWidth - (isReply ? 4 : 0)
    const color = isMenuOpen ? mute(speakerColor(one.authorId ?? one.author)) : speakerColor(one.authorId ?? one.author)
    const avatar = one.authorId ? remote.avatars?.[one.authorId] : undefined
    const avatarPng = avatar && pixels.get(avatar.file)
    const face = Image ? fitPicture(budget, avatarPng) : undefined
    const when = whenLabel(one.at, now)
    const picture: ProseOptions['picture'] = (alt, url, pictureKey, pictureWidth) => {
      const shot = remote.pictures?.[url]
      const png = Image ? fitPicture(budget, shot && pixels.get(shot.file)) : undefined
      if (!png || !shot || !Image) return null
      const box = imageBox(shot.width, shot.height, pictureWidth, pictureRows)
      return { child: <Image key={pictureKey} source={{ png }} {...box} alt={alt || 'image'} />, rows: box.rows }
    }
    const parts = await proseParts({ ...ctx, textWidth: width }, io, `${key}-body`, linked(one.body || '*(empty)*'), { picture })
    const bodyParts = parts.map(part => part.node)
    const bodyRows = parts.reduce((sum, part) => sum + part.rows, 0) + Math.max(0, parts.length - 1)
    const files = slackFiles(`slack-file-${index}`, one, width)
    const rows = 2 + bodyRows + files.height
    const content = (
      <Box flexDirection="column" width={width}>
        <Box flexDirection="row" height={2}>
          <Box flexShrink={0} width={4} marginRight={1}>
            {face && Image ? (
              <Image key={`slack-avatar-${index}`} source={{ png: face }} columns={4} rows={2} alt={one.author} />
            ) : (
              <Text backgroundColor={color} color={C.appBg} bold>{` ${initials(one.author)} `}</Text>
            )}
          </Box>
          <Box flexDirection="column" flexShrink={1}>
            <Text color={color} bold wrap="truncate-end">{one.author}</Text>
            {one.href ? <Button key={`slack-time-${index}`} label={when} plain onPress={() => openInSlack(one.href)} /> : <Text color={C.overlay0}>{when}</Text>}
          </Box>
        </Box>
        <Box flexDirection="column" gap={1}>{bodyParts}</Box>
        {files.rows}
      </Box>
    )
    drawnParts.push(
      isReply ? (
        <Box key={key} flexDirection="row" marginLeft={1}>
          <Box flexShrink={0} width={3}>
            <Text color={C.surface1}>{Array.from({ length: rows }, () => '│').join('\n')}</Text>
          </Box>
          {content}
        </Box>
      ) : (
        <Box key={key}>{content}</Box>
      ),
    )
    note(rows, 'Thread')
  }
  await slackMessage(0, lead, false)
  for (const [i, one] of replies.entries()) await slackMessage(i + 1, one, true)
}
