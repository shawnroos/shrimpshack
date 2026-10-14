import type { View } from '../../../../types'
import { linkify } from '../../../markdown'
import { fitName } from '../../../measure'
import { openFromPage, refContext } from '../../../navigation'
import type { NavIo } from '../../../navigation'
import { parseRef } from '../../../refs'
import { adapterOfKind, failureText } from '../../../sources/adapter'
import { matches, problemLine } from '../../../views/definition'
import type { Definition, DefinitionProblem } from '../../../views/definition'
import { createViewRegistry } from '../../../views/registry'
import type { ViewsIo } from '../../../views/registry'
import { drawComments } from '../../blocks/comments'
import { drawFields } from '../../blocks/fields'
import { drawHeader, sectionRule } from '../../blocks/header'
import type { RecordEnv } from '../../blocks/header'
import { drawMedia, recordPictures } from '../../blocks/media'
import type { DrawContext, PictureBudget } from '../../types'
import { newBlocks, settleBlocks } from './blocks'
import type { ViewBody } from './blocks'
import { drawProse } from './prose'
import type { ProsePart, RecordBlock } from './prose'
import { slackThread } from './slack'

const MAX_LINK_MEMO = 400
const linkMemo = new Map<string, string>()
const views = createViewRegistry()

const BODY_LABEL: Partial<Record<string, string>> = { 'gh-repo': 'README', web: 'Page', 'slack-thread': 'Message' }
const LISTS_FIRST = new Set(['gh-repo', 'linear-issue'])

const RECORD_DRAWERS: Record<RecordBlock, (env: RecordEnv, options: Record<string, string>) => void | Promise<void>> = {
  'peek-header': drawHeader,
  'peek-fields': drawFields,
  'peek-media': drawMedia,
  'peek-comments': drawComments,
}

// A record kind with a loaded view definition draws from its template; the rest keep the drawing below.
async function viewOf(ctx: DrawContext, io: NavIo, kind: string): Promise<{ definition: Definition | null; problems: DefinitionProblem[] }> {
  const viewsIo: ViewsIo = { list: dir => io.list(dir), read: io.readFile, stat: io.stat }
  const folders = { builtIn: `${io.liveIo().root}/views`, user: `${ctx.home}/.local/share/claude-peek/views` }
  const { definitions, problems } = await views.load(viewsIo, folders)
  return {
    definition: definitions.find(one => matches(one, { recordKind: kind })) ?? null,
    problems: problems.filter(one => one.file.endsWith(`/${kind}.md`)),
  }
}

async function recordParts(env: RecordEnv, lang: RecordBlock, options: Record<string, string>, navStart: number): Promise<ProsePart[]> {
  const own = newBlocks()
  await RECORD_DRAWERS[lang]({ ...env, blocks: own, navBase: navStart }, options)
  const last = own.drawnParts.length - 1
  return own.drawnParts.map((node, i) => ({ node, rows: own.partRows[i] ?? 1, heading: own.partHeadings[i] ?? '', ...(i === last && own.nav.length ? { nav: own.nav } : {}) }))
}

