import type { CiTone, RemoteRecord } from '../../../types'
import { pixels } from '../../images'
import { iconFor } from '../../kinds'
import { estimateRows } from '../../measure'
import { ICON, META_ICON } from '../../theme'
import { Embed, fullWidthOf } from '../screens/view/blocks'
import { fitPicture } from '../widgets'
import { colorNamed, fieldOf, kindColor } from './header'
import type { RecordEnv } from './header'

type Row = { label: string; value: string }
type Changes = NonNullable<RemoteRecord['stats']>

const isRows = (value: unknown): value is Row[] =>
  Array.isArray(value) && value.every(one => typeof one === 'object' && one !== null && typeof one.label === 'string' && typeof one.value === 'string')

const isChanges = (value: unknown): value is Changes =>
  typeof value === 'object' && value !== null && ['additions', 'deletions', 'changedFiles'].every(key => typeof (value as Record<string, unknown>)[key] === 'number')

export const iconKey = (label: string) => label.trim().toLowerCase().replace(/\s+/g, '-')

// A definition that declares no icons keeps the shared label icons, so pages without one still draw them.
function labelIcon(env: RecordEnv, label: string): string | undefined {
  return Object.keys(env.icons).length ? env.icons[iconKey(label)] : META_ICON[label]
}

function boxIcon(env: RecordEnv, name: string | undefined): string {
  if (!name || name === 'kind') return iconFor(env.record.kind)
  return (ICON as Record<string, string>)[name] ?? name
}

function boxColor(env: RecordEnv, name: string | undefined): string {
  if (!name || name === 'kind') return kindColor(env.ctx, env.record.kind)
  return colorNamed(env.ctx.C, name) ?? env.ctx.C.text
}

function textOf(env: RecordEnv, name: string | undefined): string {
  const value = fieldOf(env.record, name)
  return typeof value === 'string' || typeof value === 'number' ? String(value) : ''
}

// The block draws by the shape of the value it names, so a record without that value leaves the block out.
export function drawFields(env: RecordEnv, options: Record<string, string>) {
  const from = options.from ?? ''
  const value = fieldOf(env.record, from)
  const title = options.title ?? from
  if (isRows(value)) labelRows(env, from, title, value, options)
  else if (isChanges(value)) changeRows(env, from, title, value, options)
}

function labelRows(env: RecordEnv, from: string, title: string, rows: Row[], options: Record<string, string>) {
  const { ctx, remote, record, budget, blocks } = env
  const { Box, Text, Image, C, textWidth } = ctx
  const labelWidth = Math.min(14, Math.max(0, ...rows.map(one => (labelIcon(env, one.label) ? 1 : one.label.length))) + 2)
  const preview = fitPicture(budget, remote.preview && pixels.get(remote.preview.file))
  const previewBox = preview && Image && remote.preview ? fullWidthOf(ctx)(remote.preview.width, remote.preview.height) : null
  const ogDescription = record.og?.description
  blocks.drawnParts.push(
    Embed(ctx, `remote-${from}`, boxIcon(env, options.icon), title.toUpperCase(), textOf(env, options.detail), boxColor(env, options.color), (
      <Box flexDirection="column">
        {previewBox && preview && Image && <Image key="remote-preview-image" source={{ png: preview }} {...previewBox} alt="preview image" />}
        {ogDescription && (
          <Box marginTop={previewBox ? 1 : 0} marginBottom={1}>
            <Text color={C.subtext0}>{ogDescription}</Text>
          </Box>
        )}
        {rows.map((one, i) => (
          <Text key={`meta-${i}`} wrap="truncate-end">
            <Text color={C.overlay0}>{(labelIcon(env, one.label) ?? one.label).padEnd(labelWidth)}</Text>
            <Text color={C.text}>{one.value}</Text>
          </Text>
        ))}
      </Box>
    )),
  )
  blocks.note(rows.length + 4 + (previewBox?.rows ?? 0) + (ogDescription ? estimateRows(ogDescription, textWidth - 2) + 1 : 0), title)
}

function changeRows(env: RecordEnv, from: string, title: string, changes: Changes, options: Record<string, string>) {
  const { ctx, blocks } = env
  const { Box, Text, C } = ctx
  const tone: Record<CiTone, string> = { bad: C.red, wait: C.yellow, ok: C.green, none: C.overlay1 }
  const ciColor = colorNamed(C, env.colors.ciTone?.[changes.ciTone] ?? '') ?? tone[changes.ciTone]
  blocks.drawnParts.push(
    Embed(ctx, `remote-${from}`, boxIcon(env, options.icon), title.toUpperCase(), `${changes.changedFiles} files`, boxColor(env, options.color), (
      <Box flexDirection="column">
        <Text>
          <Text color={C.green}>{`+${changes.additions}`}</Text>
          <Text color={C.overlay0}>{'  '}</Text>
          <Text color={C.red}>{`−${changes.deletions}`}</Text>
          <Text color={C.overlay0}>{`  ·  ${changes.changedFiles} files changed`}</Text>
        </Text>
        <Text wrap="truncate-end">
          <Text color={C.overlay0}>{'CI  '}</Text>
          <Text color={ciColor}>{changes.ci}</Text>
        </Text>
      </Box>
    )),
  )
  blocks.note(6, title)
}
