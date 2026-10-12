import type { FileEntry } from '../../gallery'
import { selectEntries } from '../../gallery'
import { groupHome } from '../../groups-session'
import { iconFor } from '../../kinds'
import { clamp } from '../../navigation'
import { closeKey, expandKey, modeKeys, selectKeys } from '../keys'
import { LIST_CHUNK, layout } from '../layout'
import type { DrawContext, PaneActions, Screen } from '../types'
import { HoverLayer, ItemRow, SectionRule } from '../widgets'
import { fileListing } from './files'
import { groupCards } from './groups'

const PINNED_GROUPS = 4

export async function recentScreen(ctx: DrawContext, actions: PaneActions): Promise<Screen> {
  const { Box, Text, C, textWidth } = ctx
  const w = ctx
  const io = actions.io
  const { rest, favourites, scopeNote, roleKey, scopeKey, scopeCrumbs, waiting, selected, nav, keys, starts, at, looks, describe, favouritesBlock, groupsOf, scope, starSet } = await fileListing(ctx, actions)
  const favs = selectEntries(favourites, 'all', '', 'recent')
  const recentList = rest ? selectEntries(rest, 'all', '', 'recent').slice(0, 300) : []
  at.cursor = 0
  const starredGroups = await groupHome(io)
    .then(found => (found ? io.shownGroups(found.place) : []))
    .then(all => all.filter(one => one.starred))
    .catch(() => [])
  const pinned = starredGroups.slice(0, PINNED_GROUPS)
  const pinnedBlock = await (async () => {
    if (!pinned.length) return null
    at.cursor += 2
    const { cards: grid, heights } = await groupCards(ctx, actions, pinned, 'starred', nav.length, selected)
    pinned.forEach((one, i) => {
      keys.push(`starred-${i}`)
      starts.push(at.cursor)
      at.cursor += heights[i] ?? 0
      nav.push({ href: '', group: one.id, key: `starred-${i}`, line: at.navLine++, col: 0 })
    })
    at.cursor += 1
    const count = starredGroups.length > pinned.length ? `${pinned.length} of ${starredGroups.length} · e for all` : `${pinned.length}`
    return (
      <Box flexDirection="column" width={textWidth}>
        {SectionRule(w, 'STARRED GROUPS', count, textWidth)}
        <Box height={1} />
        {grid}
      </Box>
    )
  })()
  const favBlock = favouritesBlock(favs)
  const rowList = (items: readonly FileEntry[], prefix: string) => {
    const chunks = Array.from({ length: Math.ceil(items.length / LIST_CHUNK) }, (_, i) =>
      items.slice(i * LIST_CHUNK, i * LIST_CHUNK + LIST_CHUNK),
    )
    const firstNav = nav.length
    chunks.forEach((chunk, i) => {
      keys.push(`${prefix}-${i}`)
      starts.push(at.cursor)
      at.cursor += chunk.length
      for (const one of chunk) nav.push({ href: one.href, key: `${prefix}-${i}`, line: at.navLine++, col: 0 })
    })
    return chunks.map((chunk, i) => (
      <Box key={`${prefix}-${i}`} flexDirection="column" width={textWidth}>
        {chunk.map((one, j) => {
          const index = firstNav + i * LIST_CHUNK + j
          const isSelected = index === selected
          const { look, isStarred, png } = looks(one)
          const { where, age } = describe(one)
          const count = one.mentions > 1 ? `${one.mentions}× · ` : ''
          const meta = `${one.status ? `${one.status} · ` : ''}${where}${count}${age}`
          return ItemRow(w, look, {
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
        {HoverLayer(w, `hover-${prefix}-${i}`, { kind: 'rows', width: textWidth, height: chunk.length, starX: 0, starY: 0, items: chunk.map(one => ({ href: one.href, isStarred: starSet.has(one.href) })) })}
      </Box>
    ))
  }
  const groups = groupsOf(recentList).map(group => {
    at.cursor += 2
    const list = rowList(group.items, group.id)
    at.cursor += 1
    return { ...group, list }
  })
  layout.blockStarts = starts
  layout.estimatedRows = Math.max(1, at.cursor)
  const pinnedId = nav[clamp(selected, nav.length)]?.group
  const pinnedOn = pinned.find(one => one.id === pinnedId)
  const content = (
    <Box flexDirection="column" width={textWidth}>
      {pinnedBlock}
      {favBlock}
      {!rest && waiting}
      {rest && recentList.length === 0 && favs.length === 0 && pinned.length === 0 && (
        <Text color={C.overlay0}>
          {scope === 'session' ? 'Nothing mentioned yet. Paths and links in replies land here.' : 'No files found here.'}
        </Text>
      )}
      {groups.map(group => (
        <Box key={`group-${group.id}`} flexDirection="column" width={textWidth} marginBottom={1}>
          {SectionRule(w, group.label, `${group.items.length}`, textWidth)}
          <Box height={1} />
          {group.list as never}
        </Box>
      ))}
    </Box>
  )
  return {
    crumbs: scopeCrumbs,
    content,
    info: rest ? `${favs.length} favourites · ${recentList.length} files · ${scopeNote}` : 'loading…',
    keys: [
      ...modeKeys(actions),
      scopeKey,
      roleKey,
      ...selectKeys(actions).map(one => {
        if (!pinnedOn) return one
        if (one.key === 'open-selected') return { ...one, menu: 'Open the selected group' }
        return one.key === 'star-selected' ? { ...one, menu: 'Unstar the selected group' } : one
      }),
      ...(pinned.length ? [expandKey(actions, ctx.chosen)] : []),
      closeKey(actions),
    ],
    pageBg: C.appBg,
    menuOn: pinnedOn ? { group: pinnedOn, starHint: 'f' } : { target: nav[clamp(selected, nav.length)]?.href },
  }
}
