import type { EngineInterface, Register } from 'claude-code'
import type { BandProps, BandSelection } from './band.tsx'

import { ContractView } from './contract'
import { contractControls, focusContractRow, isContractRow, resetContract } from './contract-state'
import { getSelection, onSelect, select } from './selection'
import type { Selection } from './selection'
import { DecisionsView, SetupBand, SetupView } from './setup'
import { WorkView, itemRowKey, stepRowKey } from './tree'
import { leaseHomes, loadView, markViewed, stamp } from './view'
import type { Found, WorkItem } from './view'

const PANE = 'programme-view'
const POLL_MS = 2000

let polling = false
let lastStamp: string | undefined
let band: BandProps | undefined
let mode: 'work' | 'contract' = 'work'
let shown: WorkItem[] = []

const SETUP_COMMAND = 'auto:programme'
const STATUS_COMMAND = 'auto:programme-status'
const SETUP_WAIT_MS = 60_000

let waitingSince: number | undefined
let waitExpired = false

async function startPolling($: EngineInterface) {
  // Every session loads this mod; starting the timer only from a command keeps it out of sessions that drive no programme.
  if (polling) return
  polling = true
  onSelect(() => void $.ui.invalidate('ui.render'))
  lastStamp = await stamp($)
  let lastMinute = Math.floor((await $.clock.now()) / 60_000)
  $.clock.every(POLL_MS, async () => {
    const current = await stamp($).catch(() => lastStamp)
    const now = await $.clock.now()
    const minute = Math.floor(now / 60_000)
    const expired = waitingSince !== undefined && now - waitingSince >= SETUP_WAIT_MS
    if (current !== lastStamp || minute !== lastMinute || expired !== waitExpired) {
      lastStamp = current
      lastMinute = minute
      waitExpired = expired
      await $.ui.invalidate('ui.render')
    }
  })
}

async function showPane($: EngineInterface, focus = false) {
  const opened = await $.ui.open({ id: PANE, title: 'Programme', ...(focus && { focus: true as const }) })
  mode = 'work'
  resetContract()
  await startPolling($)
  return opened
}

async function openView($: EngineInterface): Promise<{ text: string }> {
  const homes = await leaseHomes($)
  if (homes.length === 0) {
    return { text: 'This session drives no auto programme, so there is no programme view to show.' }
  }
  await showPane($)
  return { text: 'Programme view opened.' }
}

async function openForSetup($: EngineInterface): Promise<string | undefined> {
  if ((await leaseHomes($)).length === 0) {
    waitingSince = await $.clock.now()
    waitExpired = false
  }
  const opened = await showPane($)
  if (opened.isPlaced) return
  return `The Programme pane could not open here (${opened.reason}). Make the first line of your reply: "Run /programme-view to open the Programme pane." Then carry on with setup in the chat.`
}

function waitingText(): string {
  return waitExpired
    ? 'Setup has not started. Run /auto:programme to start it.'
    : 'Waiting for setup to start. The view appears once the PM takes the programme.'
}

function readPick(data: unknown, work: WorkItem[]): Required<BandSelection> | undefined {
  const picked = (data as { select?: { item?: unknown; step?: unknown } } | null)?.select
  const entry = work.find(w => w.id === picked?.item)
  if (!entry || typeof picked?.step !== 'number' || !Number.isInteger(picked.step)) return undefined
  return { item: entry.id, step: Math.min(Math.max(0, picked.step), Math.max(0, entry.steps.length - 1)) }
}

function rowTarget(element: string): (Selection & { item: string }) | undefined {
  for (const item of shown) {
    if (element === itemRowKey(item.id)) return { item: item.id }
    const step = item.steps.findIndex((_, index) => element === stepRowKey(item.id, index))
    if (step !== -1) return { item: item.id, step }
  }
}

