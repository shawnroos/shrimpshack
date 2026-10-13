import type { Mode } from '../../types'
import { nextOf } from '../gallery'
import type { RoleFilter, Scope } from '../gallery'
import { setStar, toggleExpanded, toggleGroupStar } from '../groups-session'
import { switchMode } from '../navigation'
import type { Cell, NavIo } from '../navigation'
import { ICON, ROLE_ICON, SCOPE_ICON } from '../theme'
import type { Action, PaneActions } from './types'

export const MODES: { id: Mode; label: string; icon: string; hotkey: string; row: string; about: string; isMenuSwitch: boolean }[] = [
  { id: 'view', label: 'Peek', icon: ICON.peek, hotkey: 'p', row: 'peek', about: 'show the open file', isMenuSwitch: false },
  { id: 'recent', label: 'Recent', icon: ICON.recent, hotkey: 'r', row: 'recent', about: 'files by last use', isMenuSwitch: false },
  { id: 'gallery', label: 'Gallery', icon: ICON.gallery, hotkey: 'g', row: 'gallery', about: 'files as cards by type', isMenuSwitch: false },
  { id: 'groups', label: 'Groups', icon: ICON.groups, hotkey: 'e', row: 'groups', about: 'files and links the agent bundled', isMenuSwitch: true },
]

const ROLES: RoleFilter[] = ['all', 'artifacts', 'touched']
const SCOPES: Scope[] = ['session', 'worktree', 'repo']

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

function cycleActions<T extends string>(spec: {
  id: string
  hotkey: string
  label: string
  values: readonly T[]
  icon: Record<T, string>
  cell: (actions: PaneActions) => Cell<T>
}) {
  return {
    action: (actions: PaneActions, current: T): Action => ({
      id: spec.id,
      label: `${spec.label}: ${current}`,
      hotkey: spec.hotkey,
      run: () => void spec.cell(actions).update(one => nextOf(spec.values, one)),
    }),
    rows: (actions: PaneActions): Action[] =>
      spec.values.map(one => ({
        id: `${spec.id}-${one}`,
        icon: spec.icon[one],
        label: `${spec.label}: ${one}`,
        hintFrom: spec.id,
        run: () => void spec.cell(actions).update(() => one),
      })),
  }
}

const role = cycleActions({ id: 'role', hotkey: 'a', label: 'Show', values: ROLES, icon: ROLE_ICON, cell: actions => actions.roleFilter })
const scope = cycleActions({ id: 'scope', hotkey: 's', label: 'Scope', values: SCOPES, icon: SCOPE_ICON, cell: actions => actions.scope })
export const roleAction = role.action
export const roleRows = role.rows
export const scopeAction = scope.action
export const scopeRows = scope.rows

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
