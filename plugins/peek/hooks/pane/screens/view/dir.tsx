import type { View } from '../../../../types'
import { describeAge, describeSize } from '../../../format'
import { colorFor, iconFor } from '../../../kinds'
import type { NavIo } from '../../../navigation'
import { fileHref, kindOf } from '../../../paths'
import { ICON } from '../../../theme'
import { LIST_CHUNK } from '../../layout'
import type { DrawContext } from '../../types'
import { blockJumps } from './blocks'
import type { ViewBody } from './blocks'

export function dirBody(ctx: DrawContext, io: NavIo, folderPath: string, dir: NonNullable<View['dir']>): ViewBody {
  const { Box, Text, Client, C, textWidth, isMenuOpen, now } = ctx
  const parent = folderPath.slice(0, Math.max(1, folderPath.lastIndexOf('/')))
  const items = [
    ...(folderPath !== '/' ? [{ href: fileHref(parent), icon: ICON.up, color: C.overlay1, name: '..', folder: '', meta: 'up', canStar: false }] : []),
    ...dir.map(one => {
      const kindOfEntry = one.isDir ? 'folder' : kindOf(one.name)
      return {
        href: fileHref(`${folderPath}/${one.name}`),
        icon: iconFor(kindOfEntry),
        color: colorFor(kindOfEntry),
        name: one.isDir ? `${one.name}/` : one.name,
        folder: '',
        meta: one.isDir ? describeAge(one.mtimeMs, now) : `${describeSize(one.size)} · ${describeAge(one.mtimeMs, now)}`,
      }
    }),
  ]
  const chunks = Array.from({ length: Math.ceil(items.length / LIST_CHUNK) }, (_, i) =>
    items.slice(i * LIST_CHUNK, i * LIST_CHUNK + LIST_CHUNK),
  )
  const body = (
    <Box flexDirection="column" width={textWidth}>
      {items.length === 0 && <Text color={C.overlay0}>Empty folder.</Text>}
      {Client &&
        chunks.map((chunk, i) => (
          <Client
            key={`rows-${i}`}
            module="../../../rows.tsx"
            props={{ muted: isMenuOpen, width: textWidth, rows: chunk }}
            width={textWidth}
            height={chunk.length}
          />
        ))}
    </Box>
  )
  return { body, jumps: blockJumps(ctx, io, chunks.length, 'rows'), position: '', layout: { blockStarts: chunks.map((_, i) => i * LIST_CHUNK), estimatedRows: Math.max(1, items.length) } }
}
