import type { RenderElement } from 'claude-code'

import { COLOR, GLYPH } from './palette'
import type { Ui } from './tree'

export type Proposal = {
  value: unknown
  extras?: Record<string, unknown> | null
  at?: string
  origin?: string
  state: 'pending' | 'refused' | 'accepted' | 'superseded'
  reason?: string | null
}

export type Term = {
  key: string
  label: string
  value: unknown
  value_text: string
  description: string
  binding: 'code' | 'guidance' | 'none'
  reliant_steps: number
  set_by: string | null
  set_at: string | null
  why: string | null
  notes: { text?: string; at?: string }[]
  proposal: Proposal | null
  options: { name: string; description: string; active: boolean }[]
}

export type Instruction = { id: string; quote: string; applies_to: string; scope: 'own' | 'inherited'; reliant_steps: number }

export type Contract = { terms: Term[]; instructions: Instruction[] }

export type Reread = { last_at: string | null; changed_since: string[]; requested: boolean }

export type ContractProps = {
  contract: Contract
  reread: Reread
  openTerm: string | undefined
  focusedRow: string | undefined
  itemTitles: Record<string, string>
  onToggle: (key: string) => void
  onOption: (term: string, option: string) => void
  termActions?: (term: Term) => RenderElement[]
}

export const termRowKey = (key: string) => `term:${key}`
export const optionRowKey = (term: string, option: string) => `option:${term}:${option}`

const BINDING = {
  code: { glyph: GLYPH.code, color: COLOR.done, text: 'Checked in code' },
  guidance: { glyph: GLYPH.guide, color: COLOR.warning, text: 'Written guidance only, no code checks it' },
  none: { glyph: GLYPH.unread, color: COLOR.refused, text: 'Nothing reads it' },
} as const

function valueText(value: unknown): string {
  if (Array.isArray(value)) return value.map(String).join(', ') || 'none'
  return String(value ?? '')
}

function proposalText(proposal: Proposal): string {
  switch (proposal.state) {
    case 'refused': {
      return `refused: ${proposal.reason || 'no reason recorded'}`
    }
    case 'accepted':
    case 'superseded': {
      return proposal.state
    }
    default: {
      return 'pending'
    }
  }
}

function steps(count: number): string {
  if (count === 0) return 'No step relies on this'
  return count === 1 ? '1 step relies on this' : `${count} steps rely on this`
}

function day(iso: string | null): string {
  if (!iso) return ''
  const date = new Date(iso)
  return Number.isNaN(date.getTime()) ? iso : date.toDateString().slice(4, 10)
}

