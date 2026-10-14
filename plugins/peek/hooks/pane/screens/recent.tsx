import type { FileEntry } from '../../gallery'
import { selectEntries } from '../../gallery'
import { groupHome } from '../../groups-session'
import { iconFor } from '../../kinds'
import { clamp } from '../../navigation'
import { fileHref } from '../../paths'
import { closeAction, expandAction, modeActions, roleAction, scopeAction, selectActions } from '../actions'
import { LIST_CHUNK } from '../layout'
import { TASKS_ICON, recentPins } from '../task-data'
import type { RecentPins } from '../task-data'
import type { DrawContext, PaneActions, Screen } from '../types'
import { HoverLayer, ItemRow, SectionRule } from '../widgets'
import { fileListing } from './files'
import { groupCards } from './groups'

const PINNED_GROUPS = 4

type PinRow = { href: string; name: string; meta: string }

const plural = (count: number, one: string) => `${count} more ${one}${count === 1 ? '' : 's'}`

function pinRows(pins: RecentPins): PinRow[] {
  const page = fileHref(pins.tasksPage)
  const more = [pins.moreTasks ? plural(pins.moreTasks, 'task') : '', pins.moreLists ? plural(pins.moreLists, 'agent') : ''].filter(Boolean)
  return [
    ...pins.tasks.map(one => ({ href: fileHref(one.href), name: one.name, meta: typeof one.props.status === 'string' ? one.props.status : '' })),
    ...pins.lists.map(one => {
      const at = one.list.lastIndexOf('#')
      return { href: page, name: `Agent tasks ${one.list.slice(0, Math.min(8, at))} ${one.list.slice(at)}`, meta: `${one.open} open` }
    }),
    ...(more.length ? [{ href: page, name: 'More on the Tasks page', meta: more.join(' · ') }] : []),
  ]
}

