import type { Mode } from '../../types'
import { setStar, toggleExpanded, toggleGroupStar } from '../groups-session'
import { switchMode } from '../navigation'
import { ICON } from '../theme'
import type { Key, PaneActions } from './types'

export const MODES: { id: Mode; label: string; icon: string; hotkey: string }[] = [
  { id: 'view', label: 'Peek', icon: '\u{f06e}', hotkey: 'p' },
  { id: 'recent', label: 'Recent', icon: '\u{f017}', hotkey: 'r' },
  { id: 'gallery', label: 'Gallery', icon: '\u{f0c6c}', hotkey: 'g' },
  { id: 'groups', label: 'Groups', icon: ICON.groups, hotkey: 'e' },
]

export const MOVE_KEYS = new Set(['next', 'prev', 'left', 'right'])

export const modeKeys = (actions: PaneActions): Key[] =>
  MODES.map(one => ({
    key: `mode-${one.id}`,
    label: one.label,
    hotkey: one.hotkey,
    onPress: () => void switchMode(actions.io, one.id),
  }))

export const selectKeys = (actions: PaneActions): Key[] => [
  { key: 'next', label: 'Down', hotkey: 'j', onPress: () => void actions.moveSelection('down') },
  { key: 'prev', label: 'Up', hotkey: 'k', onPress: () => void actions.moveSelection('up') },
  { key: 'left', label: 'Left', hotkey: 'h', onPress: () => void actions.moveSelection('left') },
  { key: 'right', label: 'Right', hotkey: 'l', onPress: () => void actions.moveSelection('right') },
  {
    key: 'open-selected',
    label: '⏎ Open',
    hotkey: 'o',
    menu: 'Open the selected file',
    onPress: () => void actions.selectedNav().then(one => actions.openNav(one)),
  },
  {
    key: 'star-selected',
    label: 'Star',
    hotkey: 'f',
    menu: 'Star or unstar the selected file',
    onPress: () =>
      void actions.selectedNav().then(one => {
        if (one?.group) return toggleGroupStar(actions.io, one.group)
        return one?.href ? setStar(actions.io, one.href).then(() => undefined) : undefined
      }),
  },
]

export const closeKey = (actions: PaneActions): Key => ({ key: 'close', label: 'Close', hotkey: 'x', onPress: () => void actions.close() })

export const expandKey = (actions: PaneActions, chosen: Mode): Key => ({
  key: 'expand-selected',
  label: 'More',
  hotkey: 'm',
  menu: 'Expand/Collapse group',
  onPress: () =>
    void actions.selectedNav().then(one => {
      const id = one?.group ?? (one && chosen === 'groups' ? one.href : undefined)
      if (id) toggleExpanded(actions.io, id)
    }),
})
