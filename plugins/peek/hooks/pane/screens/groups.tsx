import type { Group, SectionLayout } from '../../../types'
import { describeAge, plural } from '../../format'
import { gridColumns } from '../../gallery'
import { layoutOf } from '../../groups'
import { expandedGroups, groupHome, groupItemLook, groupPage, loadGroupRemote, openGroupHref, openGroupPage, starInGroupsTab, starredFirst, toggleExpanded } from '../../groups-session'
import { pixels } from '../../images'
import { iconFor, kindLabel } from '../../kinds'
import { fitName, wrapLines } from '../../measure'
import { clamp, remoteRef, starKeyOf, titlesByKey } from '../../navigation'
import { parseHref } from '../../paths'
import { cached } from '../../refresh'
import { ICON } from '../../theme'
import { MOVE_KEYS, closeAction, expandAction, modeActions, selectActions } from '../actions'
import { CARD_GAP, CARD_MIN, CARD_ROWS } from '../layout'
import type { ItemLook } from '../look'
import type { DrawContext, PaneActions, Screen } from '../types'
import { HoverLayer, ItemCard, ItemIcon, type IconSlot } from '../widgets'
import { groupPageScreen } from './group-page'

const GROUP_CARD_LINES = 3

const sum = (values: readonly number[]) => values.reduce((total, one) => total + one, 0)