async function selectRow($: EngineInterface, target: Selection & { item: string }) {
  select(target.step === undefined ? { item: target.item } : { item: target.item, step: target.step })
  await markViewed($, shown.find(item => item.id === target.item))
  await $.ui.invalidate('ui.render')
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

  on('command.run', { command: SETUP_COMMAND }, async ($, e, next) => {
    const note = await openForSetup($).catch(() => undefined)
    const result = await next(e)
    return note ? { ...result, context: [...(result.context ?? []), note] } : result
  })

  on('command.run', { command: STATUS_COMMAND }, async ($, e, next) => {
    if (e.args.trim() !== '' || (await leaseHomes($).catch(() => [])).length === 0) return next(e)
    const opened = await showPane($, true).catch(() => undefined)
    if (!opened?.isPlaced) return next(e)
    return { text: 'Programme status is in the Programme pane beside the chat.' }
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const ui = $.ui.resolve(e)
    const { Box, Button, Text } = ui
    const found = await loadView($).catch(
      (error): Found => ({ kind: 'unreadable', path: 'the programme view', why: String(error) }),
    )
    const waiting = waitingSince !== undefined && (found.kind === 'none' || found.kind === 'missing')
    if (waiting) return <Text dimColor>{waitingText()}</Text>
    waitingSince = undefined
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

    const { work, setup, decisions } = found
    const { contract, reread, spaces } = found.parts
    shown = setup ? [] : work
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
    const main = setup ? { hotkey: 's', label: 'setup' } : { hotkey: 'w', label: 'work' }
    const header = e.props.isFocused ? (
      <Box key="line:views" flexDirection="row" gap={2}>
        {toggle('work', main.hotkey, main.label)}
        {toggle('contract', 'c', 'contract')}
      </Box>
    ) : (
      <Box key="line:views" flexDirection="row">
        <Text dimColor>
          {mode === 'work' ? (setup ? 'Setup' : 'Work') : 'Contract'} · click the pane, then {main.hotkey} {main.label} · c contract
        </Text>
      </Box>
    )
    const mainView = () =>
      setup
        ? SetupView(ui, { setup, decisions })
        : [
            WorkView(ui, {
              work,
              selection: getSelection(),
              onSelect: target => void selectRow($, { ...target, item: target.item ?? '' }),
            }),
            DecisionsView(ui, decisions),
          ]
    const body =
      mode === 'contract'
        ? ContractView(ui, {
            contract,
            reread,
            spaces,
            itemTitles: Object.fromEntries(work.map(entry => [entry.id, entry.title])),
            selectedItem: getSelection().item,
            armed: e.props.isFocused === true,
            ...contractControls($, contract),
          })
        : mainView()
    return (
      <Box flexDirection="column">
        {header}
        {body}
      </Box>
    )
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (!polling || e.surface !== 'terminal' || e.props.hasSurvey) return next(e)
    const found = await loadView($).catch(() => undefined)
    if (found?.kind === 'view' && found.setup) {
      band = undefined
      return SetupBand($.ui.resolve(e), found.setup)
    }
    const work = found?.kind === 'view' ? found.work : []
    if (work.length === 0) return next(e)
    band = { work, columns: e.props.bodyColumns, maxLines: Math.max(1, Math.min(2, e.props.maxRows)), selection: getSelection() }
    const { Client } = $.ui.resolve(e)
    return <Client key="band" module="./band-keys.tsx" props={band} width={e.props.bodyColumns} />
  })

  on('ui.message', async ($, e, next) => {
    if (e.element !== 'band' || !band) return next(e)
    const picked = readPick(e.data, band.work)
    if (!picked) return next(e)
    await markViewed($, band.work.find(w => w.id === picked.item))
    band = {
      ...band,
      selection: picked,
      work: band.work.map(w => (w.id === picked.item ? { ...w, changed: false } : w)),
    }
    select(picked)
    return { props: band }
  })

  on('ui.focus', { component: 'Pane', requestId: PANE }, async ($, e, next) => {
    const element = e.element ?? ''
    if (e.origin.kind === 'person') {
      const target = rowTarget(element)
      if (target) await selectRow($, target)
      if (target || isContractRow(element)) {
        if (isContractRow(element)) focusContractRow(element)
        await $.ui.scroll({ in: PANE, to: { key: element }, block: 'nearest' }).catch(() => {})
        await $.ui.invalidate('ui.render')
      }
    }
    return next(e)
  })
}
