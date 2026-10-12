import type { View } from '../../../../types'
import { describeAge } from '../../../format'
import { pixels } from '../../../images'
import { colorFor, iconFor } from '../../../kinds'
import { isWebUrl } from '../../../live'
import { linkify } from '../../../markdown'
import { chunkMarkdown, estimateRows, fitName } from '../../../measure'
import { openFromPage, pressLink, refContext } from '../../../navigation'
import type { NavIo } from '../../../navigation'
import { parseRef } from '../../../refs'
import { failureText } from '../../../sources'
import { ICON, META_ICON, mute } from '../../../theme'
import type { DrawContext, PictureBudget } from '../../types'
import { SectionRule, fitPicture } from '../../widgets'
import { DiagramEmbed, Embed, fullWidthOf, newBlocks, settleBlocks } from './blocks'
import type { ViewBody } from './blocks'
import { slackThread } from './slack'

const MAX_BLOCK_MEMO = 400
const blockMemo = new Map<string, { chunk: string; rows: number }[]>()

export function remoteBody(ctx: DrawContext, io: NavIo, current: View, remote: NonNullable<View['remote']>): ViewBody {
  const { Box, Text, Button, Markdown, Image, C, textWidth, isMenuOpen, now } = ctx
  const w = ctx
  const fullWidth = fullWidthOf(ctx)
  const record = remote.record
  const blocks = newBlocks()
  const { drawnParts, note } = blocks
  const sectionRule = (key: string, label: string, right = '') => {
    drawnParts.push(SectionRule(w, label.toUpperCase(), right, textWidth, key))
    note(1, label)
  }
  const kindColor = (kind: string) => (isMenuOpen ? mute(colorFor(kind)) : colorFor(kind))
  const budget: PictureBudget = { used: 0 }
  const ghRef = record?.kind.startsWith('gh-') ? parseRef(record.address) : null
  const refs = refContext(ghRef?.owner && ghRef.repo ? `${ghRef.owner}/${ghRef.repo}` : undefined)
  const memoBase = `${current.href}|${remote.fetchedAt}|${textWidth}|${refs.teamKeys?.length}|${refs.workspace}`
  const mediaBlock = (index: number, alt: string, url: string, heading: string) => {
    const key = `media-${index}`
    const one = record?.media?.[url]
    const picture = remote.pictures?.[url]
    const loadedPng = picture && pixels.get(picture.file)
    const png = fitPicture(budget, loadedPng)
    const host = (() => {
      try {
        return new URL(url).host
      } catch {
        return url
      }
    })()
    drawnParts.push(
      Embed(ctx, key, one?.play ? '\u{f03d}' : ICON.image, one?.play ? 'VIDEO' : 'IMAGE', alt || host, C.teal, (
        <Box flexDirection="column">
          {png && Image && picture ? (
            <Image key={`${key}-image`} source={{ png }} {...fullWidth(picture.width, picture.height)} alt={alt || 'image'} />
          ) : (
            !one?.play && <Markdown dimColor={isMenuOpen} key={`${key}-link`} text={`[open image](${url})`} onLinkPress={link => void pressLink(io, link.href)} />
          )}
          {one?.play && (
            <Button key={`media-play-${index}`} label="\u{f04b} Play video" plain onPress={() => void (isWebUrl(url) && io.run(['open', url]).catch(() => undefined))} />
          )}
        </Box>
      )),
    )
    note(png && picture ? fullWidth(picture.width, picture.height).rows + 4 : 4, heading)
  }
  let mediaCount = 0
  // Splits out picture lines and drawn diagrams; a fence's contents stay in the text around them.
  const markdownBlocks = (key: string, text: string, heading: string, indent = 0) => {
    if (!record?.media && !text.includes('```peek-diagram')) return markdownChunks(key, text, heading, indent)
    let pending = ''
    let segment = 0
    let fence = ''
    let diagram: { info: string; lines: string[] } | null = null
    const flush = () => {
      if (pending.trim()) markdownChunks(`${key}-${segment++}`, pending, heading, indent)
      pending = ''
    }
    for (const line of text.split('\n')) {
      if (diagram) {
        if (/^\s*```\s*$/.test(line)) {
          drawnParts.push(DiagramEmbed(ctx, `${key}-diagram-${segment++}`, diagram.info, diagram.lines.join('\n')))
          note(diagram.lines.length + 4, heading)
          diagram = null
        } else diagram.lines.push(line)
        continue
      }
      const marker = /^\s*(```|~~~)/.exec(line)?.[1]
      const drawn = !fence && /^```peek-diagram\s*(.*)$/.exec(line)
      if (drawn) {
        flush()
        diagram = { info: drawn[1] ?? '', lines: [] }
        continue
      }
      if (marker && (!fence || marker === fence)) fence = fence ? '' : marker
      const found = !fence && !marker && /^!\[([^\]]*)\]\(([^)\s]+)\)\s*$/.exec(line.trim())
      if (found && record?.media?.[found[2] ?? '']) {
        flush()
        mediaBlock(mediaCount++, found[1] ?? '', found[2] ?? '', heading)
      } else pending += `${line}\n`
    }
    if (diagram) pending += ['```text', ...diagram.lines, '```'].join('\n')
    flush()
  }
  const markdownChunks = (key: string, text: string, heading: string, indent = 0) => {
    const memoKey = `${memoBase}|${key}`
    let chunks = blockMemo.get(memoKey)
    if (!chunks) {
      if (blockMemo.size > MAX_BLOCK_MEMO) blockMemo.clear()
      chunks = chunkMarkdown(linkify(text, () => null, refs)).map(chunk => ({ chunk, rows: estimateRows(chunk, textWidth - indent) }))
      blockMemo.set(memoKey, chunks)
    }
    for (const [i, { chunk, rows }] of chunks.entries()) {
      drawnParts.push(
        <Box key={`${key}-${i}`} marginLeft={indent}>
          <Markdown dimColor={isMenuOpen} key={`${key}-md-${i}`} text={chunk} onLinkPress={link => void pressLink(io, link.href)} />
        </Box>,
      )
      note(rows, heading)
    }
  }
  if (!record) {
    const message = failureText(remote.failure ?? 'offline')
    drawnParts.push(
      <Box key="remote-failure" flexDirection="column">
        <Text color={C.red} bold>{message.title}</Text>
        {remote.failureDetail && <Text color={C.overlay1}>{remote.failureDetail}</Text>}
        <Text color={C.subtext0}>{message.hint}</Text>
        <Text color={C.overlay0}>Press o to open it in the browser.</Text>
      </Box>,
    )
    note(remote.failureDetail ? 4 : 3)
  } else {
    const faviconPng = remote.favicon && pixels.get(remote.favicon.file)
    const favicon = fitPicture(budget, faviconPng)
    drawnParts.push(
      <Box key="remote-title" flexDirection="row" width={textWidth}>
        {favicon && Image ? (
          <Box flexShrink={0} marginRight={1}>
            <Image key="remote-favicon" source={{ png: favicon }} columns={2} rows={1} alt={iconFor(record.kind)} />
          </Box>
        ) : (
          <Text color={kindColor(record.kind)}>{`${iconFor(record.kind)} `}</Text>
        )}
        <Box flexShrink={1}>
          <Text color={C.text} bold>{record.title}</Text>
        </Box>
      </Box>,
    )
    note(Math.ceil((record.title.length + 3) / textWidth), record.title)
    const labelWidth = Math.min(14, Math.max(0, ...record.meta.map(one => (META_ICON[one.label] ? 1 : one.label.length))) + 2)
    const previewPng = remote.preview && pixels.get(remote.preview.file)
    const preview = fitPicture(budget, previewPng)
    const previewBox = preview && Image && remote.preview ? fullWidth(remote.preview.width, remote.preview.height) : null
    const ogDescription = record.og?.description
    drawnParts.push(
      Embed(ctx, 'remote-meta', iconFor(record.kind), 'DETAILS', record.status ?? '', kindColor(record.kind), (
        <Box flexDirection="column">
          {previewBox && preview && Image && <Image key="remote-preview-image" source={{ png: preview }} {...previewBox} alt="preview image" />}
          {ogDescription && (
            <Box marginTop={previewBox ? 1 : 0} marginBottom={1}>
              <Text color={C.subtext0}>{ogDescription}</Text>
            </Box>
          )}
          {record.meta.map((one, i) => (
            <Text key={`meta-${i}`} wrap="truncate-end">
              <Text color={C.overlay0}>{(META_ICON[one.label] ?? one.label).padEnd(labelWidth)}</Text>
              <Text color={C.text}>{one.value}</Text>
            </Text>
          ))}
        </Box>
      )),
    )
    note(record.meta.length + 4 + (previewBox?.rows ?? 0) + (ogDescription ? estimateRows(ogDescription, textWidth - 2) + 1 : 0), 'Details')
    if (record.stats) {
      const ci = record.stats.ci
      const ciColor = { bad: C.red, wait: C.yellow, ok: C.green, none: C.overlay1 }[record.stats.ciTone]
      drawnParts.push(
        Embed(ctx, 'remote-stats', ICON['gh-pr'], 'CHANGES', `${record.stats.changedFiles} files`, C.green, (
          <Box flexDirection="column">
            <Text>
              <Text color={C.green}>{`+${record.stats.additions}`}</Text>
              <Text color={C.overlay0}>{'  '}</Text>
              <Text color={C.red}>{`−${record.stats.deletions}`}</Text>
              <Text color={C.overlay0}>{`  ·  ${record.stats.changedFiles} files changed`}</Text>
            </Text>
            <Text wrap="truncate-end">
              <Text color={C.overlay0}>{'CI  '}</Text>
              <Text color={ciColor}>{ci}</Text>
            </Text>
          </Box>
        )),
      )
      note(6, 'Changes')
    }
    const lists = () => {
      for (const [li, list] of (record.lists ?? []).entries()) {
        const more = list.total > list.items.length || list.isPartial
        sectionRule(`list-head-${li}`, list.heading, more ? `${list.items.length} of ${list.isPartial ? `${list.total}+` : list.total}` : `${list.total}`)
        drawnParts.push(
          <Box key={`list-${li}`} flexDirection="column" width={textWidth}>
            {list.items.length === 0 && <Text color={C.overlay0}>None open.</Text>}
            {list.items.map((item, i) => {
              const meta = [item.status, item.meta].filter(Boolean).join(' · ')
              return (
                <Box key={`list-${li}-${i}`} flexDirection="row" justifyContent="space-between" width={textWidth} height={1} hover={{ backgroundColor: C.surface0 }}>
                  <Box flexShrink={1} overflow="hidden" height={1}>
                    <Button key={`list-item-${li}-${i}`} label={fitName(item.title, Math.max(8, textWidth - meta.length - 2))} plain onPress={() => void openFromPage(io, item.href)} />
                  </Box>
                  <Box flexShrink={0}>
                    <Text color={C.overlay0}>{meta}</Text>
                  </Box>
                </Box>
              )
            })}
            {more && <Text color={C.overlay0}>{`showing ${list.items.length} of ${list.isPartial ? 'many' : list.total} · press o for the rest in the browser`}</Text>}
          </Box>,
        )
        note(Math.max(1, list.items.length) + (more ? 1 : 0), list.heading)
      }
    }
    const description = () => {
      if (!record.body?.trim()) return
      const label = record.kind === 'gh-repo' ? 'README' : record.kind === 'web' ? 'Page' : record.kind === 'slack-thread' ? 'Message' : 'Description'
      sectionRule('body-head', label)
      markdownBlocks('body', record.body, label)
    }
    const lead = record.kind === 'slack-thread' ? record.lead : undefined
    if (lead) {
      sectionRule('thread-head', 'Thread', record.status ?? '')
      slackThread({ ctx, io, remote, blocks, budget, refs }, lead, record.comments?.shown ?? [])
    } else if (record.kind === 'gh-repo' || record.kind === 'linear-issue') {
      lists()
      description()
    } else {
      description()
      lists()
    }
    const comments = lead ? undefined : record.comments
    if (comments && comments.total > 0) {
      const shown = comments.shown.length
      const count = shown < comments.total ? `showing latest ${shown} of ${comments.total}` : `${comments.total}`
      sectionRule('comments-head', 'Comments', comments.inline ? `${count} · ${comments.inline} inline` : count)
      for (const [i, one] of comments.shown.entries()) {
        const indent = (one.depth ?? 0) * 2
        const when = Number.isNaN(Date.parse(one.at)) ? one.at : describeAge(Date.parse(one.at), now)
        drawnParts.push(
          <Box key={`comment-${i}`} marginLeft={indent}>
            <Text wrap="truncate-end">
              <Text color={C.accent} bold>{one.author}</Text>
              <Text color={C.overlay0}>{` · ${when}${one.isReview ? ' · review' : ''}`}</Text>
            </Text>
          </Box>,
        )
        note(1, 'Comments')
        markdownBlocks(`comment-${i}-body`, one.body || '*(empty)*', 'Comments', indent)
      }
    }
  }
  return settleBlocks(ctx, io, blocks)
}