export function ContractView(ui: Ui, props: ContractProps): RenderElement {
  const { Box, Button, Text } = ui
  const { contract, reread, openTerm, focusedRow, itemTitles, onToggle, onOption, termActions } = props
  const out: RenderElement[] = []
  const line = (key: string, ...cells: RenderElement[]) =>
    out.push(
      <Box key={`line:${key}`} flexDirection="row">
        {cells}
      </Box>,
    )
  const gap = (key: string) => line(`gap:${key}`, <Text> </Text>)
  const focus = (key: string) => (focusedRow === key ? { autoFocus: true as const } : {})
  const cursor = (key: string, mark: string) => <Text color={COLOR.accent}>{focusedRow === key ? mark : ' '}</Text>

  line('head', <Text color={COLOR.accent}>{`${GLYPH.clause}  `}</Text>, <Text bold>Agreement</Text>)
  if (reread.last_at) {
    const at = new Date(reread.last_at).toTimeString().slice(0, 5)
    line('reread', <Text color={COLOR.next}>{`   ${GLYPH.history}  `}</Text>, <Text>{`PM last re-read the rules at ${at}`}</Text>)
  } else {
    line('reread', <Text color={COLOR.warning}>{`   ${GLYPH.warning}  `}</Text>, <Text>PM has not re-read the rules yet</Text>)
  }
  const changed = reread.changed_since
  if (changed.length > 0) {
    const label = changed.map(key => key.replaceAll('_', ' '))
    line(
      'changed',
      <Text color={COLOR.warning}>{`   ${GLYPH.warning}  `}</Text>,
      <Text>{`${changed.length} ${changed.length === 1 ? 'term' : 'terms'} changed since then: ${label.join(', ')}`}</Text>,
    )
  }
  if (reread.requested) line('requested', <Text color={COLOR.next}>{`   ${GLYPH.history}  `}</Text>, <Text>re-read requested</Text>)
  gap('terms')
  line('terms', <Text bold>Terms  </Text>, <Text dimColor>{'─'.repeat(40)}</Text>)

  for (const term of contract.terms) {
    const isOpen = openTerm === term.key
    const proposal = term.proposal
    line(
      termRowKey(term.key),
      cursor(termRowKey(term.key), '▌'),
      <Text dimColor>{` ${isOpen ? GLYPH.open : GLYPH.closed}  `}</Text>,
      <Button key={termRowKey(term.key)} label={term.label} plain {...focus(termRowKey(term.key))} onPress={() => onToggle(term.key)}>
        <Text bold>{term.label.padEnd(17)}</Text>
      </Button>,
      <Text>{` ${term.value_text.padEnd(28)}`}</Text>,
      <Text dimColor>{term.description}</Text>,
      ...(proposal
        ? [
            <Text color={proposal.state === 'refused' ? COLOR.refused : COLOR.warning}>{`   ${GLYPH.draft} `}</Text>,
            <Text dimColor>
              {proposal.state === 'pending' ? `proposed: ${valueText(proposal.value)}` : proposalText(proposal)}
            </Text>,
          ]
        : []),
    )
    if (!isOpen) continue

    const binding = BINDING[term.binding] ?? BINDING.none
    line(`${term.key}:binding`, <Text color={binding.color}>{`        ${binding.glyph}  `}</Text>, <Text dimColor>{binding.text}</Text>)
    line(`${term.key}:reliant`, <Text dimColor>{`        ${GLYPH.clause}  ${steps(term.reliant_steps)}`}</Text>)
    const setBy = [`Set by ${term.set_by ?? 'nobody'}`, day(term.set_at)].filter(Boolean).join(' · ')
    line(`${term.key}:set`, <Text dimColor>{`        ${GLYPH.note}  ${setBy}${term.why ? ` — ${term.why}` : ''}`}</Text>)
    for (const [index, note] of term.notes.entries()) {
      line(`${term.key}:note:${index}`, <Text dimColor>{`        ${GLYPH.note}  Your note: ${note.text ?? ''}  (no force)`}</Text>)
    }
    if (proposal) {
      line(
        `${term.key}:proposal`,
        <Text color={proposal.state === 'refused' ? COLOR.refused : COLOR.warning}>{`        ${GLYPH.draft}  `}</Text>,
        <Text>{`Proposed: ${valueText(proposal.value)} · ${proposalText(proposal)}`}</Text>,
      )
    }
    const isMulti = Array.isArray(term.value)
    const [on, off] = isMulti ? [GLYPH.checkOn, GLYPH.checkOff] : [GLYPH.radioOn, GLYPH.radioOff]
    line(`${term.key}:options`, <Text dimColor>{`        Options${isMulti ? '  (choose any)' : ''}`}</Text>)
    for (const option of term.options) {
      const key = optionRowKey(term.key, option.name)
      line(
        key,
        <Text>{' '.repeat(7)}</Text>,
        cursor(key, '›'),
        <Text color={option.active ? COLOR.done : undefined}>{` ${option.active ? on : off}  `}</Text>,
        <Button key={key} label={option.name} plain {...focus(key)} onPress={() => onOption(term.key, option.name)}>
          <Text bold={option.active}>{option.name.padEnd(24)}</Text>
        </Button>,
        <Text dimColor>{` ${option.description}`}</Text>,
        option.active ? <Text bold>   active</Text> : <Text>{''}</Text>,
      )
    }
    for (const action of termActions?.(term) ?? []) out.push(action)
    gap(`${term.key}:end`)
  }

  if (contract.instructions.length > 0) {
    gap('instructions')
    line('instructions', <Text bold>Instructions  </Text>, <Text dimColor>{'─'.repeat(33)}</Text>)
    for (const instruction of contract.instructions) {
      line(`instruction:${instruction.id}`, <Text color={COLOR.warning}>{`    ${GLYPH.clause}  `}</Text>, <Text bold>{`"${instruction.quote}"`}</Text>)
      const target =
        instruction.applies_to === 'programme' ? 'the whole programme' : (itemTitles[instruction.applies_to] ?? instruction.applies_to)
      line(
        `instruction:${instruction.id}:about`,
        <Text dimColor>{`         Applies to ${target} (${instruction.scope}) · ${steps(instruction.reliant_steps)}`}</Text>,
      )
    }
  }
  return <Box flexDirection="column">{out}</Box>
}
