import type { RemoteRecord, View } from '../../../types'
import { pixels } from '../../images'
import { colorFor, iconFor } from '../../kinds'
import type { NavIo } from '../../navigation'
import { mute } from '../../theme'
import type { ColorName } from '../../views/definition'
import type { Blocks } from '../screens/view/blocks'
import type { ProseOptions } from '../screens/view/prose'
import type { DrawContext, PictureBudget } from '../types'
import { SectionRule, fitPicture } from '../widgets'

export type RecordEnv = {
  ctx: DrawContext
  io: NavIo
  blocks: Blocks
  remote: NonNullable<View['remote']>
  record: RemoteRecord
  budget: PictureBudget
  linked: (text: string) => string
  picture: ProseOptions['picture']
  // The page's keyboard rows already taken when this block draws into blocks of its own.
  navBase: number
  icons: Readonly<Record<string, string>>
  colors: PropColors
  items?: ProseOptions['items']
  definitions?: ProseOptions['definitions']
}

// Color names a definition may use, read from the draw's colors so a page dims with the menu open.
export function colorNamed(C: DrawContext['C'], name: string): string | undefined {
  const palette: Record<ColorName, string> = {
    red: C.red,
    yellow: C.yellow,
    green: C.green,
    teal: C.teal,
    blue: C.blue,
    mauve: C.mauve,
    peach: C.peach,
    accent: C.accent,
    text: C.text,
    subtext: C.subtext0,
    gray: C.overlay1,
    muted: C.overlay0,
  }
  return Object.hasOwn(palette, name) ? palette[name as ColorName] : undefined
}

export type PropColors = Readonly<Record<string, Readonly<Record<string, string>>>>

export const colorOf = (C: DrawContext['C'], colors: PropColors | undefined, prop: string, value: string): string | undefined =>
  colorNamed(C, colors?.[prop]?.[value] ?? '')

export const collectionsOf = (env: RecordEnv): Pick<ProseOptions, 'items' | 'definitions'> => ({
  ...(env.items ? { items: env.items } : {}),
  ...(env.definitions ? { definitions: env.definitions } : {}),
})

export const fieldOf = (record: RemoteRecord, name: string | undefined): unknown => (name ? (record as unknown as Record<string, unknown>)[name] : undefined)

export const kindColor = (ctx: DrawContext, kind: string) => (ctx.isMenuOpen ? mute(colorFor(kind)) : colorFor(kind))

export function sectionRule(env: Pick<RecordEnv, 'ctx' | 'blocks'>, key: string, label: string, right = '') {
  env.blocks.drawnParts.push(SectionRule(env.ctx, label.toUpperCase(), right, env.ctx.textWidth, key))
  env.blocks.note(1, label)
}

export function drawHeader(env: RecordEnv, options: Record<string, string>) {
  const { ctx, remote, record, budget, blocks } = env
  const { Box, Text, Image, C, textWidth } = ctx
  const from = options.from ?? 'title'
  const named = fieldOf(record, from)
  const title = typeof named === 'string' && named ? named : record.title
  const favicon = fitPicture(budget, remote.favicon && pixels.get(remote.favicon.file))
  blocks.drawnParts.push(
    <Box key="remote-title" flexDirection="row" width={textWidth}>
      {favicon && Image ? (
        <Box flexShrink={0} marginRight={1}>
          <Image key="remote-favicon" source={{ png: favicon }} columns={2} rows={1} alt={iconFor(record.kind)} />
        </Box>
      ) : (
        <Text color={kindColor(ctx, record.kind)}>{`${iconFor(record.kind)} `}</Text>
      )}
      <Box flexShrink={1}>
        <Text color={colorOf(C, env.colors, from, title) ?? C.text} bold>{title}</Text>
      </Box>
    </Box>,
  )
  blocks.note(Math.ceil((title.length + 3) / textWidth), title)
}
