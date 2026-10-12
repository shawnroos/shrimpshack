import type { RoleFilter, Scope } from '../gallery'
import { describeAge } from '../format'
import { setStar } from '../groups-session'
import type { MenuCommand } from '../groups-session'
import { iconFor } from '../kinds'
import { liveKey, liveSession, toggleLive } from '../live-pane'
import { openExternally, refresh, setMenu, show, switchMode } from '../navigation'
import { kindOf, parseHref } from '../paths'
import { parseRef } from '../refs'
import { C as BASE, ICON } from '../theme'
import { MOVE_KEYS } from './keys'
import type { DrawContext, Key, PaneActions } from './types'

export const ROLES: RoleFilter[] = ['all', 'artifacts', 'touched']
export const SCOPES: Scope[] = ['session', 'worktree', 'repo']
export const SCOPE_ICON: Record<Scope, string> = { session: '\u{f0b79}', worktree: '\u{f418}', repo: '\u{f401}' }

const COMMAND_KEYS: Record<string, string> = {
  peek: 'mode-view',
  recent: 'mode-recent',
  gallery: 'mode-gallery',
  groups: 'mode-groups',
  'role-*': 'role',
  'scope-*': 'scope',
  open: 'open',
  refresh: 'refresh',
  live: 'live',
  'live-back': 'back',
  copy: 'copy',
  star: 'star',
  close: 'close',
}

export const menuWidthOf = (columns: number) => Math.max(24, Math.min(64, columns - 8))

// Built when the draw starts: the live labels read the live session before anything the draw awaits can change it.
export function menuCommands(ctx: DrawContext, actions: PaneActions): MenuCommand[] {
  const { current, list, now, surface, Image } = ctx
  const io = actions.io
  return [
    ...(current
      ? [
          { id: 'peek', icon: ICON.peek, label: 'Peek: show the open file', hint: 'p', run: () => void io.mode.update(() => 'view') },
        ]
      : []),
    { id: 'recent', icon: ICON.recent, label: 'Recent: files by last use', hint: 'r', run: () => void io.mode.update(() => 'recent') },
    { id: 'gallery', icon: ICON.gallery, label: 'Gallery: files as cards by type', hint: 'g', run: () => void io.mode.update(() => 'gallery') },
    { id: 'groups', icon: ICON.groups, label: 'Groups: files and links the agent bundled', hint: 'e', run: () => void switchMode(io, 'groups') },
    ...ROLES.map(one => ({
      id: `role-${one}`,
      icon: one === 'artifacts' ? '◆' : one === 'touched' ? '◇' : '\u{f0c9}',
      label: `Show: ${one}`,
      hint: 'a',
      run: () => void actions.roleFilter.update(() => one),
    })),
    ...SCOPES.map(one => ({
      id: `scope-${one}`,
      icon: SCOPE_ICON[one],
      label: `Scope: ${one}`,
      hint: 's',
      run: () => void actions.scope.update(() => one),
    })),
    { id: 'top', icon: '\u{f062}', label: 'Scroll to top', hint: 'home', run: () => void io.scroll({ to: 'start' }).catch(() => undefined) },
    { id: 'bottom', icon: '\u{f063}', label: 'Scroll to bottom', hint: 'end', run: () => void io.scroll({ to: 'end' }).catch(() => undefined) },
    ...(current
      ? [
          { id: 'open', icon: '\u{f08e}', label: 'Open in its own app', hint: 'o', run: () => void openExternally(io, current) },
          ...(current.remote
            ? [{ id: 'refresh', icon: '\u{f021}', label: 'Refresh this page', hint: 'u', run: () => void refresh(io, current.href) }]
            : []),
          ...(surface === 'terminal' && Image && current.remote && parseRef(current.href)?.kind === 'web'
            ? [{ id: 'live', icon: '\u{f0ac}', label: liveSession.href === current.href ? 'Reader view: leave the live page' : 'Live view: the real page, clickable', hint: 'v', run: () => void toggleLive(io, current, liveSession.viewport ?? { width: 600, height: 400 }) }]
            : []),
          ...(liveSession.href === current.href && liveSession.live?.state().canBack
            ? [{ id: 'live-back', icon: '\u{f060}', label: 'Back in the live page', hint: 'b', run: () => void liveKey(io, 'b') }]
            : []),
          { id: 'copy', icon: '\u{f0c5}', label: current.remote ? 'Copy link' : 'Copy path', hint: 'c', run: () => void io.copy({ text: current.location }) },
          { id: 'star', icon: '\u{f51a}', label: 'Star or unstar this file', hint: 'f', run: () => void setStar(io, current.href) },
        ]
      : []),
    { id: 'close', icon: '\u{f00d}', label: 'Close the pane', hint: 'x', run: () => void actions.close() },
    ...[...list]
      .reverse()
      .slice(0, 15)
      .map((one, index) => {
        const target = parseHref(one.href)?.path ?? one.href
        const kind = parseHref(one.href) ? kindOf(target) : 'web'
        return {
          id: `file-${index}`,
          icon: iconFor(kind),
          label: `Go to ${target.split('/').pop() || target}`,
          hint: describeAge(one.at, now),
          run: () => void show(io, one.href),
        }
      }),
  ]
}

export function Menu(ctx: DrawContext, actions: PaneActions, commands: readonly MenuCommand[], keys: readonly Key[], groupMenu: readonly MenuCommand[]) {
  const { Box, Text, Button, Input } = ctx
  const menuWidth = menuWidthOf(ctx.columns)
  const words = ctx.filter.toLowerCase().split(/\s+/).filter(Boolean)
  const closeMenu = () => void setMenu(actions.io, false)
  const runCommand = (one: MenuCommand | undefined) => {
    if (!one) return
    closeMenu()
    one.run()
  }
  const fromKeys = keys.flatMap(one => (one.menu ? [{ id: `key-${one.key}`, icon: '\u{f11c}', label: one.menu, hint: one.hotkey, run: one.onPress }] : []))
  const closeAt = commands.findIndex(one => one.id === 'close')
  const keyed = commands.map(one => {
    const owner = COMMAND_KEYS[one.id.replace(/-[^-]+$/, '-*')] ?? COMMAND_KEYS[one.id]
    return owner ? { ...one, hint: keys.find(key => key.key === owner)?.hotkey ?? '' } : one
  })
  const all: MenuCommand[] = [...keyed.slice(0, closeAt), ...fromKeys, ...groupMenu, ...keyed.slice(closeAt)]
  let others = 0
  // Group rows sit outside the 20-row cap, so every one of the first eight shows however long the rest of the menu is.
  const matches = all.filter(
    one => (words.length > 0 || !one.isFilteredOnly) && words.every(word => one.label.toLowerCase().includes(word)) && (one.isGroupRow || others++ < 20),
  )
  const moves = keys.filter(one => MOVE_KEYS.has(one.key)).map(one => one.hotkey)
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
      {matches.map(one => (
        <Box key={`menu-row-${one.id}`} flexDirection="row" justifyContent="space-between" width={menuWidth}>
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
