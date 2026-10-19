import type { EngineInterface, Register } from 'claude-code'
import { readWork } from './band.tsx'
import type { BandEntry, BandProps, BandSelection } from './band.tsx'

import { ContractView, optionRowKey, termRowKey } from './contract'
import type { Contract, Reread } from './contract'
import { getSelection, onSelect, select, viewedKey } from './selection'
import type { Selection } from './selection'
import { WorkView, itemRowKey, stepRowKey } from './tree'
import type { WorkEntry } from './tree'

const PANE = 'programme-view'
const VIEW_FORMAT = 2
const POLL_MS = 2000
const DEFAULT_DATA_DIR = '/.claude/plugins/data/auto-shrimpshack'
const ROW_CAP = 2000

type Row = { style: string; text: string }
type Found =
  | { kind: 'none' }
  | { kind: 'several'; homes: string[] }
  | { kind: 'missing'; path: string }
  | { kind: 'unreadable'; path: string; why: string }
  | {
      kind: 'view'
      path: string
      rows: Row[]
      generatedAt: string
      parts?: { work: WorkEntry[]; contract: Contract; reread: Reread }
    }

let polling = false
let lastStamp: string | undefined
let band: BandProps | undefined
let selectionWired = false
let mode: 'work' | 'contract' = 'work'
let openTerm: string | undefined
let focusedRow: string | undefined
let rowTargets = new Map<string, Selection & { item: string }>()
let workHashes = new Map<string, string | null>()

async function dataDir($: EngineInterface): Promise<string> {
  const override = await $.env.get('CLAUDE_AUTO_DATA_DIR')
  if (override) return override
  return `${(await $.env.get('HOME')) ?? ''}${DEFAULT_DATA_DIR}`
}

async function leaseHomes($: EngineInterface): Promise<string[]> {
  const sessionId = await $.session.id()
  const folder = `${await dataDir($)}/programmes/leases`
  const entries = await $.fs.list(folder).catch(() => [])
  const homes = new Set<string>()
  for (const entry of entries) {
    if (entry.kind !== 'file' || entry.name.startsWith('.') || !entry.name.endsWith('.json')) continue
    const text = await $.fs.read(`${folder}/${entry.name}`).catch(() => '')
    let lease: { session_id?: unknown; run?: unknown; home?: unknown } = {}
    try {
      lease = JSON.parse(text)
    } catch {
      continue
    }
    const { session_id, run, home } = lease
    if (session_id !== sessionId || typeof run !== 'string' || typeof home !== 'string') continue
    if (home.endsWith(`/programmes/${run}`)) homes.add(home)
  }
  return [...homes].sort()
}

function partsOf(view: { work?: unknown; contract?: Partial<Contract>; reread?: Partial<Reread> }) {
  const { work, contract, reread } = view
  if (!Array.isArray(work) || !contract || !reread) return
  return {
    work: work as WorkEntry[],
    contract: {
      terms: Array.isArray(contract.terms) ? contract.terms : [],
      instructions: Array.isArray(contract.instructions) ? contract.instructions : [],
    },
    reread: {
      last_at: reread.last_at ?? null,
      changed_since: Array.isArray(reread.changed_since) ? reread.changed_since : [],
      requested: reread.requested === true,
    },
  }
}

async function findView($: EngineInterface): Promise<Found> {
  const homes = await leaseHomes($)
  if (homes.length === 0) return { kind: 'none' }
  if (homes.length > 1) return { kind: 'several', homes }
  const path = `${homes[0]}/views/view.json`
  const text = await $.fs.read(path).catch(() => undefined)
  if (text === undefined) return { kind: 'missing', path }
  try {
    const view = JSON.parse(text)
    if (view?.view_format !== VIEW_FORMAT || !Array.isArray(view.rows)) {
      return { kind: 'unreadable', path, why: `view format ${String(view?.view_format)}, expected ${VIEW_FORMAT}` }
    }
    const rows: Row[] = view.rows.map((row: Partial<Row>) => ({
      style: String(row?.style ?? 'text'),
      text: String(row?.text ?? '').slice(0, ROW_CAP),
    }))
    return { kind: 'view', path, rows, generatedAt: String(view.generated_at ?? ''), parts: partsOf(view) }
  } catch (error) {
    return { kind: 'unreadable', path, why: String(error) }
  }
}

