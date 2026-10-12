import type { View } from '../../../../types'
import { setStar } from '../../../groups-session'
import { pixels } from '../../../images'
import { iconFor } from '../../../kinds'
import { liveStatusText } from '../../../live'
import { LINE_SCROLL_PX, LIVE_FRAME, liveBox, liveKey, liveSession, scrollLive, toggleLive } from '../../../live-pane'
import { goBack, nav, openExternally, refresh, sourceLine, starKeyOf, trailIcon } from '../../../navigation'
import { parseHref, shortPath } from '../../../paths'
import { itemKey, parseRef } from '../../../refs'
import { failureText } from '../../../sources'
import { ICON } from '../../../theme'
import { FOOTER_ROWS, HEADER_ROWS, PAGE_TOP } from '../../chrome'
import { modeKeys } from '../../keys'
import type { DrawContext, PaneActions, Screen } from '../../types'
import { noJumps } from './blocks'
import type { ViewBody } from './blocks'
import { codeBody } from './code'
import { dirBody } from './dir'
import { imageBody } from './image'
import { markdownBody } from './markdown'
import { remoteBody } from './remote'
import { tableBody } from './table'

export async function viewScreen(ctx: DrawContext, actions: PaneActions, current: View): Promise<Screen> {
  const { Box, Text, Image, Client, C, textWidth, pageWidth, isNarrow, offset, now, cwd, home } = ctx
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
  const folderPath = path.slice(0, Math.max(0, path.length - current.title.length - 1))
  const folder = current.root && folderPath.startsWith(current.root)
    ? folderPath.slice(current.root.length + 1)
    : shortPath(folderPath, cwd, home)

  let { body, jumps, position }: ViewBody = { body: null, jumps: noJumps(), position: '' }
  if (current.remote) ({ body, jumps, position } = remoteBody(ctx, io, current, current.remote))
  else if (current.markdown !== undefined) ({ body, jumps, position } = await markdownBody(ctx, io, current, current.markdown, path))
  else if (current.table) ({ body, jumps, position } = tableBody(ctx, io, current.table))
  else if (current.dir) ({ body, jumps, position } = dirBody(ctx, io, path, current.dir))
  else if (current.code) ({ body, jumps, position } = codeBody(ctx, io, current.code))
  else if (current.image && Image && png) ({ body, jumps, position } = imageBody(ctx, Image, current, current.image, png))
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
