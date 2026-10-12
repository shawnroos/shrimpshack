import type { RemoteComment, View } from '../../../../types'
import { describeAge, describeSize } from '../../../format'
import { docImage, pixels } from '../../../images'
import { colorFor, iconFor } from '../../../kinds'
import { isWebUrl, liveStatusText } from '../../../live'
import { LINE_SCROLL_PX, LIVE_FRAME, liveBox, liveKey, liveSession, scrollLive, toggleLive } from '../../../live-pane'
import { diagramType, linkify, plainInline, segmentsOf } from '../../../markdown'
import { IMAGE_ROWS, chunkMarkdown, estimateRows, fitName, imageBox, taskRows } from '../../../measure'
import { fullText } from '../../../loaders'
import { goBack, nav, openExternally, openFromPage, pressLink, refContext, refresh, sourceLine, starKeyOf, trailIcon } from '../../../navigation'
import { fileHref, kindOf, parseHref, shortPath } from '../../../paths'
import { itemKey, parseRef } from '../../../refs'
import { initials, whenLabel } from '../../../slack'
import { failureText } from '../../../sources'
import { setStar } from '../../../groups-session'
import { columnWidths, fitCell } from '../../../tabular'
import { ICON, META_ICON, mute, speakerColor } from '../../../theme'
import { FOOTER_ROWS, HEADER_ROWS, PAGE_TOP } from '../../chrome'
import { modeKeys } from '../../keys'
import { LIST_CHUNK, layout } from '../../layout'
import type { DrawContext, PaneActions, PictureBudget, Screen } from '../../types'
import { SectionRule, fitPicture } from '../../widgets'
import { DiagramEmbed, Embed, blockJumps, fullWidthOf, newBlocks, pictureRowsOf, settleBlocks } from './blocks'

const MAX_BLOCK_MEMO = 400
const blockMemo = new Map<string, { chunk: string; rows: number }[]>()