export async function groupCards(ctx: DrawContext, actions: PaneActions, groups: readonly Group[], prefix: string, firstIndex: number, selected: number) {
  const { Box, Text, Button, Image, C, textWidth, now } = ctx
  const w = ctx
  const io = actions.io
  const inner = Math.max(8, textWidth - 4)
  const perRow = Math.min(2, gridColumns(inner, CARD_MIN, CARD_GAP))
  const itemWidth = Math.floor((inner - (perRow - 1) * CARD_GAP) / perRow)
  const starKeys = new Set((await io.stars.read()).map(starKeyOf))
  const worktreeRoot = (await groupHome(io))?.worktreeRoot
  const known = titlesByKey()
  const drawn = await Promise.all(
    groups.map(async (group, i) => {
      const index = firstIndex + i
      const isSelected = index === selected
      const isExpanded = expandedGroups.has(group.id)
      const sectionIds = new Set(group.sections.map(one => one.id))
      const loose = group.items.filter(one => !one.section || !sectionIds.has(one.section))
      let first = 0
      const blocks = [
        ...(loose.length ? [{ section: -1, title: '', layout: 'cards' as SectionLayout, items: loose }] : []),
        ...group.sections.map((one, section) => ({ section, title: one.title, layout: layoutOf(one), items: group.items.filter(item => item.section === one.id) })),
      ].map(block => {
        const numbered = { ...block, first }
        first += block.items.length
        return numbered
      })
      const description = wrapLines(group.description, inner, Number.POSITIVE_INFINITY)
      const canExpand = description.length > GROUP_CARD_LINES || blocks.length > 1 || (blocks[0]?.items.length ?? 0) > perRow
      const lines = isExpanded ? description : wrapLines(group.description, inner, GROUP_CARD_LINES)
      const shown = isExpanded ? blocks : blocks.slice(0, 1).map(block => ({ ...block, items: block.items.slice(0, perRow) }))
      const looks = await Promise.all(shown.map(block => Promise.all(block.items.map(one => groupItemLook(io, one, worktreeRoot, known)))))
      for (const one of looks.flat()) if (one.href && !parseHref(one.href) && remoteRef(one.href) && !cached(one.href)) loadGroupRemote(io, one.href)
      const open = (look: ItemLook) => void io.cursor.update(() => index).then(() => openGroupHref(io, group, look.key, look.href))
      let layers = 0
      const layer = (kind: 'rows' | 'cards', height: number, row: ItemLook[]) =>
        HoverLayer(w, `hover-${prefix}-items-${i}-${layers++}`, { kind, width: inner, height, cardWidth: itemWidth, cardHeight: CARD_ROWS, gap: CARD_GAP, starX: kind === 'cards' ? 2 : 0, starY: kind === 'cards' ? 1 : 0, items: row.map(one => ({ href: one.href, isStarred: starKeys.has(one.key), inGroup: group.id, key: one.key })) })
      const iconSlot = (look: ItemLook, n: number): IconSlot => {
        const isStarred = starKeys.has(look.key)
        return {
          isStarred,
          png: look.favicon && Image && !isStarred ? pixels.get(look.favicon) : undefined,
          icon: iconFor(look.kind),
          imageKey: `${prefix}-favicon-${i}-${n}`,
          buttonKey: `${prefix}-it-${i}-${n}`,
          onPress: () => open(look),
          boxes: { image: `${prefix}-fav-${i}-${n}`, button: `${prefix}-icon-${i}-${n}` },
        }
      }
      const itemCard = (look: ItemLook, n: number) =>
        ItemCard(w, look, {
          key: `${prefix}-card-${i}-${n}`,
          width: itemWidth,
          height: CARD_ROWS,
          background: C.appBg,
          clip: true,
          icon: iconSlot(look, n),
          nameKey: `${prefix}-itname-${i}-${n}`,
          nameColor: look.state === 'missing' ? C.overlay0 : C.text,
          meta: look.state === 'ok' ? kindLabel(look.kind).label : look.state,
          metaColor: look.state === 'missing' ? C.red : C.overlay0,
        })
      const line = (look: ItemLook, n: number) => (
        <Box key={`${prefix}-line-${i}-${n}`} height={1} flexDirection="row" width={inner} overflow="hidden" hover={{ backgroundColor: C.surface0 }}>
          {ItemIcon(w, iconSlot(look, n))}
          <Box key={`${prefix}-itname-${i}-${n}`} flexShrink={0}>
            <Text color={look.state === 'missing' ? C.overlay0 : C.text} hover={{ color: C.accent }} wrap="truncate-end">{`  ${fitName(look.name, Math.max(8, inner - 6))}`}</Text>
          </Box>
          <Box flexShrink={1} flexGrow={1} overflow="hidden">
            <Text color={C.overlay0} wrap="truncate-middle">{look.where ? `  ${look.where}` : ''}</Text>
          </Box>
          <Box flexShrink={0}>
            <Text color={look.state === 'missing' ? C.red : C.overlay1}>{look.state === 'ok' ? '' : ` ${look.state}`}</Text>
          </Box>
        </Box>
      )
      let height = 2 + 1 + (lines.length ? 1 + lines.length : 0) + (canExpand ? 2 : 0) + 1
      const parts = shown.map((block, b) => {
        const blockLooks = looks[b] ?? []
        const rows = Array.from({ length: Math.ceil(blockLooks.length / perRow) }, (_, r) => blockLooks.slice(r * perRow, r * perRow + perRow))
        const body = !blockLooks.length
          ? [<Text key={`${prefix}-empty-${i}-${b}`} color={C.overlay0}>empty</Text>]
          : block.layout === 'list'
            ? [
                <Box key={`${prefix}-lines-${i}-${b}`} flexDirection="column" width={inner}>
                  {blockLooks.map((look, j) => line(look, block.first + j))}
                  {layer('rows', blockLooks.length, blockLooks)}
                </Box>,
              ]
            : rows.map((row, r) => (
                <Box key={`${prefix}-irow-${i}-${b}-${r}`} flexDirection="row" columnGap={CARD_GAP} marginTop={r ? 1 : 0}>
                  {row.map((look, c) => itemCard(look, block.first + r * perRow + c))}
                  {layer('cards', CARD_ROWS, row)}
                </Box>
              ))
        height += 1 + (block.title ? 2 : 0) + (!blockLooks.length ? 1 : block.layout === 'list' ? blockLooks.length : rows.length * (CARD_ROWS + 1) - 1)
        return (
          <Box key={`${prefix}-block-${i}-${b}`} flexDirection="column" width={inner} marginTop={1}>
            {block.title ? (
              <Box key={`${prefix}-sec-${i}-${block.section}`} flexDirection="column" width={inner}>
                <Text color={C.text} bold wrap="truncate-end">{block.title}</Text>
                <Text color={C.surface1}>{'─'.repeat(inner)}</Text>
              </Box>
            ) : null}
            {body}
          </Box>
        )
      })
      if (!blocks.length) height += 2
      const barLabel = isExpanded ? 'LESS ▲' : 'MORE ▼'
      const barPad = Math.max(0, inner - barLabel.length)
      const node = (
        <Box
          key={`${prefix}-${i}`}
          flexDirection="column"
          width={textWidth}
          paddingX={2}
          paddingY={1}
          marginBottom={1}
          backgroundColor={isSelected ? C.surface0 : C.panelBg}
        >
          <Box flexDirection="row" width={inner} height={1}>
            <Box flexShrink={0}>
              <Button
                key={`item-${index}`}
                label={group.starred ? '\u{f51a}' : ICON.groups}
                plain
                autoFocus={isSelected ? true : undefined}
                onPress={() => void io.cursor.update(() => index).then(() => openGroupPage(io, group.id))}
              />
            </Box>
            <Box key={`group-name-${index}`} flexGrow={1} flexShrink={1} overflow="hidden">
              <Text color={isSelected ? C.accent : C.text} bold hover={{ color: C.accent }} wrap="truncate-end">{` ${group.title.toUpperCase()}`}</Text>
            </Box>
            <Box flexShrink={0} marginLeft={1}>
              <Text color={isSelected ? C.overlay1 : C.overlay0}>{`${plural(group.items.length, 'item')} · ${describeAge(group.updatedAt, now)}`}</Text>
            </Box>
            {HoverLayer(w, `hover-${prefix}-${i}`, { kind: 'rows', width: inner, height: 1, starX: 0, starY: 0, items: [{ group: group.id, isStarred: group.starred }] })}
          </Box>
          {lines.length > 0 && <Box height={1} />}
          {lines.map((text, k) => (
            <Text key={`${prefix}-desc-${i}-${k}`} color={C.subtext0}>{text}</Text>
          ))}
          {parts}
          {!blocks.length && (
            <Box marginTop={1}>
              <Text color={C.overlay0}>No items</Text>
            </Box>
          )}
          {canExpand && <Box key={`${prefix}-moregap-${i}`} height={1} />}
          {canExpand && (
            <Box key={`${prefix}-morebar-${i}`} width={inner} height={1} backgroundColor={isSelected ? C.surface1 : C.surface0}>
              <Button
                key={`${prefix}-more-${i}`}
                label={`${' '.repeat(Math.floor(barPad / 2))}${barLabel}${' '.repeat(Math.ceil(barPad / 2))}`}
                plain
                dimColor
                hover={{ color: C.accent }}
                onPress={() => void io.cursor.update(() => index).then(() => toggleExpanded(io, group.id))}
              />
            </Box>
          )}
        </Box>
      )
      return { node, height }
    }),
  )
  return { cards: drawn.map(one => one.node), heights: drawn.map(one => one.height) }
}

