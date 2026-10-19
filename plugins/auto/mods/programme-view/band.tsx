import type { ClientElements } from 'claude-code'

export type StepKind = 'done' | 'current' | 'waiting' | 'planned'
export type BandStep = { kind: StepKind; title: string }
export type BandEntry = {
  id: string
  title: string
  steps: BandStep[]
  finish: string | null
  noPlan: boolean
  location: string | null
  changeHash: string | null
  marked: boolean
}
export type BandSelection = { item?: string; step?: number }
export type BandProps = { work: BandEntry[]; columns: number; maxLines: number; selection: BandSelection }
export type BandKey = { key: string; shift?: boolean }
export type Span = { text: string; color?: string; dim?: boolean; bold?: boolean; inverse?: boolean; step?: number }
export type Hit = { line: number; x0: number; x1: number; item: string; step: number }
export type BandLayout = { lines: Span[][]; hits: Hit[]; shown: string[]; more: number }

export const GLYPH = {
  done: '',
  planned: '',
  current: '',
  waiting: '\u{F051F}',
  goal: '',
  pane: '',
  changed: '',
  capLeft: '',
  capRight: '',
}

const COLOR = { done: 'success', active: 'claude', next: 'suggestion', marked: 'warning' }
const TITLE_COLUMNS = 24
const LOCATION_COLUMNS = 32
const SHORTEN_OVER = 8
const SEPARATOR = '  │  '
const MORE_ROOM = 10
const STEP_KINDS = new Set<string>(['done', 'current', 'waiting', 'planned'])

function text(value: unknown): string | null {
  return typeof value === 'string' && value !== '' ? value : null
}

export function readWork(raw: unknown): BandEntry[] {
  if (!Array.isArray(raw)) return []
  const out: BandEntry[] = []
  for (const value of raw) {
    if (typeof value !== 'object' || value === null) continue
    const entry = value as Record<string, unknown>
    const id = text(entry.id)
    if (id === null) continue
    const steps = (Array.isArray(entry.steps) ? entry.steps : [])
      .filter((s): s is Record<string, unknown> => typeof s === 'object' && s !== null && STEP_KINDS.has(String(s.kind)))
      .map(s => ({ kind: s.kind as StepKind, title: String(s.title ?? '') }))
    out.push({
      id,
      title: String(entry.title ?? ''),
      steps,
      finish: text(entry.finish),
      noPlan: entry.no_plan === true,
      location: text(entry.location),
      changeHash: text(entry.change_hash),
      marked: false,
    })
  }
  return out
}

export function columns(value: string): number {
  return [...value].length
}

function truncate(value: string, limit: number): string {
  const chars = [...value]
  return chars.length <= limit ? value : `${chars.slice(0, limit - 1).join('')}…`
}

export function lineText(spans: Span[]): string {
  return spans.map(span => span.text).join('')
}

function activeStep(entry: BandEntry): number {
  return entry.steps.findIndex(step => step.kind === 'current' || step.kind === 'waiting')
}

export function currentStep(entry: BandEntry): number {
  const active = activeStep(entry)
  if (active !== -1) return active
  const planned = entry.steps.findIndex(step => step.kind === 'planned')
  return planned === -1 ? Math.max(0, entry.steps.length - 1) : planned
}

function selectedStep(entry: BandEntry, selection: BandSelection): number {
  const step = selection.step
  return typeof step === 'number' && step >= 0 && step < entry.steps.length ? step : currentStep(entry)
}

function stepColor(entry: BandEntry, index: number): string | undefined {
  const active = activeStep(entry)
  const next = active === -1 ? entry.steps.findIndex(step => step.kind === 'planned') : active + 1
  if (entry.steps[index]?.kind === 'done') return COLOR.done
  if (index === active) return COLOR.active
  return index === next ? COLOR.next : undefined
}

const STEP_GLYPH: Record<StepKind, string> = {
  done: GLYPH.done,
  current: GLYPH.current,
  waiting: GLYPH.waiting,
  planned: GLYPH.planned,
}

function link(entry: BandEntry, previous: number, index: number): string {
  if (index - previous > 1) return '…'
  return entry.steps[previous]?.kind === 'done' ? '━' : '┄'
}

function visibleSteps(entry: BandEntry, selected: number | undefined): number[] {
  const all = entry.steps.map((_, index) => index)
  if (all.length <= SHORTEN_OVER) return all
  const current = currentStep(entry)
  const keep = new Set([current, current + 1])
  if (entry.steps[0]?.kind === 'done') keep.add(0)
  if (selected !== undefined) keep.add(selected)
  return all.filter(index => keep.has(index))
}

function track(entry: BandEntry, selected: number | undefined): Span[] {
  const shown = visibleSteps(entry, selected)
  const spans: Span[] = []
  let previous: number | undefined
  for (const index of shown) {
    const step = entry.steps[index]
    if (!step) continue
    if (previous !== undefined) spans.push({ text: link(entry, previous, index), dim: true })
    previous = index
    const color = stepColor(entry, index)
    if (index === selected) {
      const label = `${step.kind === 'waiting' ? `${GLYPH.waiting} ` : ''}${truncate(step.title, TITLE_COLUMNS)}`
      spans.push(
        { text: GLYPH.capLeft, color, step: index },
        { text: ` ${label} `, color, inverse: true, step: index },
        { text: GLYPH.capRight, color, step: index },
      )
    } else {
      spans.push({ text: STEP_GLYPH[step.kind], color, step: index })
    }
  }
  const last = shown.at(-1)
  if (last !== undefined) spans.push({ text: last < entry.steps.length - 1 ? '…' : '┄', dim: true })
  return spans
}