export async function viewScreen(ctx: DrawContext, actions: PaneActions, current: View): Promise<Screen> {
  const { Box, Text, Button, Markdown, Code, Image, Client, C, textWidth, pageWidth, isNarrow, isMenuOpen, offset, now, cwd, home } = ctx
  const w = ctx
  const io = actions.io
  let png = current.image ? pixels.get(current.image.file) : undefined
  if (current.image && !png) {
    png = await io.readBytes(current.image.file).then(
      bytes => bytes.base64,
      () => undefined,
    )
    if (png) pixels.set(current.image.file, png)
  }
  const kind = current.kind
  const path = parseHref(current.href)?.path ?? current.href
  const pictureRows = pictureRowsOf(ctx)
  const fullWidth = fullWidthOf(ctx)
  const folderPath = path.slice(0, Math.max(0, path.length - current.title.length - 1))
  const folder = current.root && folderPath.startsWith(current.root)
    ? folderPath.slice(current.root.length + 1)
    : shortPath(folderPath, cwd, home)

  let body: unknown = null
  let position = ''
  let jumps: { next: () => void; prev: () => void } = { next: () => {}, prev: () => {} }
  if (current.remote) {
    const remote = current.remote
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
      const openInSlack = (href: string | undefined) => void (href && isWebUrl(href) && io.run(['open', href]).catch(() => undefined))
      const slackFiles = (key: string, one: RemoteComment, width: number) => {
        const rows: unknown[] = []
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
      const slackMessage = (index: number, one: RemoteComment, isReply: boolean) => {
        const key = `slack-msg-${index}`
        const width = textWidth - (isReply ? 4 : 0)
        const color = isMenuOpen ? mute(speakerColor(one.authorId ?? one.author)) : speakerColor(one.authorId ?? one.author)
        const avatar = one.authorId ? remote.avatars?.[one.authorId] : undefined
        const avatarPng = avatar && pixels.get(avatar.file)
        const face = Image ? fitPicture(budget, avatarPng) : undefined
        const when = whenLabel(one.at, now)
        const bodyParts: unknown[] = []
        let bodyRows = 0
        let pending: string[] = []
        const flush = () => {
          const chunk = pending.join('\n')
          pending = []
          if (!chunk.trim()) return
          bodyParts.push(<Markdown dimColor={isMenuOpen} key={`${key}-md-${bodyParts.length}`} text={chunk} onLinkPress={link => void pressLink(io, link.href)} />)
          bodyRows += estimateRows(chunk, width)
        }
        for (const line of linkify(one.body || '*(empty)*', () => null, refs).split('\n')) {
          const found = /^\s*!\[([^\]]*)\]\(([^)\s]+)\)\s*$/.exec(line)
          if (!found) {
            pending.push(line)
            continue
          }
          const [, alt = '', url = ''] = found
          const picture = remote.pictures?.[url]
          const loaded = picture && pixels.get(picture.file)
          const png = Image ? fitPicture(budget, loaded) : undefined
          if (!png || !picture || !Image) {
            pending.push(`[${alt || 'open image'}](${url})`)
            continue
          }
          flush()
          const box = imageBox(picture.width, picture.height, width, pictureRows)
          bodyParts.push(<Image key={`${key}-picture-${bodyParts.length}`} source={{ png }} {...box} alt={alt || 'image'} />)
          bodyRows += box.rows
        }
        flush()
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
            {bodyParts as never}
            {files.rows as never}
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
      const lead = record.kind === 'slack-thread' ? record.lead : undefined
      if (lead) {
        sectionRule('thread-head', 'Thread', record.status ?? '')
        slackMessage(0, lead, false)
        for (const [i, one] of (record.comments?.shown ?? []).entries()) slackMessage(i + 1, one, true)
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
    ;({ body, jumps, position } = settleBlocks(ctx, io, blocks))
  } else if (current.markdown !== undefined) {
    const source = fullText.get(current.href) ?? current.markdown
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
    ;({ body, jumps, position } = settleBlocks(ctx, io, blocks))
  } else if (current.table) {
    const table = current.table
    const widths = columnWidths([table.header, ...table.rows], textWidth)
    const line = (row: readonly string[]) => widths.map((w, c) => fitCell(row[c] ?? '', w)).join('  ')
    const chunks = Array.from({ length: Math.ceil(table.rows.length / LIST_CHUNK) }, (_, i) =>
      table.rows.slice(i * LIST_CHUNK, i * LIST_CHUNK + LIST_CHUNK),
    )
    layout.blockStarts = chunks.map((_, i) => 2 + i * LIST_CHUNK)
    layout.estimatedRows = Math.max(1, 2 + table.rows.length)
    body = (
      <Box flexDirection="column" width={textWidth}>
        <Text color={C.accent} bold wrap="truncate-end">{line(table.header)}</Text>
        <Text color={C.surface1} wrap="truncate-end">{widths.map(w => '─'.repeat(w)).join('  ')}</Text>
        {chunks.map((chunk, i) => (
          <Box key={`chunk-${i}`} flexDirection="column">
            {chunk.map((row, r) => (
              <Text
                key={`table-row-${i * LIST_CHUNK + r}`}
                color={C.text}
                backgroundColor={(i * LIST_CHUNK + r) % 2 ? C.cardBg : undefined}
                wrap="truncate-end"
              >
                {line(row)}
              </Text>
            ))}
          </Box>
        ))}
        {table.total > table.rows.length && (
          <Text color={C.overlay0}>{`… ${table.total - table.rows.length} more rows. Press o to open the whole file.`}</Text>
        )}
      </Box>
    )
    jumps = blockJumps(ctx, io, chunks.length, 'chunk')
    const first = Math.max(1, Math.min(table.rows.length, offset - PAGE_TOP - 1))
    position = `row ${first} of ${table.total}`
  } else if (current.dir) {
    const folderPath = path
    const parent = folderPath.slice(0, Math.max(1, folderPath.lastIndexOf('/')))
    const items = [
      ...(folderPath !== '/' ? [{ href: fileHref(parent), icon: ICON.up, color: C.overlay1, name: '..', folder: '', meta: 'up', canStar: false }] : []),
      ...current.dir.map(one => {
        const kindOfEntry = one.isDir ? 'folder' : kindOf(one.name)
        return {
          href: fileHref(`${folderPath}/${one.name}`),
          icon: iconFor(kindOfEntry),
          color: colorFor(kindOfEntry),
          name: one.isDir ? `${one.name}/` : one.name,
          folder: '',
          meta: one.isDir ? describeAge(one.mtimeMs, now) : `${describeSize(one.size)} · ${describeAge(one.mtimeMs, now)}`,
        }
      }),
    ]
    const chunks = Array.from({ length: Math.ceil(items.length / LIST_CHUNK) }, (_, i) =>
      items.slice(i * LIST_CHUNK, i * LIST_CHUNK + LIST_CHUNK),
    )
    layout.blockStarts = chunks.map((_, i) => i * LIST_CHUNK)
    layout.estimatedRows = Math.max(1, items.length)
    body = (
      <Box flexDirection="column" width={textWidth}>
        {items.length === 0 && <Text color={C.overlay0}>Empty folder.</Text>}
        {Client &&
          chunks.map((chunk, i) => (
            <Client
              key={`rows-${i}`}
              module="../../../rows.tsx"
              props={{ muted: isMenuOpen, width: textWidth, rows: chunk }}
              width={textWidth}
              height={chunk.length}
            />
          ))}
      </Box>
    )
    jumps = blockJumps(ctx, io, chunks.length, 'rows')
  } else if (current.code) {
    const code = current.code
    const lines = code.source.split('\n')
    const chunk = 10
    const chunks = Array.from({ length: Math.ceil(lines.length / chunk) }, (_, i) => lines.slice(i * chunk, i * chunk + chunk))
    layout.blockStarts = chunks.map((_, i) => i * chunk)
    layout.estimatedRows = Math.max(1, lines.length)
    body = (
      <Box flexDirection="column" width={textWidth}>
        {chunks.map((part, i) => (
          <Box key={`chunk-${i}`} flexDirection="column">
            {isMenuOpen ? (
              <Text color={C.overlay1}>{part.join('\n') || ' '}</Text>
            ) : (
              <Code
                source={part.join('\n') || ' '}
                language={code.language}
                startLine={code.startLine + i * chunk}
                wrap="truncate-end"
              />
            )}
          </Box>
        ))}
      </Box>
    )
    jumps = blockJumps(ctx, io, chunks.length, 'chunk')
    const firstLine = code.startLine + Math.max(0, Math.min(lines.length - 1, offset))
    position = `line ${firstLine} of ${code.startLine + lines.length - 1}`
  } else if (current.image && Image && png) {
    layout.blockStarts = []
    body = (
      <Image
        key="picture"
        source={{ png }}
        {...imageBox(current.image.width, current.image.height, textWidth, Math.max(4, ctx.bodyRows - PAGE_TOP - FOOTER_ROWS - 2))}
        alt={`${current.title} (this terminal cannot draw images: press o to open it)`}
      />
    )
  }
  const liveState = liveSession.live?.state()
  const canLive = ctx.surface === 'terminal' && Boolean(Image) && current.remote !== undefined && parseRef(current.href)?.kind === 'web'
  const liveRows = Math.max(4, ctx.bodyRows - PAGE_TOP - FOOTER_ROWS - 2)
  const viewport = liveBox(textWidth, liveRows)
  const isLiveHere = canLive && liveSession.href === current.href && liveState !== undefined && liveState.phase !== 'off'
  const liveFrame = isLiveHere ? liveState.frame : undefined
  if (liveFrame && Image) {
    liveSession.isFrameDrawn = true
    if (liveSession.viewport && (liveSession.viewport.width !== viewport.width || liveSession.viewport.height !== viewport.height)) {
      liveSession.viewport = viewport
      void liveSession.live?.command('resize', viewport)
    }
    liveSession.geom = { left: Math.floor((ctx.bodyColumns - pageWidth) / 2) + (isNarrow ? 0 : 2), top: HEADER_ROWS + 1 - offset, columns: textWidth, rows: liveRows }
    body = (
      <Box width={textWidth} height={liveRows}>
        <Image
          key={LIVE_FRAME}
          source={{ file: liveFrame.path, format: 'png', generation: liveFrame.id }}
          columns={textWidth}
          rows={liveRows}
          alt={`${current.title} (the live view cannot draw here: press v for the reader page)`}
        />
        {Client && (
          <Box position="absolute" top={0} left={0} width={textWidth} height={liveRows}>
            <Client key="live-input" module="../../../live-input.tsx" props={{ width: textWidth, height: liveRows, acked: liveSession.lastInputSeq }} width={textWidth} height={liveRows} />
          </Box>
        )}
      </Box>
    )
    position = ''
  }
  const liveStatus = isLiveHere ? liveStatusText(liveState, current.location) : ''
  const notice = liveSession.notice?.href === current.href ? failureText(liveSession.notice.kind) : null
  const goNext = jumps.next
  const goPrev = jumps.prev
  const starTarget = (liveFrame && liveState?.url) || current.href
  const isStarred = (await io.stars.read()).some(one => starKeyOf(one) === itemKey(starTarget))
  const remote = current.remote
  const source = remote?.record ? sourceLine(remote, now) : ''
  const info = liveFrame
    ? [isStarred ? '\u{f51a} starred' : '', liveStatus].filter(Boolean).join(' · ')
    : [liveStatus, isStarred ? '\u{f51a} starred' : '', source, position, current.summary, current.tasks].filter(Boolean).join(' · ')
  const remoteCrumbs = remote
    ? [
        ...(remote.record?.trail ?? []).map((label, index, all) => ({
          label: `${trailIcon(current.kind ?? 'web', index, all.length)} ${label}`,
          fg: C.subtext0 as string,
          bg: C.surface1 as string,
          canShrink: true,
        })),
        { label: `${iconFor(current.kind)} ${liveFrame && liveState?.title ? liveState.title : current.title}`, fg: C.appBg, bg: C.accent, bold: true },
      ]
    : null

  return {
    crumbs: remoteCrumbs ?? [
            ...(current.root
              ? [
                  {
                    label: `${current.isWorktree ? ICON.worktree : ICON.repo} ${current.root.split('/').pop() ?? ''}`,
                    fg: C.overlay1 as string,
                    bg: C.surface0 as string,
                  },
                ]
              : []),
            ...(folder ? [{ label: `${ICON.folder} ${folder}`, fg: C.subtext0 as string, bg: C.surface1 as string, canShrink: true }] : []),
            { label: `${iconFor(kind)} ${current.title}`, fg: C.appBg, bg: C.accent, bold: true },
          ],
    content: (
      <Box flexDirection="column" width={textWidth}>
        {current.error && <Text color={C.red}>{current.error}</Text>}
        {notice && (
          <Box key="live-notice" flexDirection="column" marginBottom={1}>
            <Text color={C.red} bold>{notice.title}</Text>
            <Text color={C.subtext0}>{notice.hint}</Text>
          </Box>
        )}
        {body as never}
      </Box>
    ),
    info,
    keys: [
        ...modeKeys(actions),
        ...(canLive
          ? [{ key: 'live', label: liveSession.href === current.href ? 'Reader' : 'Live', hotkey: 'v', onPress: () => void toggleLive(io, current, viewport) }]
          : []),
        ...(liveFrame && liveSession.isTyping
          ? [{ key: 'done-typing', label: 'Done typing', hotkey: 'd', menu: 'Done typing: give the keys back to peek', onPress: () => { liveSession.isTyping = false; io.invalidate() } }]
          : []),
        { key: 'next', label: 'Down', hotkey: 'j', onPress: liveFrame ? () => scrollLive(LINE_SCROLL_PX) : goNext },
        { key: 'prev', label: 'Up', hotkey: 'k', onPress: liveFrame ? () => scrollLive(-LINE_SCROLL_PX) : goPrev },
        { key: 'star', label: isStarred ? 'Unstar' : 'Star', hotkey: 'f', onPress: liveFrame ? () => void liveKey(io, 'f') : () => void setStar(io, current.href) },
        { key: 'open', label: remote ? 'Open in browser' : 'Open', hotkey: 'o', onPress: liveFrame ? () => void liveKey(io, 'o') : () => void openExternally(io, current) },
        ...(remote ? [{ key: 'refresh', label: liveFrame ? 'Reload' : 'Refresh', hotkey: 'u', onPress: liveFrame ? () => void liveKey(io, 'u') : () => void refresh(io, current.href) }] : []),
        ...(liveFrame || nav.backStack.length || nav.groupBack
          ? [{ key: 'back', label: 'Back', hotkey: 'b', menu: liveFrame ? undefined : nav.groupBack && nav.backStack.length <= nav.groupBack.depth ? `Back to ${nav.groupBack.title}` : 'Back to the previous page', onPress: liveFrame ? () => void liveKey(io, 'b') : () => void goBack(io) }]
          : []),
        {
          key: 'copy',
          label: remote ? 'Copy link' : 'Copy path',
          hotkey: 'c',
          onPress: liveFrame ? () => void liveKey(io, 'c') : () => void io.copy({ text: current.location }),
        },
        { key: 'close', label: 'Close', hotkey: 'x', onPress: () => void actions.close() },
    ].map(one => (liveSession.isTyping ? { ...one, onPress: () => { liveSession.isTyping = false; one.onPress() } } : one)),
    menuOn: { target: current.error || (remote?.failure && !remote.record) || isLiveHere ? undefined : current.href },
  }
}