async function stamp($: EngineInterface): Promise<string> {
  const homes = await leaseHomes($)
  const parts = await Promise.all(
    homes.map(async home => {
      const stat = await $.fs.stat(`${home}/views/view.json`).catch(() => undefined)
      return `${home}:${stat?.mtimeMs ?? 'missing'}`
    }),
  )
  return parts.join('|')
}

async function openView($: EngineInterface): Promise<{ text: string }> {
  const homes = await leaseHomes($)
  if (homes.length === 0) {
    return { text: 'This session drives no auto programme, so there is no programme view to show.' }
  }
  await $.ui.open({ id: PANE, title: 'Programme' })
  mode = 'work'
  openTerm = undefined
  focusedRow = undefined
  // Every session loads this mod; starting the timer here keeps it out of sessions that drive no programme.
  if (!polling) {
    polling = true
    onSelect(() => void $.ui.invalidate('ui.render'))
    lastStamp = await stamp($)
    $.clock.every(POLL_MS, async () => {
      const current = await stamp($).catch(() => lastStamp)
      if (current !== lastStamp) {
        lastStamp = current
        await $.ui.invalidate('ui.render')
      }
    })
  }

  return { text: 'Programme view opened.' }
}

async function readBandWork($: EngineInterface): Promise<BandEntry[]> {
  const homes = await leaseHomes($)
  if (homes.length !== 1) return []
  const text = await $.fs.read(`${homes[0]}/views/view.json`).catch(() => undefined)
  if (text === undefined) return []
  try {
    const view = JSON.parse(text)
    return view?.view_format === VIEW_FORMAT ? readWork(view.work) : []
  } catch {
    return []
  }
}

async function markChanged($: EngineInterface, work: BandEntry[]): Promise<BandEntry[]> {
  return Promise.all(
    work.map(async entry => {
      if (entry.changeHash === null) return entry
      const viewed = await $.store.get(viewedKey(entry.id)).catch(() => undefined)
      return { ...entry, marked: viewed !== entry.changeHash }
    }),
  )
}

function readPick(data: unknown, work: BandEntry[]): Required<BandSelection> | undefined {
  const picked = (data as { select?: { item?: unknown; step?: unknown } } | null)?.select
  const entry = work.find(w => w.id === picked?.item)
  if (!entry || typeof picked?.step !== 'number' || !Number.isInteger(picked.step)) return undefined
  return { item: entry.id, step: Math.min(Math.max(0, picked.step), Math.max(0, entry.steps.length - 1)) }
}

async function markViewed($: EngineInterface, target: Selection & { item: string }) {
  select(target.step === undefined ? { item: target.item } : { item: target.item, step: target.step })
  const hash = workHashes.get(target.item)
  if (hash) await $.store.set(viewedKey(target.item), hash)
  await $.ui.invalidate('ui.render')
}

function isContractRow(key: string): boolean {
  return key.startsWith('term:') || key.startsWith('option:')
}

function keepTargets(work: WorkEntry[]) {
  rowTargets = new Map()
  workHashes = new Map()
  for (const entry of work) {
    workHashes.set(entry.id, entry.change_hash)
    rowTargets.set(itemRowKey(entry.id), { item: entry.id })
    for (const index of entry.steps.keys()) rowTargets.set(stepRowKey(entry.id, index), { item: entry.id, step: index })
  }
}

