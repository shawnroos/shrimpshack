import type { PluginState } from 'claude-code'

import type { Group } from '../../../types/groups'
import { plural } from '../../format'
import { membersOf, splitMembers } from '../../groups'
import { groupItemLook, groupPage, loadGroupRemote, openGroupHref, ruleCandidates, setStar } from '../../groups-session'
import type { GroupHome } from '../../groups-session'
import { pixels } from '../../images'
import { iconFor } from '../../kinds'
import { clamp, remoteRef, starKeyOf } from '../../navigation'
import { titlesByKey } from '../../refresh'
import { parseHref } from '../../paths'
import { cached, isTimed } from '../../refresh'
import { ICON } from '../../theme'
import { closeAction, modeActions } from '../actions'
import { layoutBuilder } from '../layout'
import type { ItemLook } from '../look'
import type { DrawContext, PaneActions, Screen } from '../types'
import { HoverLayer, ItemRow, SectionRule } from '../widgets'
import { itemsOnce } from './view/markdown'
import { proseParts } from './view/prose'

type Opened = NonNullable<PluginState['peek']['openGroup']>

export async function groupPageScreen(ctx: DrawContext, actions: PaneActions, page: { home: GroupHome | null; opened: Opened; shown: Group; project: string }): Promise<Screen> {
  const { Box, Text, Image, C, textWidth } = ctx
  const io = actions.io
  const { home, opened, shown, project } = page
  groupPage.goneNotice = ''
  const worktreeRoot = home?.worktreeRoot
  const known = titlesByKey()
  const candidates = await ruleCandidates(io, [shown], worktreeRoot)
  const members = membersOf(shown, candidates, worktreeRoot)
  const sectionIds = new Set(shown.sections.map(one => one.id))
  const splitBlocks = splitMembers(shown, members, candidates, worktreeRoot)
  const blocks = splitBlocks
    ? [{ title: '', items: [] }, ...splitBlocks]
    : [
        { title: '', items: members.filter(one => !one.section || !sectionIds.has(one.section)) },
        ...shown.sections.map(one => ({ title: one.title, items: members.filter(item => item.section === one.id) })),
      ]
  const looks = await Promise.all(blocks.flatMap(block => block.items).map(one => groupItemLook(io, one, worktreeRoot, known)))
  const remotes = looks.filter(one => one.href && !parseHref(one.href) && remoteRef(one.href))
  for (const one of remotes) if (!cached(one.href)) loadGroupRemote(io, one.href)
  groupPage.remotes = remotes.map(one => one.href).filter(isTimed)
  const keys = looks.map(one => one.key)
  const found = opened.item === null ? 0 : keys.indexOf(opened.item)
  const previous = groupPage.drawn?.id === shown.id ? groupPage.drawn.selected : 0
  const selected = clamp(found >= 0 ? found : previous, keys.length)
  const refs = blocks.flatMap(block => block.items).map(one => one.ref)
  groupPage.drawn = { id: shown.id, selected }
  const starList = await io.stars.read()
  const starKeys = new Set(starList.map(starKeyOf))
  const missing = looks.filter(one => one.state === 'missing').length
  const row = (one: ItemLook, index: number) => {
    const isSelected = index === selected
    return ItemRow(ctx, one, {
      key: `group-row-${index}`,
      width: textWidth,
      isSelected,
      icon: {
        isStarred: starKeys.has(one.key),
        png: one.favicon && Image ? pixels.get(one.favicon) : undefined,
        icon: iconFor(one.kind),
        imageKey: `favicon-${index}`,
        buttonKey: `item-${index}`,
        autoFocus: isSelected ? true : undefined,
        onPress: () => void actions.selectAndOpen(index),
        boxes: {},
      },
      nameKey: `group-item-${index}`,
      nameColor: one.state === 'missing' ? C.overlay0 : isSelected ? C.accent : C.text,
      meta: one.state === 'ok' ? '' : one.state,
      metaColor: one.state === 'missing' ? C.red : C.overlay1,
      metaKey: `group-meta-${index}`,
    })
  }
  // The description's block rows press like links but stay out of the keyboard order, which is the group's items:
  // their keys start after the items' so every Button key is unique, and the cursor never lands on them.
  const unselected = { ...io, cursor: { read: async () => -1, update: io.cursor.update } }
  const description = shown.description
    ? await proseParts(ctx, unselected, 'group-description', shown.description, { picture: () => null, items: itemsOnce(io), navStart: looks.length })
    : []
  const layout = layoutBuilder()
  // Three rows for the title and the gap under it, two per block whether it draws or not: the estimate as it was.
  layout.space(3)
  layout.space(description.reduce((rows, part) => rows + part.rows, 0))
  let next = 0
  const drawn = blocks.map((block, b) => {
    layout.space(2)
    const first = next
    next += block.items.length
    const blockLooks = looks.slice(first, next)
    const list = blockLooks.length > 0 && (
      <Box key={`group-block-${b}`} flexDirection="column" width={textWidth}>
        {layout.lines(blockLooks, (one, index) => ({ href: one.href, key: `group-row-${index}`, groupItem: { group: shown.id, title: shown.title, key: one.key } }), row)}
        {HoverLayer(ctx, `hover-group-${b}`, { kind: 'rows', width: textWidth, height: blockLooks.length, starX: 0, starY: 0, items: blockLooks.map(one => ({ href: one.href, isStarred: starKeys.has(one.key) })) })}
      </Box>
    )
    if (b === 0) return list ? <Box key="group-top" flexDirection="column" width={textWidth} marginBottom={1}>{list}</Box> : null
    return (
      <Box key={`group-part-${b}`} flexDirection="column" width={textWidth} marginBottom={1}>
        <Box key={`group-section-${b - 1}`}>{SectionRule(ctx, block.title.toUpperCase(), `${block.items.length}`, textWidth)}</Box>
        {list || (
          <Box key={`group-empty-${b - 1}`}>
            <Text color={C.overlay0}>empty</Text>
          </Box>
        )}
      </Box>
    )
  })
  const content = (
    <Box flexDirection="column" width={textWidth}>
      <Box key="group-page-title">
        <Text color={C.accent} bold>{`${shown.starred ? ICON.star : ICON.groups} ${shown.title}`}</Text>
      </Box>
      {description.length ? (
        <Box key="group-description" flexDirection="column" width={textWidth}>
          {description.map(part => part.node)}
        </Box>
      ) : null}
      <Box height={1} />
      {members.length === 0 && (
        <Box key="group-no-items" marginBottom={1}>
          <Text color={C.overlay0}>No items</Text>
        </Box>
      )}
      {drawn}
    </Box>
  )
  return {
    crumbs: [
      { label: `${ICON.groups} ${project}`, fg: C.overlay1, bg: C.surface0, canShrink: true },
      { label: `${shown.starred ? ICON.star : ICON.groups} ${shown.title}`, fg: C.appBg, bg: C.accent, bold: true, canShrink: true },
    ],
    content,
    info: `${shown.title} · ${plural(looks.length, 'item')} · ${missing} missing`,
    actions: [
      ...modeActions(actions),
      { id: 'next', label: 'Down', hotkey: 'j', run: () => void actions.moveSelection('down') },
      { id: 'prev', label: 'Up', hotkey: 'k', run: () => void actions.moveSelection('up') },
      {
        id: 'open-selected',
        label: '⏎ Open',
        hotkey: 'o',
        menu: 'Open the selected item',
        // An empty page answers o with the gone-file toast it always gave.
        run: () => void (looks.length ? actions.selectedIndex().then(at => actions.selectAndOpen(at)) : openGroupHref(io, shown, '', '')),
      },
      {
        id: 'star-selected',
        label: 'Star',
        hotkey: 'f',
        menu: 'Star or unstar the selected item',
        run: () => void actions.selectedNav().then(one => (one?.href ? setStar(io, one.href).then(() => io.invalidate()) : undefined)),
      },
      closeAction(actions),
    ],
    pageBg: C.appBg,
    menuOn: { target: looks[selected]?.href || undefined, group: shown, selectedRef: refs[selected] },
    layout: { ...layout.done(), group: { id: shown.id, selected } },
  }
}
