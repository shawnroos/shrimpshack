import type { EngineInterface, Register } from 'claude-code'
import type { BandProps, BandSelection } from './band.tsx'

import { ContractView } from './contract'
import { contractControls, focusContractRow, isContractRow, resetContract } from './contract-state'
import { getSelection, onSelect, select } from './selection'
import type { Selection } from './selection'
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

async function openView($: EngineInterface): Promise<{ text: string }> {
  const homes = await leaseHomes($)
  if (homes.length === 0) {
    return { text: 'This session drives no auto programme, so there is no programme view to show.' }
  }
  await $.ui.open({ id: PANE, title: 'Programme' })
  mode = 'work'
  resetContract()
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

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const ui = $.ui.resolve(e)
    const { Box, Button, Text } = ui
    const found = await loadView($).catch(
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

    const { work } = found
    const { contract, reread, spaces } = found.parts
    shown = work
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
        : WorkView(ui, {
            work,
            selection: getSelection(),
            onSelect: target => void selectRow($, { ...target, item: target.item ?? '' }),
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
    const found = await loadView($).catch(() => undefined)
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