export async function groupsScreen(ctx: DrawContext, actions: PaneActions): Promise<Screen> {
  const { Box, Text, C, textWidth, cwd } = ctx
  const io = actions.io
  const home = await groupHome(io)
  const opened = await io.openGroup.read()
  const shown = opened && home ? await io.shownGroup(home.place, opened.id) : null
  if (opened && !shown && groupPage.goneNotice !== opened.id) {
    groupPage.goneNotice = opened.id
    io.toast('That group was deleted.')
  }
  const project = (home?.worktreeRoot ?? cwd).split('/').filter(Boolean).pop() ?? 'project'
  if (opened && shown) return groupPageScreen(ctx, actions, { home, opened, shown, project })
  groupPage.rows = null
  groupPage.remotes = []
  const groups = home ? starredFirst(await io.shownGroups(home.place)) : []
  const starredCount = groups.filter(one => one.starred).length
  const selected = await io.cursor.read()
  const { cards, heights } = await groupCards(ctx, actions, groups, 'groups', 0, selected)
  const selectedGroup = () => actions.selectedNav().then(one => one?.href)
  const content = (
    <Box flexDirection="column" width={textWidth}>
      {groups.length === 0 && <Text color={C.overlay0}>No groups yet. The agent makes groups: ask it to group related files and links.</Text>}
      {cards}
    </Box>
  )
  return {
    crumbs: [{ label: `${ICON.groups} ${project}`, fg: C.appBg, bg: C.accent, bold: true, canShrink: true }],
    content,
    info: `${plural(groups.length, 'group')} · ${starredCount} starred`,
    actions: [
      ...modeActions(actions),
      ...selectActions(actions).filter(one => MOVE_KEYS.has(one.id)),
      {
        id: 'open-selected',
        label: '⏎ Open',
        hotkey: 'o',
        menu: 'Open the selected group',
        run: () => void selectedGroup().then(id => (id ? openGroupPage(io, id) : undefined)),
      },
      {
        id: 'star-selected',
        label: 'Star',
        hotkey: 'f',
        menu: 'Star or unstar the selected group',
        run: () => void selectedGroup().then(id => (id ? starInGroupsTab(io, id) : undefined)),
      },
      expandAction(actions, ctx.chosen),
      closeAction(actions),
    ],
    pageBg: C.appBg,
    menuOn: { group: groups[clamp(selected, groups.length)], starHint: 'f' },
    layout: {
      nav: groups.map((one, i) => ({ href: one.id, key: `groups-${i}`, line: i, col: 0 })),
      blockStarts: heights.map((_, i) => sum(heights.slice(0, i))),
      estimatedRows: Math.max(1, sum(heights)),
    },
  }
}
