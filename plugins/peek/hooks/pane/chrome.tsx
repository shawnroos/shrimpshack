import type { RenderChildren } from 'claude-code'

import type { Mode } from '../../types'
import { groupMenuRows } from '../groups-session'
import { C as BASE } from '../theme'
import { MODES } from './actions'
import { Menu, menuRows, menuWidthOf } from './menu'
import type { MenuLists } from './menu'
import type { CrumbSegment } from '../crumbs'
import type { Action, Crumb, DrawContext, PaneActions, Screen } from './types'

export const HEADER_ROWS = 2
export const FOOTER_ROWS = 3
export const PAGE_TOP = HEADER_ROWS + 1
const NARROW = 60
const MIN_CPL = 30
const MAX_CPL = 104

export function geometryOf(bodyColumns: number) {
  const columns = Math.max(20, bodyColumns - 1)
  const isNarrow = bodyColumns < NARROW
  const textWidth = isNarrow ? columns : Math.min(MAX_CPL, Math.max(MIN_CPL, columns - 4))
  const pageWidth = columns
  return { columns, isNarrow, textWidth, pageWidth }
}

function chipOf(id: Mode, chosen: Mode, isTabCompact: boolean) {
  const one = MODES.find(each => each.id === id)
  if (!one) return ''
  return isTabCompact && id !== chosen ? ` ${one.icon} ` : ` ${one.icon} ${one.label.toUpperCase()} `
}

function fitCrumbs(parts: readonly Crumb[], geom: { columns: number; isNarrow: boolean; chosen: Mode }) {
  const { columns, isNarrow, chosen } = geom
  const width = (label: string) => label.length + 2
  const fullTabs = MODES.reduce((sum, one) => sum + ` ${one.icon} ${one.label} `.length, 0)
  const isTabCompact = !isNarrow && 2 + parts.reduce((sum, one) => sum + width(one.label), 0) > columns - fullTabs - 4
  const tabsWidth = MODES.reduce((sum, one) => sum + chipOf(one.id, chosen, isTabCompact).length, 0)
  const room = Math.max(8, isNarrow ? columns - 2 : columns - tabsWidth - 4)
  let spare = room - 2 - parts.reduce((sum, one) => sum + width(one.label), 0)
  const fitted = parts.map(one => ({ ...one }))
  for (const one of fitted) {
    if (spare >= 0 || !one.canShrink) continue
    const keep = Math.max(3, one.label.length + spare)
    const icon = one.label.slice(0, 2)
    const rest = one.label.slice(2)
    const tail = Math.max(1, keep - 3)
    one.label = rest.length > tail ? `${icon}…${rest.slice(rest.length - tail)}` : one.label
    spare = room - 2 - fitted.reduce((sum, item) => sum + width(item.label), 0)
  }
  for (const one of fitted) {
    if (spare >= 0) break
    const cut = Math.max(4, one.label.length + spare)
    if (cut < one.label.length) one.label = `${one.label.slice(0, cut - 1)}…`
    spare = room - 2 - fitted.reduce((sum, item) => sum + width(item.label), 0)
  }
  return { fitted, isTabCompact }
}

function crumbSegments(ctx: DrawContext, fitted: readonly Crumb[]) {
  const { C } = ctx
  const last = fitted.length - 1
  const segments: CrumbSegment[] = [{ text: '\u{e0b6}', fg: fitted[0]?.bg ?? C.surface0, bg: C.frame, crumb: 0, isEdge: true }]
  for (const [index, one] of fitted.entries()) {
    segments.push({ text: index === 0 ? `${one.label} ` : ` ${one.label}${index === last ? '' : ' '}`, fg: one.fg, bg: one.bg, crumb: index, ...(one.bold ? { bold: true } : {}) })
    segments.push(
      index === last
        ? { text: '\u{e0b4}', fg: one.bg, bg: C.frame, crumb: index, isEdge: true }
        : { text: '\u{e0bc}', fg: one.bg, bg: fitted[index + 1]?.bg ?? C.frame, crumb: index, isEdge: true },
    )
  }
  return segments
}

function Crumbs(ctx: DrawContext, fitted: readonly Crumb[]) {
  const { Box, Text, Client, C } = ctx
  const last = fitted.length - 1
  if (Client && fitted.some(one => one.press)) {
    const segments = crumbSegments(ctx, fitted)
    return (
      <Box flexDirection="row" flexShrink={1} height={1} overflow="hidden">
        <Client
          key="crumbs"
          module="../crumbs.tsx"
          props={{ segments, presses: fitted.map(one => one.press ?? null) }}
          width={segments.reduce((sum, one) => sum + [...one.text].length, 0)}
          height={1}
        />
      </Box>
    )
  }
  return (
    <Box flexDirection="row" flexShrink={1} height={1} overflow="hidden">
      <Text color={fitted[0]?.bg ?? C.surface0} backgroundColor={C.frame}>{'\u{e0b6}'}</Text>
      {fitted.map((one, index) => (
        <Box key={`crumb-${index}`} flexDirection="row" flexShrink={0}>
          <Text color={one.fg} backgroundColor={one.bg} bold={one.bold} wrap="truncate-end">{index === 0 ? `${one.label} ` : ` ${one.label}${index === last ? '' : ' '}`}</Text>
          {index === last ? (
            <Text color={one.bg} backgroundColor={C.frame}>{'\u{e0b4}'}</Text>
          ) : (
            <Text color={one.bg} backgroundColor={fitted[index + 1]?.bg ?? C.frame}>{'\u{e0bc}'}</Text>
          )}
        </Box>
      ))}
    </Box>
  )
}