export async function remoteBody(ctx: DrawContext, io: NavIo, current: View, remote: NonNullable<View['remote']>): Promise<ViewBody> {
  const { Box, Text, Button, C, textWidth } = ctx
  const record = remote.record
  const blocks = newBlocks()
  const { drawnParts, note } = blocks
  const budget: PictureBudget = { used: 0 }
  const ghRef = record && adapterOfKind(record.kind).id === 'github' ? parseRef(record.address) : null
  const refs = refContext(ghRef && 'owner' in ghRef && ghRef.owner && ghRef.repo ? `${ghRef.owner}/${ghRef.repo}` : undefined)
  const refsKey = `${refs.repo}|${refs.teamKeys?.join(',')}|${refs.workspace}`
  const linked = (text: string) => {
    const memoKey = `${refsKey}|${text}`
    const cached = linkMemo.get(memoKey)
    if (cached !== undefined) return cached
    if (linkMemo.size > MAX_LINK_MEMO) linkMemo.clear()
    const out = linkify(text, () => null, refs)
    linkMemo.set(memoKey, out)
    return out
  }
  const picture = recordPictures(ctx, io, remote, budget)
  if (!record) {
    const message = failureText(remote.failure ?? 'offline')
    drawnParts.push(
      <Box key="remote-failure" flexDirection="column">
        <Text color={C.red} bold>{message.title}</Text>
        {remote.failureDetail && <Text color={C.overlay1}>{remote.failureDetail}</Text>}
        <Text color={C.subtext0}>{message.hint}</Text>
        <Text color={C.overlay0}>Press o to open it in the browser.</Text>
      </Box>,
    )
    note(remote.failureDetail ? 4 : 3)
    return settleBlocks(ctx, io, blocks)
  }
  const { definition, problems } = await viewOf(ctx, io, record.kind)
  if (problems.length) {
    drawnParts.push(
      <Box key="view-problems" flexDirection="column" width={textWidth}>
        {problems.map((one, i) => (
          <Text key={`view-problem-${i}`} color={C.red} wrap="truncate-end">{problemLine(one)}</Text>
        ))}
      </Box>,
    )
    note(problems.length)
  }
  const env: RecordEnv = { ctx, io, blocks, remote, record, budget, linked, picture, navBase: 0, icons: definition?.icons ?? {}, colors: definition?.colors ?? {} }
  if (definition) {
    await drawProse(ctx, io, blocks, 'view', definition.template, { picture, record: (lang, options, navStart) => recordParts(env, lang, options, navStart) })
    return settleBlocks(ctx, io, blocks)
  }
  drawHeader(env, {})
  drawFields(env, { from: 'meta', title: 'Details', icon: 'kind', detail: 'status', color: 'kind' })
  drawFields(env, { from: 'stats', title: 'Changes', icon: 'gh-pr', color: 'green' })
  const lists = () => {
    for (const [li, list] of (record.lists ?? []).entries()) {
      const more = list.total > list.items.length || list.isPartial
      sectionRule(env, `list-head-${li}`, list.heading, more ? `${list.items.length} of ${list.isPartial ? `${list.total}+` : list.total}` : `${list.total}`)
      drawnParts.push(
        <Box key={`list-${li}`} flexDirection="column" width={textWidth}>
          {list.items.length === 0 && <Text color={C.overlay0}>None open.</Text>}
          {list.items.map((item, i) => {
            const meta = [item.status, item.meta].filter(Boolean).join(' · ')
            return (
              <Box key={`list-${li}-${i}`} flexDirection="row" justifyContent="space-between" width={textWidth} height={1} hover={{ backgroundColor: C.surface0 }}>
                <Box flexShrink={1} overflow="hidden" height={1}>
                  <Button key={`list-item-${li}-${i}`} label={fitName(item.title, Math.max(8, textWidth - meta.length - 2))} plain onPress={() => void openFromPage(io, item.href)} />
                </Box>
                <Box flexShrink={0}>
                  <Text color={C.overlay0}>{meta}</Text>
                </Box>
              </Box>
            )
          })}
          {more && <Text color={C.overlay0}>{`showing ${list.items.length} of ${list.isPartial ? 'many' : list.total} · press o for the rest in the browser`}</Text>}
        </Box>,
      )
      note(Math.max(1, list.items.length) + (more ? 1 : 0), list.heading)
    }
  }
  const description = () => drawMedia(env, { from: 'body', title: BODY_LABEL[record.kind] ?? 'Description' })
  const lead = record.kind === 'slack-thread' ? record.lead : undefined
  if (lead) {
    sectionRule(env, 'thread-head', 'Thread', record.status ?? '')
    await slackThread({ ctx, io, remote, blocks, budget, linked }, lead, record.comments?.shown ?? [])
  } else if (LISTS_FIRST.has(record.kind)) {
    lists()
    await description()
  } else {
    await description()
    lists()
  }
  if (!lead) await drawComments(env, { from: 'comments', title: 'Comments' })
  return settleBlocks(ctx, io, blocks)
}
