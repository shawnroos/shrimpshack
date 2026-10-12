import type { PluginState } from 'claude-code'

import type { Group } from '../../../types'
import { plural } from '../../format'
import { groupItemLook, groupPage, groupPageRows, loadGroupRemote, openGroupItem, setStar } from '../../groups-session'
import type { GroupHome, GroupRows } from '../../groups-session'
import { pixels } from '../../images'
import { iconFor } from '../../kinds'
import { clamp, remoteRef, starKeyOf, titlesByKey } from '../../navigation'
import { parseHref } from '../../paths'
import { cached, isTimed } from '../../refresh'
import { ICON } from '../../theme'
import { closeKey, modeKeys } from '../keys'
import { layout } from '../layout'
import type { ItemLook } from '../look'
import type { DrawContext, PaneActions, Screen } from '../types'
import { HoverLayer, ItemRow, SectionRule } from '../widgets'

type Opened = NonNullable<PluginState['peek']['openGroup']>

export async function groupPageScreen(ctx: DrawContext, actions: PaneActions, page: { home: GroupHome | null; opened: Opened; shown: Group; project: string }): Promise<Screen> {
  const { Box, Text, Image, C, textWidth } = ctx
  const w = ctx
  const io = actions.io
  const { home, opened, shown, project } = page
  groupPage.goneNotice = ''
  const worktreeRoot = home?.worktreeRoot
  const known = titlesByKey()
  const sectionIds = new Set(shown.sections.map(one => one.id))
  const blocks = [
    { title: '', items: shown.items.filter(one => !one.section || !sectionIds.has(one.section)) },
    ...shown.sections.map(one => ({ title: one.title, items: shown.items.filter(item => item.section === one.id) })),
  ]
  const looks = await Promise.all(blocks.flatMap(block => block.items).map(one => groupItemLook(io, one, worktreeRoot, known)))
  const remotes = looks.filter(one => one.href && !parseHref(one.href) && remoteRef(one.href))
  for (const one of remotes) if (!cached(one.href)) loadGroupRemote(io, one.href)
  groupPage.remotes = remotes.map(one => one.href).filter(isTimed)
  const keys = looks.map(one => one.key)
  const found = opened.item === null ? 0 : keys.indexOf(opened.item)
  const previous = groupPage.rows?.id === shown.id ? groupPage.rows.selected : 0
  const selected = clamp(found >= 0 ? found : previous, keys.length)
  const refs = blocks.flatMap(block => block.items).map(one => one.ref)
  const rows: GroupRows = { id: shown.id, title: shown.title, keys, hrefs: looks.map(one => one.href), selected }
  groupPage.rows = rows
  layout.navOrder = keys.map((key, index) => ({ href: key, key: `group-row-${index}`, line: index, col: 0 }))
  layout.blockStarts = []
  const starList = await io.stars.read()
  const starKeys = new Set(starList.map(starKeyOf))
  const missing = looks.filter(one => one.state === 'missing').length
  const row = (one: ItemLook, index: number) => {
    const isSelected = index === selected
    return ItemRow(w, one, {
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
        onPress: () => void openGroupItem(io, rows, index),
        boxes: {},
      },
      nameKey: `group-item-${index}`,
      nameColor: one.state === 'missing' ? C.overlay0 : isSelected ? C.accent : C.text,
      meta: one.state === 'ok' ? '' : one.state,
      metaColor: one.state === 'missing' ? C.red : C.overlay1,
      metaKey: `group-meta-${index}`,
    })
  }
  let next = 0
  const drawn = blocks.map((block, b) => {
    const first = next
    next += block.items.length
    const blockLooks = looks.slice(first, next)
    const list = blockLooks.length > 0 && (
      <Box key={`group-block-${b}`} flexDirection="column" width={textWidth}>
        {blockLooks.map((one, j) => row(one, first + j))}
        {HoverLayer(w, `hover-group-${b}`, { kind: 'rows', width: textWidth, height: blockLooks.length, starX: 0, starY: 0, items: blockLooks.map(one => ({ href: one.href, isStarred: starKeys.has(one.key) })) })}
      </Box>
    )
    if (b === 0) return list ? <Box key="group-top" flexDirection="column" width={textWidth} marginBottom={1}>{list}</Box> : null
    return (
      <Box key={`group-part-${b}`} flexDirection="column" width={textWidth} marginBottom={1}>
        <Box key={`group-section-${b - 1}`}>{SectionRule(w, block.title.toUpperCase(), `${block.items.length}`, textWidth)}</Box>
        {list || (
          <Box key={`group-empty-${b - 1}`}>
            <Text color={C.overlay0}>empty</Text>
          </Box>
        )}
      </Box>
    )
  })
  layout.estimatedRows = Math.max(1, looks.length + blocks.length * 2 + 3)
  const content = (
    <Box flexDirection="column" width={textWidth}>
      <Box key="group-page-title">
        <Text color={C.accent} bold>{`${shown.starred ? '\u{f51a}' : ICON.groups} ${shown.title}`}</Text>
      </Box>
      {shown.description ? <Text color={C.subtext0}>{shown.description}</Text> : null}
      <Box height={1} />
      {shown.items.length === 0 && (
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
      { label: `${shown.starred ? '\u{f51a}' : ICON.groups} ${shown.title}`, fg: C.appBg, bg: C.accent, bold: true, canShrink: true },
    ],
    content,
    info: `${shown.title} · ${plural(looks.length, 'item')} · ${missing} missing`,
    keys: [
      ...modeKeys(actions),
      { key: 'next', label: 'Down', hotkey: 'j', onPress: () => void actions.moveSelection('down') },
      { key: 'prev', label: 'Up', hotkey: 'k', onPress: () => void actions.moveSelection('up') },
      {
        key: 'open-selected',
        label: '⏎ Open',
        hotkey: 'o',
        menu: 'Open the selected item',
        onPress: () => void groupPageRows(io).then(now => (now ? openGroupItem(io, now, now.selected) : undefined)),
      },
      {
        key: 'star-selected',
        label: 'Star',
        hotkey: 'f',
        menu: 'Star or unstar the selected item',
        onPress: () => void groupPageRows(io).then(now => {
          const href = now?.hrefs[now.selected]
          return href ? setStar(io, href).then(() => io.invalidate()) : undefined
        }),
      },
      closeKey(actions),
    ],
    pageBg: C.appBg,
    menuOn: { target: rows.hrefs[selected] || undefined, group: shown, selectedRef: refs[selected] },
  }
}
