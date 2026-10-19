import type { RenderElement } from 'claude-code'

import { acceptReply, customOf, draftReply, draftText, instructionTemplate, isChecklist, toolsOf, withdrawReply } from './actions'
import type { Draft, EditorKind, Outcome } from './actions'
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
  editor: EditorKind
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

export type ContractActions = {
  propose: (term: Term) => void
  clear: (term: Term) => void
  note: (term: Term) => void
  saveNote: (term: Term, text: string) => void
  reread: () => void
  fulfil: (id: string) => void
  closeAsFulfilled: (id: string, why: string) => void
  custom: (term: Term, text: string) => void
  addTool: (term: Term) => void
  toolName: (term: Term, text: string) => void
  toolDescription: (term: Term, text: string) => void
  focusRow: (key: string) => void
}

export type ContractProps = {
  contract: Contract
  reread: Reread
  openTerm: string | undefined
  focusedRow: string | undefined
  itemTitles: Record<string, string>
  selectedItem: string | undefined
  armed: boolean
  drafts: Record<string, Draft>
  editing: string | undefined
  status: Outcome | undefined
  spaces: string[]
  onToggle: (key: string) => void
  onOption: (term: string, option: string) => void
  act: ContractActions
}

export const termRowKey = (key: string) => `term:${key}`
export const optionRowKey = (term: string, option: string) => `option:${term}:${option}`
export const instructionRowKey = (id: string) => `instruction:${id}`
export const noteKey = (term: string) => `note:${term}`
export const whyKey = (id: string) => `why:${id}`
export const toolEditKey = (term: string) => `tool:${term}`

const BINDING = {
  code: { glyph: GLYPH.code, color: COLOR.done, text: 'Checked in code' },
  guidance: { glyph: GLYPH.guide, color: COLOR.warning, text: 'Written guidance only, no code checks it' },
  none: { glyph: GLYPH.unread, color: COLOR.refused, text: 'Nothing reads it' },
} as const

function valueText(value: unknown): string {
  if (Array.isArray(value)) return value.map(String).join(', ') || 'none'
  return String(value ?? '')
}

