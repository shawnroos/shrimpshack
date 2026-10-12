import { describeAge, describeSize } from '../../format'
import { filterRole, gridColumns } from '../../gallery'
import type { FileEntry } from '../../gallery'
import { scopeEntries, sessionEntries, withMentions } from '../../entries'
import { pixels } from '../../images'
import { iconFor } from '../../kinds'
import { shortPath } from '../../paths'
import { CARD_GAP, CARD_MIN, CARD_ROWS, layoutBuilder } from '../layout'
import { lookOf } from '../look'
import { SCOPE_ICON } from '../actions'
import type { Crumb, DrawContext, PaneActions } from '../types'
import { HoverLayer, ItemCard, SectionRule } from '../widgets'

// Recent and Gallery share one listing: the same reads in the same order, and one layout builder that cardGrid,
// favouritesBlock and Recent's own blocks all add to.
export async function fileListing(ctx: DrawContext, actions: PaneActions) {
  const { Box, Text, Image, C, textWidth, list, now, cwd, home } = ctx
  const w = ctx
  const io = actions.io
  const scope = await actions.scope.read()
  const role = await actions.roleFilter.read()
  const starList = await io.stars.read()
  const starSet = new Set(starList)
  const raw = scope === 'session' ? await sessionEntries(io, list) : scopeEntries(io, scope, cwd, now)
  const entries = raw ? filterRole(withMentions(raw, list), role) : null
  const scopeNote = role === 'all' ? scope : `${scope} · ${role}`
  const describe = (one: FileEntry) => {
    const age = describeAge(Math.max(one.mentionedAt, one.mtimeMs), now)
    const where = one.worktree && scope === 'repo' ? `${one.worktree} · ` : ''
    return { where, age }
  }
  const looks = (one: FileEntry) => ({
    look: lookOf(one, scope === 'session' ? shortPath(one.folder, cwd, home) : one.folder),
    isStarred: starSet.has(one.href),
    png: one.favicon && Image ? pixels.get(one.favicon) : undefined,
  })
  const scopeCrumbs: Crumb[] = [{ label: `${SCOPE_ICON[scope]} ${scope}`, fg: C.appBg, bg: C.accent, bold: true }]
  const waiting = <Text color={C.overlay0}>Loading files…</Text>

  const favMentions = starList.map(href => list.find(one => one.href === href) ?? { href, at: 0, count: 0 })
  const favourites = filterRole(withMentions(await sessionEntries(io, favMentions), list), role)
  const rest = entries ? entries.filter(one => !starSet.has(one.href)) : null
  const perRow = gridColumns(textWidth, CARD_MIN, CARD_GAP)
  const cardWidth = Math.floor((textWidth - (perRow - 1) * CARD_GAP) / perRow)
  const selected = await io.cursor.read()
  const layout = layoutBuilder()
  const cardGrid = (list: readonly FileEntry[], prefix: string) =>
    layout.grid(list, perRow, (one, r) => ({ href: one.href, key: `${prefix}-${r}` }), (cards, r, first) => (
      <Box key={`${prefix}-${r}`} flexDirection="row" columnGap={CARD_GAP} marginBottom={1}>
        {cards.map((one, c) => {
          const index = first + c
          const isSelected = index === selected
          const { look, isStarred, png } = looks(one)
          const { where, age } = describe(one)
          return ItemCard(w, look, {
            key: `${prefix}-${r}-${c}`,
            width: cardWidth,
            height: CARD_ROWS,
            background: isSelected ? C.surface0 : C.panelBg,
            clip: false,
            icon: {
              isStarred,
              png,
              icon: iconFor(look.kind),
              imageKey: `favicon-${index}`,
              buttonKey: `item-${index}`,
              autoFocus: isSelected ? true : undefined,
              onPress: () => void actions.selectAndOpen(index),
            },
            nameKey: `name-${index}`,
            nameColor: isSelected ? C.accent : C.text,
            meta: `${where}${age} · ${one.status ?? describeSize(one.size)}`,
            metaColor: isSelected ? C.overlay1 : C.overlay0,
          })
        })}
        {HoverLayer(w, `hover-${prefix}-${r}`, { kind: 'cards', width: textWidth, height: CARD_ROWS, cardWidth, cardHeight: CARD_ROWS, gap: CARD_GAP, starX: 2, starY: 1, items: cards.map(one => ({ href: one.href, isStarred: starSet.has(one.href) })) })}
      </Box>
    ))
  const favouritesBlock = (shownFavs: readonly FileEntry[]) => {
    if (!shownFavs.length) return null
    const grid = layout.section(() => cardGrid(shownFavs, 'favs'))
    return (
      <Box flexDirection="column" width={textWidth}>
        {SectionRule(w, 'FAVOURITES', `${shownFavs.length}`, textWidth)}
        <Box height={1} />
        {grid}
      </Box>
    )
  }

  const groupsOf = (items: readonly FileEntry[]) =>
    [
      { id: 'artifacts', label: 'ARTIFACTS', items: items.filter(one => one.role === 'artifact') },
      { id: 'touched', label: 'TOUCHED', items: items.filter(one => one.role === 'touched') },
      { id: 'files', label: scope.toUpperCase(), items: items.filter(one => !one.role) },
    ].filter(group => group.items.length > 0)
  return { scope, role, starSet, rest, favourites, scopeNote, scopeCrumbs, waiting, selected, layout, looks, describe, cardGrid, favouritesBlock, groupsOf }
}
