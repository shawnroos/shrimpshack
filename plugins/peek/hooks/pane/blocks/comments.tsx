import type { RemoteRecord } from '../../../types'
import { describeAge } from '../../format'
import { drawProse } from '../screens/view/prose'
import { collectionsOf, fieldOf, sectionRule } from './header'
import type { RecordEnv } from './header'

type Thread = NonNullable<RemoteRecord['comments']>

const isThread = (value: unknown): value is Thread =>
  typeof value === 'object' && value !== null && Array.isArray((value as Thread).shown) && typeof (value as Thread).total === 'number'

export async function drawComments(env: RecordEnv, options: Record<string, string>) {
  const from = options.from ?? ''
  const thread = fieldOf(env.record, from)
  if (!isThread(thread) || thread.total <= 0) return
  const { ctx, io, blocks } = env
  const { Box, Text, C, now } = ctx
  const title = options.title ?? from
  const shown = thread.shown.length
  const count = shown < thread.total ? `showing latest ${shown} of ${thread.total}` : `${thread.total}`
  sectionRule(env, `${from}-head`, title, thread.inline ? `${count} · ${thread.inline} inline` : count)
  for (const [i, one] of thread.shown.entries()) {
    const indent = (one.depth ?? 0) * 2
    const when = Number.isNaN(Date.parse(one.at)) ? one.at : describeAge(Date.parse(one.at), now)
    blocks.drawnParts.push(
      <Box key={`comment-${i}`} marginLeft={indent}>
        <Text wrap="truncate-end">
          <Text color={C.accent} bold>{one.author}</Text>
          <Text color={C.overlay0}>{` · ${when}${one.isReview ? ' · review' : ''}`}</Text>
        </Text>
      </Box>,
    )
    blocks.note(1, title)
    await drawProse(ctx, io, blocks, `comment-${i}-body`, env.linked(one.body || '*(empty)*'), { ...collectionsOf(env), picture: env.picture, heading: title, indent, navStart: env.navBase + blocks.nav.length })
  }
}