function proposalValue(proposal: Proposal): string {
  const { seconds, until } = proposal.extras ?? {}
  const parts = [valueText(proposal.value)]
  if (typeof seconds === 'number') parts.push(`every ${seconds % 60 === 0 ? `${seconds / 60} min` : `${seconds}s`}`)
  if (typeof until === 'string') parts.push(`until ${until}`)
  return parts.join(' ')
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
  const { Box, Button, Input, Text } = ui
  const { contract, reread, openTerm, focusedRow, itemTitles, selectedItem, armed, drafts, editing, status, spaces } = props
  const { onToggle, onOption, act } = props
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
  const pad = (width: number) => <Text>{' '.repeat(width)}</Text>
  const typeThis = (key: string, reply: string, width: number, label = 'Type this:') => {
    line(`${key}:label`, <Text dimColor>{`${' '.repeat(width)}${label}`}</Text>)
    line(`${key}:reply`, <Text bold>{`${' '.repeat(width)}${reply}`}</Text>)
  }
  const action = (key: string, hotkey: string, label: string, onPress: () => void) => (
    <Button key={key} label={label} plain hotkey={hotkey} onPress={onPress} />
  )

  function customOptions(term: Term, draft: Draft | undefined) {
    const custom = customOf(term)
    if (custom) {
      line(
        `${term.key}:custom`,
        pad(8),
        <Input
          key={`custom:${term.key}:${custom.field}`}
          label={custom.label}
          placeholder={custom.placeholder(spaces)}
          value={draft?.custom ?? ''}
          onSubmit={text => act.custom(term, text)}
        />,
      )
    }
    if (!isChecklist(term)) return
    line(`${term.key}:add`, pad(8), <Button key="custom:tools:add" label="Add a tool…" plain onPress={() => act.addTool(term)} />)
    if (editing !== toolEditKey(term.key)) return
    line(
      `${term.key}:tool-name`,
      pad(8),
      <Input key="custom:tools:name" label="Tool name: " autoFocus value={draft?.add?.name ?? ''} onSubmit={text => act.toolName(term, text)} />,
    )
    line(
      `${term.key}:tool-description`,
      pad(8),
      <Input
        key="custom:tools:description"
        label="What it is: "
        value={draft?.add?.description ?? ''}
        onSubmit={text => act.toolDescription(term, text)}
      />,
    )
  }

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
  if (armed) line('reread:act', pad(3), action('act:reread', 'e', 'ask the PM to re-read the rules', act.reread))
  if (status) {
    line(
      'status',
      <Text color={status.ok ? COLOR.done : COLOR.refused}>{`   ${status.ok ? '✓' : '✗'}  `}</Text>,
      <Text color={status.ok ? undefined : COLOR.refused}>{status.message}</Text>,
    )
  }
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
              {proposal.state === 'pending' ? `proposed: ${proposalValue(proposal)}` : proposalText(proposal)}
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
        <Text>{`Proposed: ${proposalValue(proposal)} · ${proposalText(proposal)}`}</Text>,
      )
    }
    const draft = drafts[term.key]
    const isMulti = isChecklist(term)
    const ticked = isMulti ? toolsOf(term, draft) : []
    const [on, off] = isMulti ? [GLYPH.checkOn, GLYPH.checkOff] : [GLYPH.radioOn, GLYPH.radioOff]
    line(`${term.key}:options`, <Text dimColor>{`        Options${isMulti ? '  (choose any)' : ''}`}</Text>)
    for (const option of term.options) {
      const key = optionRowKey(term.key, option.name)
      const isOn = isMulti ? ticked.includes(option.name) : option.active
      line(
        key,
        pad(7),
        cursor(key, '›'),
        <Text color={isOn ? COLOR.done : undefined}>{` ${isOn ? on : off}  `}</Text>,
        <Button key={key} label={option.name} plain {...focus(key)} onPress={() => onOption(term.key, option.name)}>
          <Text bold={option.active}>{option.name.padEnd(24)}</Text>
        </Button>,
        <Text dimColor>{` ${option.description}`}</Text>,
        option.active ? <Text bold>   active</Text> : <Text>{''}</Text>,
      )
    }
    customOptions(term, draft)
    const change = draft ? draftText(term, draft) : undefined
    if (change) line(`${term.key}:draft`, <Text dimColor>{`        ${GLYPH.draft}  Your change: ${change}`}</Text>)
    const accept = acceptReply(term)
    if (accept) typeThis(`${term.key}:accept`, accept, 8)
    const amend = draftReply(term, draft)
    if (amend && amend !== accept) typeThis(`${term.key}:amend`, amend, 8)
    if (armed) {
      line(
        `${term.key}:actions`,
        pad(8),
        <Box flexDirection="row" gap={3}>
          {[
            action('act:propose', 'p', 'propose', () => act.propose(term)),
            ...(proposal ? [action('act:clear', 'x', 'clear proposal', () => act.clear(term))] : []),
            action('act:note', 'n', 'note', () => act.note(term)),
          ]}
        </Box>,
      )
    }
    if (editing === noteKey(term.key)) {
      line(
        `${term.key}:note-input`,
        pad(8),
        <Input
          key={noteKey(term.key)}
          label="Note (Enter on an empty note clears them all): "
          autoFocus
          onSubmit={text => act.saveNote(term, text)}
        />,
      )
    }
    gap(`${term.key}:end`)
  }

  gap('instructions')
  line('instructions', <Text bold>Instructions  </Text>, <Text dimColor>{'─'.repeat(33)}</Text>)
  for (const instruction of contract.instructions) {
    const key = instructionRowKey(instruction.id)
    line(
      key,
      cursor(key, '▌'),
      <Text color={COLOR.warning}>{`   ${GLYPH.clause}  `}</Text>,
      <Button key={key} label={instruction.quote} plain {...focus(key)} onPress={() => act.focusRow(key)}>
        <Text bold>{`"${instruction.quote}"`}</Text>
      </Button>,
    )
    const target =
      instruction.applies_to === 'programme' ? 'the whole programme' : (itemTitles[instruction.applies_to] ?? instruction.applies_to)
    line(
      `${key}:about`,
      <Text dimColor>{`         Applies to ${target} (${instruction.scope}) · ${steps(instruction.reliant_steps)}`}</Text>,
    )
    if (focusedRow !== key) continue
    typeThis(`${key}:withdraw`, withdrawReply(instruction.quote), 9)
    if (armed) line(`${key}:actions`, pad(9), action('act:fulfil', 'f', 'close as fulfilled', () => act.fulfil(instruction.id)))
    if (editing === whyKey(instruction.id)) {
      line(
        `${key}:why`,
        pad(9),
        <Input
          key={whyKey(instruction.id)}
          label="Why is it fulfilled: "
          autoFocus
          onSubmit={text => act.closeAsFulfilled(instruction.id, text)}
        />,
      )
    }
  }
  const title = selectedItem ? itemTitles[selectedItem] : undefined
  typeThis('instruction:new', instructionTemplate(title), 4, 'To add an instruction, type this:')
  return <Box flexDirection="column">{out}</Box>
}
