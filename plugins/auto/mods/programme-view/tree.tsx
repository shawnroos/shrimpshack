import type { Elements, RenderElement } from 'claude-code'

import { COLOR, GLYPH } from './palette'
import type { Selection } from './selection'

export type Ui = Elements['terminal']

export type Step = {
  kind: 'done' | 'current' | 'waiting' | 'planned'
  title: string
  clause: string | null
  clause_label: string
  no_clause: boolean
}

export type Watch = {
  state: 'watcher_live' | 'reporter_only' | 'retry_never_started' | 'nothing_watching'
  interval_seconds?: number | null
  beat_age_seconds?: number | null
  reporter?: string
}

export type WorkEntry = {
  id: string
  title: string
  state: string
  location: string | null
  no_plan: boolean
  steps: Step[]
  finish: string | null
  age_seconds: number | null
  faded: boolean
  change_hash: string | null
  changed_since_first: boolean
  watch: Watch | null
}

export type TreeProps = {
  work: WorkEntry[]
  viewed: Record<string, unknown>
  selection: Selection
  onSelect: (target: Selection) => void
}

export function duration(seconds: number): string {
  if (seconds < 60) return `${seconds}s`
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`
  const minutes = Math.floor((seconds % 3600) / 60)
  return `${Math.floor(seconds / 3600)}h${minutes ? ` ${minutes}m` : ''}`
}

export function planChanged(entry: WorkEntry, viewed: unknown): boolean {
  return Boolean(entry.change_hash) && entry.changed_since_first && viewed !== entry.change_hash
}

function watchText(watch: Watch | null): { text: string; isWarning: boolean } {
  switch (watch?.state) {
    case 'watcher_live': {
      if (watch.interval_seconds) return { text: `watcher live · every ${duration(watch.interval_seconds)}`, isWarning: false }
      if (watch.beat_age_seconds != null) return { text: `watcher live · ${duration(watch.beat_age_seconds)}`, isWarning: false }
      return { text: 'watcher live', isWarning: false }
    }
    case 'reporter_only': {
      return { text: `named reporter only${watch.reporter ? ` (${watch.reporter})` : ''}`, isWarning: false }
    }
    case 'retry_never_started': {
      return { text: 'retry never started', isWarning: false }
    }
    default: {
      return { text: 'nothing watching', isWarning: true }
    }
  }
}

export function stepRowKey(item: string, index: number): string {
  return `step:${item}:${index}`
}

export function itemRowKey(item: string): string {
  return `item:${item}`
}

function clauseTail(ui: Ui, step: Step): RenderElement[] {
  const { Text } = ui
  if (step.no_clause) {
    return [<Text>{' '.repeat(3)}</Text>, <Text color={COLOR.warning}>{GLYPH.warning}</Text>, <Text dimColor> no clause</Text>]
  }
  return [<Text dimColor>{`   ${GLYPH.clause} ${step.clause_label}`}</Text>]
}

function tree(ui: Ui, entry: WorkEntry, props: TreeProps): RenderElement[] {
  const { Box, Button, Text } = ui
  const dim = entry.faded
  const pick = (target: Selection) => () => props.onSelect(target)
  const selected = (step?: number) => props.selection.item === entry.id && props.selection.step === step
  const bar = (step?: number) => <Text color={COLOR.accent}>{selected(step) ? '▌' : ' '}</Text>
  const focus = (step?: number) => (selected(step) ? { autoFocus: true as const } : {})
  const row = (key: string, last: boolean, step: number, ...cells: RenderElement[]) => (
    <Box key={`line:${key}`} flexDirection="row">
      {bar(step)}
      <Text dimColor>{last ? ' └─ ' : ' ├─ '}</Text>
      {cells}
    </Box>
  )
  const head = (
    <Box key={`line:${itemRowKey(entry.id)}`} flexDirection="row">
      {bar()}
      <Text color={dim ? undefined : COLOR.accent} dimColor={dim}>{`${GLYPH.item} `}</Text>
      <Button key={itemRowKey(entry.id)} label={entry.title} plain {...focus()} onPress={pick({ item: entry.id })}>
        <Text bold dimColor={dim}>{entry.title}</Text>
      </Button>
      {entry.location ? <Text dimColor>{`   ${GLYPH.pane} ${entry.location}`}</Text> : <Text>{''}</Text>}
      {entry.age_seconds == null ? <Text>{''}</Text> : <Text dimColor>{` · ${duration(entry.age_seconds)}`}</Text>}
      {planChanged(entry, props.viewed[entry.id])
        ? [<Text color={COLOR.changed}>{`  ${GLYPH.changed}`}</Text>, <Text dimColor={dim}> plan changed</Text>]
        : []}
    </Box>
  )

  if (entry.no_plan) return [head, row(`${entry.id}:none`, true, -1, <Text dimColor>no plan yet</Text>)]

  const rows: RenderElement[] = [head]
  const done = entry.steps.map((s, index) => ({ s, i: index })).filter(({ s }) => s.kind === 'done')
  const lastDone = done.at(-1)
  const stepButton = (index: number, text: string, bold = false) => (
    <Button key={stepRowKey(entry.id, index)} label={text} plain {...focus(index)} onPress={pick({ item: entry.id, step: index })}>
      <Text bold={bold} dimColor={dim}>{text}</Text>
    </Button>
  )

  if (lastDone) {
    rows.push(
      row(
        `${entry.id}:done`,
        false,
        lastDone.i,
        <Text color={dim ? undefined : COLOR.done}>{`${GLYPH.doneCount} `}</Text>,
        stepButton(lastDone.i, `${done.length} done  ·  last: ${lastDone.s.title}`),
      ),
    )
  } else {
    rows.push(row(`${entry.id}:done`, false, -1, <Text dimColor>{`${GLYPH.doneCount} 0 done`}</Text>))
  }

  let planned = 0
  for (const [i, s] of entry.steps.entries()) {
    if (s.kind === 'done') continue
    const key = `${entry.id}:${i}`
    if (s.kind === 'current' || s.kind === 'waiting') {
      const waiting = s.kind === 'waiting'
      const watch = waiting ? watchText(entry.watch) : undefined
      rows.push(
        row(
          key,
          false,
          i,
          <Text color={dim ? undefined : COLOR[s.kind]}>{`${waiting ? GLYPH.waiting : GLYPH.current} `}</Text>,
          stepButton(i, s.title, true),
          ...(watch?.isWarning
            ? [<Text color={COLOR.warning}>{`   ${GLYPH.warning}`}</Text>, <Text>{` ${watch.text}`}</Text>]
            : [<Text>{watch ? `   ${watch.text}` : ''}</Text>]),
          ...clauseTail(ui, s),
        ),
      )
      continue
    }
    planned += 1
    const isNext = planned === 1
    rows.push(
      row(
        key,
        false,
        i,
        <Text color={isNext && !dim ? COLOR.next : undefined}>{`${GLYPH.planned} `}</Text>,
        stepButton(i, `${planned}. ${s.title}`),
        ...clauseTail(ui, s),
      ),
    )
  }

  rows.push(
    row(`${entry.id}:finish`, true, -1, <Text>{`${GLYPH.finish} `}</Text>, <Text dimColor={dim}>{entry.finish ?? 'no finish recorded'}</Text>),
  )
  return rows
}

export function WorkView(ui: Ui, props: TreeProps): RenderElement {
  const { Box, Text } = ui
  if (props.work.length === 0) {
    return (
      <Box key="line:empty" flexDirection="row">
        <Text dimColor>No open or waiting work.</Text>
      </Box>
    )
  }
  const out: RenderElement[] = []
  for (const [index, entry] of props.work.entries()) {
    if (index > 0) {
      out.push(
        <Box key={`line:gap:${entry.id}`} flexDirection="row">
          <Text> </Text>
        </Box>,
      )
    }
    out.push(...tree(ui, entry, props))
  }
  return <Box flexDirection="column">{out}</Box>
}
