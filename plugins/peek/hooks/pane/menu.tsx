import { describeAge } from '../format'
import { setStar } from '../groups-session'
import { iconFor } from '../kinds'
import { liveKey, liveSession, toggleLive } from '../live-pane'
import { openExternally, refresh, setMenu, show } from '../navigation'
import { baseName, kindOf, parseHref } from '../paths'
import { C as BASE, ICON } from '../theme'
import { MOVE_KEYS, modeRows, openTasksPage, pageCaps, roleRows, scopeRows } from './actions'
import { rankCommands } from './rank'
import { canGoLive } from './look'
import { TASKS_ICON } from './task-data'
import type { Action, DrawContext, PaneActions } from './types'

const KEY_ICON = '\u{f11c}'

export const menuWidthOf = (columns: number) => Math.max(24, Math.min(64, columns - 8))

// The screen's own rows and the group rows go between these two lists.
export type MenuLists = { lead: Action[]; tail: Action[] }

// Built when the draw starts: the live labels read the live session before anything the draw awaits can change it.
export function menuLists(ctx: DrawContext, actions: PaneActions): MenuLists {
  const { current, list, now } = ctx
  const io = actions.io
  const caps = current ? pageCaps(current) : undefined
  return {
    lead: [
      ...modeRows(io, Boolean(current)),
      ...roleRows(actions),
      ...scopeRows(actions),
      // Typed for, not listed: an always-on row would push the last row past the menu's 20-row cap.
      { id: 'tasks', icon: TASKS_ICON, label: 'Tasks: every task, by now, next and later', isFilteredOnly: true, run: () => void openTasksPage(io) },
      { id: 'top', icon: '\u{f062}', label: 'Scroll to top', hint: 'home', run: () => void io.scroll({ to: 'start' }).catch(() => undefined) },
      { id: 'bottom', icon: '\u{f063}', label: 'Scroll to bottom', hint: 'end', run: () => void io.scroll({ to: 'end' }).catch(() => undefined) },
      ...(current
        ? [
            { id: 'open', icon: '\u{f08e}', label: 'Open in its own app', hintFrom: 'open', run: () => void openExternally(io, current) },
            ...(caps?.canRefresh
              ? [{ id: 'refresh', icon: '\u{f021}', label: 'Refresh this page', hintFrom: 'refresh', run: () => void refresh(io, current.href) }]
              : []),
            ...(canGoLive(ctx, current)
              ? [{ id: 'live', icon: '\u{f0ac}', label: liveSession.href === current.href ? 'Reader view: leave the live page' : 'Live view: the real page, clickable', hintFrom: 'live', run: () => void toggleLive(io, current, liveSession.viewport ?? { width: 600, height: 400 }) }]
              : []),
            ...(liveSession.href === current.href && liveSession.live?.state().canBack
              ? [{ id: 'live-back', icon: '\u{f060}', label: 'Back in the live page', hintFrom: 'back', run: () => void liveKey(io, 'b') }]
              : []),
            { id: 'copy', icon: '\u{f0c5}', label: caps?.copyLabel ?? 'Copy path', hintFrom: 'copy', run: () => void io.copy({ text: current.location }) },
            ...(caps?.canStar ? [{ id: 'star', icon: ICON.star, label: 'Star or unstar this file', hintFrom: 'star', run: () => void setStar(io, current.href) }] : []),
          ]
        : []),
    ],
    tail: [
      { id: 'close', icon: '\u{f00d}', label: 'Close the pane', hintFrom: 'close', run: () => void actions.close() },
      ...[...list]
        .reverse()
        .slice(0, 15)
        .map((one, index) => {
          const target = parseHref(one.href)?.path ?? one.href
          const kind = parseHref(one.href) ? kindOf(target) : 'web'
          return {
            id: `file-${index}`,
            icon: iconFor(kind),
            label: `Go to ${baseName(target)}`,
            hint: describeAge(one.at, now),
            run: () => void show(io, one.href),
          }
        }),
    ],
  }
}

export function menuRows(lists: MenuLists, footer: readonly Action[], groupRows: readonly Action[]): Action[] {
  const hinted = (one: Action): Action => (one.hintFrom === undefined ? one : { ...one, hint: footer.find(key => key.id === one.hintFrom)?.hotkey ?? '' })
  const keyRows = footer.flatMap(one => (one.menu ? [{ id: `key-${one.id}`, icon: KEY_ICON, label: one.menu, hint: one.hotkey, run: one.run }] : []))
  return [...lists.lead.map(hinted), ...keyRows, ...groupRows, ...lists.tail.map(hinted)]
}

export function Menu(ctx: DrawContext, actions: PaneActions, rows: readonly Action[], footer: readonly Action[]) {
  const { Box, Text, Button, Input } = ctx
  const menuWidth = menuWidthOf(ctx.columns)
  const hasFilter = ctx.filter.trim().length > 0
  const closeMenu = () => void setMenu(actions.io, false)
  const runCommand = (one: Action | undefined) => {
    if (!one) return
    closeMenu()
    one.run()
  }
  let others = 0
  // Group rows sit outside the 20-row cap, so every one of the first eight shows however long the rest of the menu is.
  const matches = rankCommands(rows.filter(one => hasFilter || !one.isFilteredOnly), ctx.filter).filter(one => one.isGroupRow || others++ < 20)
  const moves = footer.filter(one => MOVE_KEYS.has(one.id)).map(one => one.hotkey)
  return (
    <Box flexDirection="column" width={menuWidth}>
      <Text wrap="truncate-end">
        <Text color={BASE.surface1}>─</Text>
        <Text color={BASE.accent} bold> COMMANDS </Text>
        <Text color={BASE.surface1}>{'─'.repeat(Math.max(1, menuWidth - 12))}</Text>
      </Text>
      {Input && (
        <Box
          key="menu-filter-frame"
          flexDirection="row"
          width={menuWidth}
          borderStyle="round"
          borderColor={BASE.accent}
          paddingX={1}
          marginY={1}
        >
          <Text color={BASE.accent}>{'\u{f002}  '}</Text>
          <Box flexGrow={1}>
            <Input
              key="menu-filter"
              placeholder="type to filter · Enter runs the first match"
              value={ctx.filter}
              autoFocus
              onInput={(value: string) => void actions.io.menuFilter.update(() => value)}
              onSubmit={() => runCommand(matches[0])}
            />
          </Box>
        </Box>
      )}
      {matches.length === 0 && <Text color={BASE.overlay0}>No command matches.</Text>}
      {matches.map((one, index) => (
        <Box
          key={`menu-row-${one.id}`}
          flexDirection="row"
          justifyContent="space-between"
          width={menuWidth}
          {...(hasFilter && index === 0 ? { backgroundColor: BASE.surface0 } : {})}
        >
          <Box flexDirection="row" flexShrink={1}>
            <Text color={BASE.accent}>{`${one.icon}  `}</Text>
            <Button key={`menu-${one.id}`} label={one.label} plain onPress={() => runCommand(one)} />
          </Box>
          <Text color={BASE.overlay0}>{one.hint}</Text>
        </Box>
      ))}
      {moves.length > 0 && <Text color={BASE.overlay0}>{`${moves.join(' ')} move`}</Text>}
      <Button key="menu-close" label="Close menu" plain dimColor onPress={closeMenu} />
    </Box>
  )
}