function entrySpans(entry: BandEntry, focused: boolean, selection: BandSelection): Span[] {
  const spans: Span[] = [{ text: `${truncate(entry.title, TITLE_COLUMNS)} `, bold: focused }]
  if (entry.noPlan || entry.steps.length === 0) {
    spans.push({ text: 'no plan yet', dim: true })
  } else {
    spans.push(...track(entry, focused ? selectedStep(entry, selection) : undefined), { text: `${GLYPH.goal} ` })
    if (entry.finish) spans.push({ text: truncate(entry.finish, TITLE_COLUMNS), dim: true })
  }
  if (entry.marked) spans.push({ text: ` ${GLYPH.changed}`, color: COLOR.marked })
  if (focused && entry.location) {
    spans.push({ text: `  ${GLYPH.pane} ${truncate(entry.location, LOCATION_COLUMNS)}`, dim: true })
  }
  return spans
}

function pack(order: BandEntry[], width: number, selection: BandSelection, maxLines: number) {
  const lines: Span[][] = [[]]
  const stepHits: Hit[] = []
  const entryHits: Hit[] = []
  const shown: string[] = []
  let x = 0
  for (const entry of order) {
    const spans = entrySpans(entry, entry.id === selection.item, selection)
    const need = columns(lineText(spans))
    const limit = width - (lines.length === maxLines ? MORE_ROOM : 0)
    if (x > 0 && x + columns(SEPARATOR) + need > limit) {
      if (lines.length >= maxLines) break
      lines.push([])
      x = 0
    }
    const line = lines.length - 1
    const row = lines[line] ?? []
    if (x > 0) {
      row.push({ text: SEPARATOR, dim: true })
      x += columns(SEPARATOR)
    }
    const start = x
    for (const span of spans) {
      const end = x + columns(span.text)
      if (span.step !== undefined) stepHits.push({ line, x0: x, x1: end, item: entry.id, step: span.step })
      row.push(span)
      x = end
    }
    entryHits.push({ line, x0: start, x1: x, item: entry.id, step: currentStep(entry) })
    shown.push(entry.id)
  }
  return { lines, hits: [...stepHits, ...entryHits], shown }
}

export function bandLayout(work: BandEntry[], width: number, selection: BandSelection, maxLines = 2): BandLayout {
  let packed = pack(work, width, selection, maxLines)
  const focused = work.find(entry => entry.id === selection.item)
  if (focused && !packed.shown.includes(focused.id)) {
    const others = work.filter(entry => entry !== focused)
    for (let slot = packed.shown.length - 1; slot >= 0; slot -= 1) {
      const order = [...others.slice(0, slot), focused, ...others.slice(slot)]
      if (pack(order, width, selection, maxLines).shown.length > slot) {
        packed = pack(order.slice(0, slot + 1), width, selection, maxLines)
        break
      }
    }
  }
  const more = work.length - packed.shown.length
  if (more > 0) packed.lines.at(-1)?.push({ text: `  +${more} more`, bold: true })
  return { lines: packed.lines, hits: packed.hits, shown: packed.shown, more }
}

export function selectionAt(layout: BandLayout, x: number, y: number): Required<BandSelection> | undefined {
  const hit = layout.hits.find(h => h.line === y && x >= h.x0 && x < h.x1)
  return hit ? { item: hit.item, step: hit.step } : undefined
}

export function moveSelection(
  work: BandEntry[],
  selection: BandSelection,
  key: BandKey,
): Required<BandSelection> | undefined {
  const index = work.findIndex(entry => entry.id === selection.item)
  if (key.key === 'tab') {
    if (work.length === 0) return undefined
    const step = key.shift ? -1 : 1
    const fresh = key.shift ? work.length - 1 : 0
    const next = index === -1 ? fresh : (index + step + work.length) % work.length
    const entry = work[next]
    return entry ? { item: entry.id, step: currentStep(entry) } : undefined
  }
  const entry = work[index]
  if (!entry || (key.key !== 'left' && key.key !== 'right')) return undefined
  const at = selectedStep(entry, selection)
  const last = Math.max(0, entry.steps.length - 1)
  return { item: entry.id, step: key.key === 'right' ? Math.min(last, at + 1) : Math.max(0, at - 1) }
}

export function drawBand(elements: Pick<ClientElements, 'Box' | 'Text'>, layout: BandLayout) {
  const { Box, Text } = elements
  return Box({
    flexDirection: 'column',
    children: layout.lines.map(line =>
      Text({
        wrap: 'truncate',
        children: line.map(span =>
          Text({
            children: span.text,
            ...(span.color !== undefined && { color: span.color }),
            ...(span.dim === true && { dimColor: true }),
            ...(span.bold === true && { bold: true }),
            ...(span.inverse === true && { inverse: true }),
          }),
        ),
      }),
    ),
  })
}