function TabStrip(ctx: DrawContext, key: string, tabs: { id: Mode; label: string; isOn: boolean }[]) {
  const { Box, Text, Client, C } = ctx
  const chip = (label: string, isOn: boolean) => (
    <Text color={isOn ? C.appBg : C.overlay0} backgroundColor={isOn ? C.accent : C.panelBg} bold={isOn}>
      {label}
    </Text>
  )
  return Client ? (
    <Client
      key={key}
      module="../tabs.tsx"
      props={{ muted: ctx.isMenuOpen, tabs }}
      width={tabs.reduce((sum, tab) => sum + tab.label.length, 0)}
      height={1}
    />
  ) : (
    <Box flexDirection="row">{tabs.map(tab => chip(tab.label, tab.isOn))}</Box>
  )
}

function Header(ctx: DrawContext, middle: RenderChildren, isTabCompact: boolean) {
  const { Box, C, chosen } = ctx
  const strip = (isLeft: boolean) =>
    MODES.filter(one => (one.id === 'view') === isLeft).map(one => ({ id: one.id, label: chipOf(one.id, chosen, isTabCompact), isOn: chosen === one.id }))
  return ctx.isNarrow ? (
    <Box flexDirection="row" justifyContent="center" width={ctx.bodyColumns} height={1} overflow="hidden" backgroundColor={C.frame}>
      {middle}
    </Box>
  ) : (
    <Box flexDirection="row" justifyContent="space-between" width={ctx.bodyColumns} height={1} overflow="hidden" backgroundColor={C.frame}>
      {TabStrip(ctx, 'tabs-left', strip(true))}
      {middle}
      {TabStrip(ctx, 'tabs-right', strip(false))}
    </Box>
  )
}

function Footer(ctx: DrawContext, info: string, footer: readonly Action[]) {
  const { Box, Text, Button, C } = ctx
  return (
    <Box flexDirection="row" flexWrap="wrap" columnGap={2} justifyContent="center" width={ctx.columns}>
      {info && <Text color={C.overlay1}>{info}</Text>}
      {!ctx.isNarrow && info && <Text color={C.surface1}>│</Text>}
      <Text color={C.accent}>⌃k menu</Text>
      {/* Hidden, yet the hotkeys still press: the Pane arms every Button in its drawn tree regardless of display (seen in engine 2.1.295, not promised by the types). Tab still visits them. */}
      <Box key="footer-keys" display="none">
        {footer.flatMap(one => (one.hotkey ? [<Button key={one.id} label={one.label} hotkey={one.hotkey} plain onPress={() => void one.run()} />] : []))}
      </Box>
    </Box>
  )
}

export async function frame(ctx: DrawContext, actions: PaneActions, lists: MenuLists, screen: Screen) {
  const { Box, C, offset, bodyColumns, bodyRows } = ctx
  const { fitted, isTabCompact } = fitCrumbs(screen.crumbs, ctx)
  const middle = Crumbs(ctx, fitted)
  // A group home that cannot resolve leaves the menu without group rows rather than failing the whole pane.
  const groupMenu = ctx.isMenuOpen ? await groupMenuRows(actions.io, screen.menuOn ?? {}).catch(() => []) : []
  const menuWidth = menuWidthOf(ctx.columns)
  return (
    <Box
      flexDirection="column"
      alignItems="center"
      backgroundColor={C.appBg}
      minHeight={bodyRows}
      width={bodyColumns}
    >
      <Box height={HEADER_ROWS} />
      <Box flexDirection="column" alignSelf="flex-start" alignItems="center" width={ctx.pageWidth} backgroundColor={screen.pageBg ?? C.panelBg} paddingX={ctx.isNarrow ? 0 : 2} paddingY={1}>
        <Box flexDirection="column" width={ctx.textWidth}>
          {screen.content}
        </Box>
      </Box>
      <Box height={FOOTER_ROWS} />
      <Box
        position="absolute"
        top={offset}
        left={0}
        width={bodyColumns}
        height={HEADER_ROWS}
        flexDirection="column"
        alignItems="center"
        backgroundColor={C.appBg}
      >
        {Header(ctx, middle, isTabCompact)}
      </Box>
      <Box
        position="absolute"
        top={offset + bodyRows - FOOTER_ROWS}
        left={0}
        width={bodyColumns}
        height={FOOTER_ROWS}
        flexDirection="column"
        alignItems="center"
        justifyContent="flex-end"
        backgroundColor={C.appBg}
      >
        {Footer(ctx, screen.info, screen.actions)}
      </Box>
      {ctx.isMenuOpen && (
        <Box
          position="absolute"
          top={offset + HEADER_ROWS + 2}
          left={Math.max(0, Math.floor((bodyColumns - menuWidth - 4) / 2))}
          width={menuWidth + 4}
          flexDirection="column"
          backgroundColor={BASE.panelBg}
          paddingX={2}
          paddingY={1}
        >
          {Menu(ctx, actions, menuRows(lists, screen.actions, groupMenu), screen.actions)}
        </Box>
      )}
    </Box>
  )
}
