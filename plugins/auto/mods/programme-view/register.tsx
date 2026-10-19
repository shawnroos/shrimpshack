import type { EngineInterface, Register } from 'claude-code'
import { readWork } from './band.tsx'
import type { BandEntry, BandProps, BandSelection } from './band.tsx'

import { UI_ORIGIN_ARGS, minutesOf, proposeArgv, runVerb, toolsOf } from './actions'
import type { Draft, Outcome } from './actions'
import { ContractView, draftText, noteKey, optionRowKey, termRowKey, toolEditKey, whyKey } from './contract'
import type { Contract, Reread, Term } from './contract'
import { getSelection, onSelect, select, viewedKey } from './selection'
import type { Selection } from './selection'
import { WorkView, itemRowKey, liveAge, stepRowKey } from './tree'
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
      parts?: { work: WorkEntry[]; contract: Contract; reread: Reread; spaces: string[] }
    }

let polling = false
let lastStamp: string | undefined
let band: BandProps | undefined
let mode: 'work' | 'contract' = 'work'
let openTerm: string | undefined
let focusedRow: string | undefined
let rowTargets = new Map<string, Selection & { item: string }>()
let workHashes = new Map<string, string | null>()
let drafts: Record<string, Draft> = {}
let editing: string | undefined
let status: Outcome | undefined


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

function spacesOf(model: unknown): string[] {
  const spaces = (model as { remit?: { spaces?: unknown } } | undefined)?.remit?.spaces
  if (!Array.isArray(spaces)) return []
  return spaces
    .map(space => space as { server?: unknown; workspace?: unknown })
    .filter(space => typeof space?.server === 'string' && typeof space.workspace === 'string')
    .map(space => `${String(space.server)}.${String(space.workspace)}`)
}

