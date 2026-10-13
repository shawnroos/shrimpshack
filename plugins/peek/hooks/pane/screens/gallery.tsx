import type { GallerySort, GalleryType } from '../../gallery'
import { nextOf, selectEntries } from '../../gallery'
import { clamp } from '../../navigation'
import { closeAction, modeActions, roleAction, scopeAction, selectActions } from '../actions'
import type { DrawContext, PaneActions, Screen } from '../types'
import { SectionRule } from '../widgets'
import { fileListing } from './files'

const TYPES: GalleryType[] = ['all', 'markdown', 'code', 'data', 'image', 'diagram', 'html']
const SORTS: GallerySort[] = ['recent', 'name', 'size', 'mentions']

export async function galleryScreen(ctx: DrawContext, actions: PaneActions): Promise<Screen> {
  const { Box, Text, C, textWidth, Input } = ctx
  const { rest, favourites, scopeNote, scope, role, scopeCrumbs, waiting, selected, layout, cardGrid, favouritesBlock, groupsOf } = await fileListing(ctx, actions)
  const type = await actions.galleryType.read()
  const sort = await actions.gallerySort.read()
  const query = await actions.galleryFilter.read()
  const favs = selectEntries(favourites, type, query, sort)
  const picked = rest ? selectEntries(rest, type, query, sort).slice(0, 240) : []
  layout.space(2)
  const favBlock = favouritesBlock(favs)
  const groups = groupsOf(picked).map(group => ({ ...group, grid: layout.section(() => cardGrid(group.items, group.id)) }))
  const content = (
    <Box flexDirection="column" width={textWidth}>
      <Box flexDirection="row" columnGap={2} width={textWidth}>
        {Input && (
          <Box flexGrow={1}>
            <Input
              key="gallery-filter"
              placeholder="filter by name or folder"
              value={query}
              onInput={(value: string) => void actions.galleryFilter.update(() => value)}
              onSubmit={(value: string) => void actions.galleryFilter.update(() => value)}
            />
          </Box>
        )}
        <Text color={C.overlay1}>{`${type} · ${sort}`}</Text>
      </Box>
      <Box height={1} />
      {favBlock}
      {!rest && waiting}
      {rest && picked.length === 0 && favs.length === 0 && <Text color={C.overlay0}>No files match.</Text>}
      {groups.map(group => (
        <Box key={`group-${group.id}`} flexDirection="column" width={textWidth}>
          {SectionRule(ctx, group.label, `${group.items.length}`, textWidth)}
          <Box height={1} />
          {group.grid}
        </Box>
      ))}
    </Box>
  )
  return {
    crumbs: scopeCrumbs,
    content,
    info: rest ? `${favs.length + picked.length} ${type === 'all' ? 'files' : type} · ${scopeNote}` : 'loading…',
    actions: [
      ...modeActions(actions),
      scopeAction(actions, scope),
      roleAction(actions, role),
      { id: 'type', label: 'Type', hotkey: 't', menu: `Next file type (now ${type})`, run: () => void actions.galleryType.update(one => nextOf(TYPES, one)) },
      { id: 'sort', label: 'Sort', hotkey: 'n', menu: `Next sort order (now ${sort})`, run: () => void actions.gallerySort.update(one => nextOf(SORTS, one)) },
      ...selectActions(actions),
      closeAction(actions),
    ],
    pageBg: C.appBg,
    menuOn: { target: layout.nav[clamp(selected, layout.nav.length)]?.href },
    layout: layout.done(),
  }
}
