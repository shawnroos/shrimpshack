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
import { remoteBody } from './remote'
import { DiagramEmbed, Embed, blockJumps, fullWidthOf, newBlocks, pictureRowsOf, settleBlocks } from './blocks'

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
    ;({ body, jumps, position } = remoteBody(ctx, io, current, current.remote))
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
