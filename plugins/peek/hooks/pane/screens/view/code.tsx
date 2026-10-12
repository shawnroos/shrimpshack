import type { View } from '../../../../types'
import type { NavIo } from '../../../navigation'
import { layout } from '../../layout'
import type { DrawContext } from '../../types'
import { blockJumps } from './blocks'
import type { ViewBody } from './blocks'

const CHUNK = 10

export function codeBody(ctx: DrawContext, io: NavIo, code: NonNullable<View['code']>): ViewBody {
  const { Box, Text, Code, C, textWidth, isMenuOpen, offset } = ctx
  const lines = code.source.split('\n')
  const chunks = Array.from({ length: Math.ceil(lines.length / CHUNK) }, (_, i) => lines.slice(i * CHUNK, i * CHUNK + CHUNK))
  layout.blockStarts = chunks.map((_, i) => i * CHUNK)
  layout.estimatedRows = Math.max(1, lines.length)
  const body = (
    <Box flexDirection="column" width={textWidth}>
      {chunks.map((part, i) => (
        <Box key={`chunk-${i}`} flexDirection="column">
          {isMenuOpen ? (
            <Text color={C.overlay1}>{part.join('\n') || ' '}</Text>
          ) : (
            <Code
              source={part.join('\n') || ' '}
              language={code.language}
              startLine={code.startLine + i * CHUNK}
              wrap="truncate-end"
            />
          )}
        </Box>
      ))}
    </Box>
  )
  const firstLine = code.startLine + Math.max(0, Math.min(lines.length - 1, offset))
  return { body, jumps: blockJumps(ctx, io, chunks.length, 'chunk'), position: `line ${firstLine} of ${code.startLine + lines.length - 1}` }
}