export async function recentScreen(ctx: DrawContext, actions: PaneActions): Promise<Screen> {
  const { Box, Text, C, textWidth } = ctx
  const io = actions.io
  const { rest, favourites, scopeNote, role, scopeCrumbs, waiting, selected, layout, looks, describe, favouritesBlock, groupsOf, scope, starSet } = await fileListing(ctx, actions)
  const favs = selectEntries(favourites, 'all', '', 'recent')
  const recentList = rest ? selectEntries(rest, 'all', '', 'recent').slice(0, 300) : []
  const pins = await recentPins(io).catch(() => null)
  const pinBlock = (() => {
    if (!pins) return null
    const rows = pinRows(pins)
    const list = layout.section(() =>
      layout.list(rows, LIST_CHUNK, (one, i) => ({ href: one.href, key: `pins-${i}` }), (chunk, i, first) => (
        <Box key={`pins-${i}`} flexDirection="column" width={textWidth}>
          {chunk.map((one, j) => {
            const index = first + j
            const isSelected = index === selected
            return ItemRow(ctx, { key: one.href, href: one.href, name: one.name, kind: 'task', where: '', state: 'ok' }, {
              key: `pins-${i}-${j}`,
              width: textWidth,
              isSelected,
              icon: {
                isStarred: false,
                icon: TASKS_ICON,
                imageKey: `favicon-${index}`,
                buttonKey: `item-${index}`,
                autoFocus: isSelected ? true : undefined,
                onPress: () => void actions.selectAndOpen(index),
                boxes: {},
              },
              nameKey: `name-${index}`,
              nameColor: isSelected ? C.accent : C.text,
              meta: one.meta,
              metaColor: C.overlay0,
            })
          })}
        </Box>
      )),
    )
    const open = pins.tasks.length + pins.moreTasks
    return (
      <Box flexDirection="column" width={textWidth} marginBottom={1}>
        {SectionRule(ctx, 'OPEN WORK', open ? `${open} yours` : '', textWidth)}
        <Box height={1} />
        {list}
      </Box>
    )
  })()
  const starredGroups = await groupHome(io)
    .then(found => (found ? io.shownGroups(found.place) : []))
    .then(all => all.filter(one => one.starred))
    .catch(() => [])
  const pinned = starredGroups.slice(0, PINNED_GROUPS)
  const pinnedBlock = await (async () => {
    if (!pinned.length) return null
    const { cards: grid, heights } = await groupCards(ctx, actions, pinned, 'starred', layout.nav.length, selected)
    layout.section(() => layout.measured(pinned.map((one, i) => ({ rows: heights[i] ?? 0, place: { href: '', group: one.id, key: `starred-${i}` } }))))
    const count = starredGroups.length > pinned.length ? `${pinned.length} of ${starredGroups.length} · e for all` : `${pinned.length}`
    return (
      <Box flexDirection="column" width={textWidth}>
        {SectionRule(ctx, 'STARRED GROUPS', count, textWidth)}
        <Box height={1} />
        {grid}
      </Box>
    )
  })()
  const favBlock = favouritesBlock(favs)
  const rowList = (items: readonly FileEntry[], prefix: string) =>
    layout.list(items, LIST_CHUNK, (one, i) => ({ href: one.href, key: `${prefix}-${i}` }), (chunk, i, first) => (
      <Box key={`${prefix}-${i}`} flexDirection="column" width={textWidth}>
        {chunk.map((one, j) => {
          const index = first + j
          const isSelected = index === selected
          const { look, isStarred, png } = looks(one)
          const { where, age } = describe(one)
          const count = one.mentions > 1 ? `${one.mentions}× · ` : ''
          const meta = `${one.status ? `${one.status} · ` : ''}${where}${count}${age}`
          return ItemRow(ctx, look, {
            key: `${prefix}-${i}-${j}`,
            width: textWidth,
            isSelected,
            icon: {
              isStarred,
              png,
              icon: iconFor(look.kind),
              imageKey: `favicon-${index}`,
              buttonKey: `item-${index}`,
              autoFocus: isSelected ? true : undefined,
              onPress: () => void actions.selectAndOpen(index),
              boxes: {},
            },
            nameKey: `name-${index}`,
            nameColor: isSelected ? C.accent : C.text,
            meta,
            metaColor: C.overlay0,
          })
        })}
        {HoverLayer(ctx, `hover-${prefix}-${i}`, { kind: 'rows', width: textWidth, height: chunk.length, starX: 0, starY: 0, items: chunk.map(one => ({ href: one.href, isStarred: starSet.has(one.href) })) })}
      </Box>
    ))
  const groups = groupsOf(recentList).map(group => ({ ...group, list: layout.section(() => rowList(group.items, group.id)) }))
  const nav = layout.nav
  const pinnedId = nav[clamp(selected, nav.length)]?.group
  const pinnedOn = pinned.find(one => one.id === pinnedId)
  const content = (
    <Box flexDirection="column" width={textWidth}>
      {pinBlock}
      {pinnedBlock}
      {favBlock}
      {!rest && waiting}
      {rest && recentList.length === 0 && favs.length === 0 && pinned.length === 0 && !pins && (
        <Text color={C.overlay0}>
          {scope === 'session' ? 'Nothing mentioned yet. Paths and links in replies land here.' : 'No files found here.'}
        </Text>
      )}
      {groups.map(group => (
        <Box key={`group-${group.id}`} flexDirection="column" width={textWidth} marginBottom={1}>
          {SectionRule(ctx, group.label, `${group.items.length}`, textWidth)}
          <Box height={1} />
          {group.list}
        </Box>
      ))}
    </Box>
  )
  return {
    crumbs: scopeCrumbs,
    content,
    info: rest ? `${favs.length} favourites · ${recentList.length} files · ${scopeNote}` : 'loading…',
    actions: [
      ...modeActions(actions),
      scopeAction(actions, scope),
      roleAction(actions, role),
      ...selectActions(actions).map(one => {
        if (!pinnedOn) return one
        if (one.id === 'open-selected') return { ...one, menu: 'Open the selected group' }
        return one.id === 'star-selected' ? { ...one, menu: 'Unstar the selected group' } : one
      }),
      ...(pinned.length ? [expandAction(actions, ctx.chosen)] : []),
      closeAction(actions),
    ],
    pageBg: C.appBg,
    menuOn: pinnedOn ? { group: pinnedOn, starHint: 'f' } : { target: nav[clamp(selected, nav.length)]?.href },
    layout: layout.done(),
  }
}
