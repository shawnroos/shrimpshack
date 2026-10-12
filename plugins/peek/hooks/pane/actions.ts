import type { Mode } from '../../types'
import { nextOf } from '../gallery'
import type { RoleFilter, Scope } from '../gallery'
import { setStar, toggleExpanded, toggleGroupStar } from '../groups-session'
import { switchMode } from '../navigation'
import type { NavIo } from '../navigation'
import { ICON } from '../theme'
import type { Action, PaneActions } from './types'

export const MODES: { id: Mode; label: string; icon: string; hotkey: string; row: string; about: string; isMenuSwitch: boolean }[] = [
  { id: 'view', label: 'Peek', icon: ICON.peek, hotkey: 'p', row: 'peek', about: 'show the open file', isMenuSwitch: false },
  { id: 'recent', label: 'Recent', icon: ICON.recent, hotkey: 'r', row: 'recent', about: 'files by last use', isMenuSwitch: false },
  { id: 'gallery', label: 'Gallery', icon: ICON.gallery, hotkey: 'g', row: 'gallery', about: 'files as cards by type', isMenuSwitch: false },
  { id: 'groups', label: 'Groups', icon: ICON.groups, hotkey: 'e', row: 'groups', about: 'files and links the agent bundled', isMenuSwitch: true },
]

export const ROLES: RoleFilter[] = ['all', 'artifacts', 'touched']
export const SCOPES: Scope[] = ['session', 'worktree', 'repo']
export const SCOPE_ICON: Record<Scope, string> = { session: '\u{f0b79}', worktree: '\u{f418}', repo: '\u{f401}' }
const ROLE_ICON: Record<RoleFilter, string> = { all: '\u{f0c9}', artifacts: '◆', touched: '◇' }

export const MOVE_KEYS = new Set(['next', 'prev', 'left', 'right'])

export const modeActions = (actions: PaneActions): Action[] =>
  MODES.map(one => ({
    id: `mode-${one.id}`,
    label: one.label,
    hotkey: one.hotkey,
    run: () => void switchMode(actions.io, one.id),
  }))

// The ⌃k rows for Peek, Recent and Gallery set the mode alone, so the page offset and the open group stay as they
// were; the Groups row, the footer mode keys and the tabs all go through switchMode. Unifying them changes behavior.
export const modeRows = (io: NavIo, hasView: boolean): Action[] =>
  MODES.filter(one => hasView || one.id !== 'view').map(one => ({
    id: one.row,
    icon: one.icon,
    label: `${one.label}: ${one.about}`,
    hintFrom: `mode-${one.id}`,
    run: one.isMenuSwitch ? () => void switchMode(io, one.id) : () => void io.mode.update(() => one.id),
  }))

export const roleAction = (actions: PaneActions, role: RoleFilter): Action => ({
  id: 'role',
  label: `Show: ${role}`,
  hotkey: 'a',
  run: () => void actions.roleFilter.update(one => nextOf(ROLES, one)),
})

export const roleRows = (actions: PaneActions): Action[] =>
  ROLES.map(one => ({
    id: `role-${one}`,
    icon: ROLE_ICON[one],
    label: `Show: ${one}`,
    hintFrom: 'role',
    run: () => void actions.roleFilter.update(() => one),
  }))

export const scopeAction = (actions: PaneActions, scope: Scope): Action => ({
  id: 'scope',
  label: `Scope: ${scope}`,
  hotkey: 's',
  run: () => void actions.scope.update(one => nextOf(SCOPES, one)),
})

export const scopeRows = (actions: PaneActions): Action[] =>
  SCOPES.map(one => ({
    id: `scope-${one}`,
    icon: SCOPE_ICON[one],
    label: `Scope: ${one}`,
    hintFrom: 'scope',
    run: () => void actions.scope.update(() => one),
  }))

export const selectActions = (actions: PaneActions): Action[] => [
  { id: 'next', label: 'Down', hotkey: 'j', run: () => void actions.moveSelection('down') },
  { id: 'prev', label: 'Up', hotkey: 'k', run: () => void actions.moveSelection('up') },
  { id: 'left', label: 'Left', hotkey: 'h', run: () => void actions.moveSelection('left') },
  { id: 'right', label: 'Right', hotkey: 'l', run: () => void actions.moveSelection('right') },
  {
    id: 'open-selected',
    label: '⏎ Open',
    hotkey: 'o',
    menu: 'Open the selected file',
    run: () => void actions.selectedNav().then(one => actions.openNav(one)),
  },
  {
    id: 'star-selected',
    label: 'Star',
    hotkey: 'f',
    menu: 'Star or unstar the selected file',
    run: () =>
      void actions.selectedNav().then(one => {
        if (one?.group) return toggleGroupStar(actions.io, one.group)
        return one?.href ? setStar(actions.io, one.href).then(() => undefined) : undefined
      }),
  },
]

export const closeAction = (actions: PaneActions): Action => ({ id: 'close', label: 'Close', hotkey: 'x', run: () => void actions.close() })

export const expandAction = (actions: PaneActions, chosen: Mode): Action => ({
  id: 'expand-selected',
  label: 'More',
  hotkey: 'm',
  menu: 'Expand/Collapse group',
  run: () =>
    void actions.selectedNav().then(one => {
      const id = one?.group ?? (one && chosen === 'groups' ? one.href : undefined)
      if (id) toggleExpanded(actions.io, id)
    }),
})
