import type { EngineInterface, Register } from 'claude-code'
import { readWork } from './band.tsx'
import type { BandEntry, BandProps, BandSelection } from './band.tsx'
import { getSelection, onSelect, select, viewedKey } from './selection.ts'

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
  | { kind: 'view'; path: string; rows: Row[]; generatedAt: string }

let polling = false
let lastStamp: string | undefined
let band: BandProps | undefined
let selectionWired = false

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
    return { kind: 'view', path, rows, generatedAt: String(view.generated_at ?? '') }
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
  // Every session loads this mod; starting the timer here keeps it out of sessions that drive no programme.
  if (!polling) {
    polling = true
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
    const { Box, Text } = $.ui.resolve(e)
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
}