function partsOf(view: { work?: unknown; contract?: Partial<Contract>; reread?: Partial<Reread>; model?: unknown }, nowMs: number) {
  const { work, contract, reread, model } = view
  if (!Array.isArray(work) || !contract || !reread) return
  return {
    spaces: spacesOf(model),
    work: work.map(entry => liveAge(entry, nowMs)) as WorkEntry[],
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
    return { kind: 'view', path, rows, generatedAt: String(view.generated_at ?? ''), parts: partsOf(view, await $.clock.now()) }
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
  drafts = {}
  editing = undefined
  status = undefined
  // Every session loads this mod; starting the timer here keeps it out of sessions that drive no programme.
  if (!polling) {
    polling = true
    onSelect(() => void $.ui.invalidate('ui.render'))
    lastStamp = await stamp($)
    let lastMinute = Math.floor((await $.clock.now()) / 60_000)
    $.clock.every(POLL_MS, async () => {
      const current = await stamp($).catch(() => lastStamp)
      const minute = Math.floor((await $.clock.now()) / 60_000)
      if (current !== lastStamp || minute !== lastMinute) {
        lastStamp = current
        lastMinute = minute
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
    if (view?.view_format !== VIEW_FORMAT || !Array.isArray(view.work)) return []
    const now = await $.clock.now()
    return readWork(view.work.map((entry: unknown) => liveAge(entry, now)))
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
  return key.startsWith('term:') || key.startsWith('option:') || key.startsWith('instruction:')
}

async function perform($: EngineInterface, argv: string[], done: string, after?: () => void) {
  const outcome = await runVerb($, argv)
  status = outcome.ok ? { ok: true, message: done } : outcome
  if (outcome.ok) after?.()
  await $.ui.invalidate('ui.render')
}

function focusedOption(term: Term): string | undefined {
  const prefix = optionRowKey(term.key, '')
  return focusedRow?.startsWith(prefix) ? focusedRow.slice(prefix.length) : undefined
}

function contractActions($: EngineInterface) {
  const redraw = () => $.ui.invalidate('ui.render')
  const refuse = async (message: string) => {
    status = { ok: false, message }
    await redraw()
  }
  const change = async (term: Term, next: Draft) => {
    drafts = { ...drafts, [term.key]: { ...drafts[term.key], ...next } }
    await redraw()
  }
  return {
    propose: async (term: Term) => {
      const stored = drafts[term.key] ?? {}
      const picked = Array.isArray(term.value) || stored.option ? undefined : focusedOption(term)
      const draft = picked ? { ...stored, option: picked } : stored
      const argv = proposeArgv(term, draft)
      if (typeof argv === 'string') return refuse(argv)
      await perform($, argv, `proposed ${term.label}: ${draftText(term, draft) ?? ''}`, () => {
        const { [term.key]: _sent, ...rest } = drafts
        drafts = rest
        if (editing === toolEditKey(term.key)) editing = undefined
      })
    },
    clear: (term: Term) => perform($, ['clear-proposal', term.key, ...UI_ORIGIN_ARGS], 'proposal cleared'),
    note: async (term: Term) => {
      editing = noteKey(term.key)
      await redraw()
    },
    saveNote: (term: Term, text: string) => {
      const argv = text.trim() ? ['note-term', term.key, text.trim()] : ['note-term', term.key, '--clear']
      return perform($, [...argv, ...UI_ORIGIN_ARGS], text.trim() ? 'note saved' : 'notes cleared', () => {
        editing = undefined
      })
    },
    reread: () => perform($, ['request-reread', ...UI_ORIGIN_ARGS], 're-read requested'),
    fulfil: async (id: string) => {
      editing = whyKey(id)
      await redraw()
    },
    closeAsFulfilled: (id: string, why: string) => {
      if (!why.trim()) return refuse('say why the instruction is fulfilled')
      return perform($, ['close-instruction', id, '--as', 'fulfilled', '--why', why.trim(), ...UI_ORIGIN_ARGS], 'instruction closed as fulfilled', () => {
        editing = undefined
      })
    },
    minutes: async (term: Term, text: string) => {
      const minutes = minutesOf(text)
      if (!minutes) return refuse(`"${text}" is not a whole number of minutes`)
      status = undefined
      await change(term, { minutes, option: undefined })
    },
    space: (term: Term, space: string) => change(term, { space, option: undefined }),
    addTool: async (term: Term) => {
      editing = toolEditKey(term.key)
      await redraw()
    },
    toolName: (term: Term, name: string) => change(term, { add: { ...drafts[term.key]?.add, name: name.trim() } }),
    toolDescription: (term: Term, description: string) =>
      change(term, { add: { ...drafts[term.key]?.add, description: description.trim() } }),
    focusRow: async (key: string) => {
      focusedRow = key
      await redraw()
    },
  }
}

function pickOption(contract: Contract, key: string, option: string) {
  const term = contract.terms.find(one => one.key === key)
  if (!term) return
  const draft = drafts[key] ?? {}
  if (Array.isArray(term.value)) {
    const tools = toolsOf(term, draft)
    const next = tools.includes(option) ? tools.filter(tool => tool !== option) : [...tools, option]
    drafts = { ...drafts, [key]: { ...draft, tools: next } }
    return
  }
  drafts = { ...drafts, [key]: { ...draft, option, minutes: undefined, space: undefined } }
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
  const hashed = work.filter(entry => entry.change_hash)
  const viewed = await Promise.all(hashed.map(entry => $.store.get(viewedKey(entry.id)).catch(() => {})))
  return Object.fromEntries(hashed.map((entry, index) => [entry.id, viewed[index]]))
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

    const { work, contract, reread, spaces } = found.parts
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
            selectedItem: getSelection().item,
            armed: e.props.isFocused === true,
            drafts,
            editing,
            status,
            spaces,
            onToggle: async key => {
              openTerm = openTerm === key ? undefined : key
              focusedRow = termRowKey(key)
              await $.ui.invalidate('ui.render')
            },
            onOption: async (term, option) => {
              focusedRow = optionRowKey(term, option)
              pickOption(contract, term, option)
              await $.ui.invalidate('ui.render')
            },
            act: contractActions($),
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