async function viewedHashes($: EngineInterface, work: WorkEntry[]): Promise<Record<string, unknown>> {
  const out: Record<string, unknown> = {}
  for (const entry of work) {
    if (entry.change_hash) out[entry.id] = await $.store.get(viewedKey(entry.id)).catch(() => {})
  }
  return out
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'programme-view',
      description: "Show this session's auto programme: doing now, queue, waits, decisions, rules, items",
    })

    return next(e)
  })

  on('command.run', { command: 'programme-view' }, $ =>
    openView($).catch(error => ({ text: `Programme view failed: ${String(error)}` })),
  )

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const ui = $.ui.resolve(e)
    const { Box, Button, Text } = ui
    const found = await findView($).catch(
      (error): Found => ({ kind: 'unreadable', path: 'the programme view', why: String(error) }),
    )
    if (found.kind === 'none') return <Text dimColor>This session drives no auto programme.</Text>
    if (found.kind === 'several') {
      return <Text color="warning">This session holds several programmes: {found.homes.join(', ')}</Text>
    }
    if (found.kind === 'missing') {
      return <Text dimColor>No view yet. The next programme write creates {found.path}</Text>
    }
    if (found.kind === 'unreadable') {
      return <Text color="error">Cannot read {found.path}: {found.why}</Text>
    }

    if (!found.parts) {
      return (
        <Box flexDirection="column">
          {found.rows.map(row => (
            <Text
              bold={row.style === 'title' || row.style === 'head'}
              dimColor={row.style === 'dim'}
              color={row.style === 'warn' ? 'warning' : row.style === 'title' ? 'claude' : undefined}
            >
              {row.text}
            </Text>
          ))}
          <Text dimColor>view built {found.generatedAt}</Text>
        </Box>
      )
    }

    const { work, contract, reread } = found.parts
    keepTargets(work)
    const toggle = (next: typeof mode, hotkey: string, label: string) => (
      <Button
        key={`view:${next}`}
        label={label}
        plain
        hotkey={hotkey}
        dimColor={mode !== next}
        onPress={async () => {
          mode = next
          await $.ui.invalidate('ui.render')
        }}
      />
    )
    // Drawn only while the pane holds the keys, so neither hotkey can fire into the prompt.
    const header = e.props.isFocused ? (
      <Box key="line:views" flexDirection="row" gap={2}>
        {toggle('work', 'w', 'work')}
        {toggle('contract', 'c', 'contract')}
      </Box>
    ) : (
      <Box key="line:views" flexDirection="row">
        <Text dimColor>{mode === 'work' ? 'Work' : 'Contract'} · click the pane, then w work · c contract</Text>
      </Box>
    )
    const itemTitles = Object.fromEntries(work.map(entry => [entry.id, entry.title]))
    const body =
      mode === 'contract'
        ? ContractView(ui, {
            contract,
            reread,
            openTerm,
            focusedRow,
            itemTitles,
            onToggle: async key => {
              openTerm = openTerm === key ? undefined : key
              focusedRow = termRowKey(key)
              await $.ui.invalidate('ui.render')
            },
            onOption: async (term, option) => {
              focusedRow = optionRowKey(term, option)
              await $.ui.invalidate('ui.render')
            },
          })
        : WorkView(ui, {
            work,
            viewed: await viewedHashes($, work),
            selection: getSelection(),
            onSelect: target => void markViewed($, { ...target, item: target.item ?? '' }),
          })
    return (
      <Box flexDirection="column">
        {header}
        {body}
      </Box>
    )
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (!polling || e.surface !== 'terminal' || e.props.hasSurvey) return next(e)
    const work = await markChanged($, await readBandWork($).catch(() => []))
    if (work.length === 0) return next(e)
    if (!selectionWired) {
      selectionWired = true
      onSelect(() => void $.ui.invalidate('ui.render'))
    }
    band = { work, columns: e.props.bodyColumns, maxLines: Math.max(1, Math.min(2, e.props.maxRows)), selection: getSelection() }
    const { Client } = $.ui.resolve(e)
    return <Client key="band" module="./band-keys.tsx" props={band} width={e.props.bodyColumns} />
  })

  on('ui.message', async ($, e, next) => {
    if (e.element !== 'band' || !band) return next(e)
    const picked = readPick(e.data, band.work)
    if (!picked) return next(e)
    const entry = band.work.find(w => w.id === picked.item)
    if (entry?.changeHash) await $.store.set(viewedKey(picked.item), entry.changeHash)
    band = {
      ...band,
      selection: picked,
      work: band.work.map(w => (w.id === picked.item ? { ...w, marked: false } : w)),
    }
    select(picked)
    return { props: band }
  })

  on('ui.focus', { component: 'Pane', requestId: PANE }, async ($, e, next) => {
    const element = e.element ?? ''
    if (e.origin.kind === 'person') {
      const target = rowTargets.get(element)
      if (target) await markViewed($, target)
      if (target || isContractRow(element)) {
        if (isContractRow(element)) focusedRow = element
        await $.ui.scroll({ in: PANE, to: { key: element }, block: 'nearest' }).catch(() => {})
        await $.ui.invalidate('ui.render')
      }
    }
    return next(e)
  })
}
