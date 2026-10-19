import type { EngineInterface } from 'claude-code'

import { UI_ORIGIN_ARGS, customOf, draftText, isChecklist, proposeArgv, runVerb, toolsOf } from './actions'
import type { Draft, Outcome } from './actions'
import { noteKey, optionRowKey, termRowKey, toolEditKey, whyKey } from './contract'
import type { Contract, ContractActions, ContractProps, Term } from './contract'

type State = {
  openTerm?: string
  focusedRow?: string
  drafts: Record<string, Draft>
  editing?: string
  status?: Outcome
}

let state: State = { drafts: {} }

export function resetContract(): void {
  state = { drafts: {} }
}

export function isContractRow(key: string): boolean {
  return key.startsWith('term:') || key.startsWith('option:') || key.startsWith('instruction:')
}

export function focusContractRow(key: string): void {
  state.focusedRow = key
}

function setDraft(key: string, draft: Draft | undefined): void {
  const { [key]: _old, ...rest } = state.drafts
  state.drafts = draft ? { ...rest, [key]: draft } : rest
}

function focusedOption(term: Term): string | undefined {
  const prefix = optionRowKey(term.key, '')
  return state.focusedRow?.startsWith(prefix) ? state.focusedRow.slice(prefix.length) : undefined
}

function pickOption(term: Term, option: string): void {
  const draft = state.drafts[term.key] ?? {}
  if (!isChecklist(term)) return setDraft(term.key, { ...draft, option, custom: undefined })
  const tools = toolsOf(term, draft)
  setDraft(term.key, { ...draft, tools: tools.includes(option) ? tools.filter(tool => tool !== option) : [...tools, option] })
}

function actions($: EngineInterface): ContractActions {
  const redraw = () => $.ui.invalidate('ui.render')
  const refuse = async (message: string) => {
    state.status = { ok: false, message }
    await redraw()
  }
  const edit = async (key: string | undefined) => {
    state.editing = key
    await redraw()
  }
  const perform = async (argv: string[], done: string, after?: () => void) => {
    const outcome = await runVerb($, argv)
    state.status = outcome.ok ? { ok: true, message: done } : outcome
    if (outcome.ok) after?.()
    await redraw()
  }
  const change = async (term: Term, next: Draft) => {
    setDraft(term.key, { ...state.drafts[term.key], ...next })
    await redraw()
  }
  return {
    propose: async term => {
      const stored = state.drafts[term.key] ?? {}
      const picked = isChecklist(term) || stored.option ? undefined : focusedOption(term)
      const draft = picked ? { ...stored, option: picked } : stored
      const argv = proposeArgv(term, draft)
      if (typeof argv === 'string') return refuse(argv)
      await perform(argv, `proposed ${term.label}: ${draftText(term, draft) ?? ''}`, () => {
        setDraft(term.key, undefined)
        if (state.editing === toolEditKey(term.key)) state.editing = undefined
      })
    },
    clear: term => perform(['clear-proposal', term.key, ...UI_ORIGIN_ARGS], 'proposal cleared'),
    note: term => edit(noteKey(term.key)),
    saveNote: (term, text) => {
      const argv = text.trim() ? ['note-term', term.key, text.trim()] : ['note-term', term.key, '--clear']
      return perform([...argv, ...UI_ORIGIN_ARGS], text.trim() ? 'note saved' : 'notes cleared', () => {
        state.editing = undefined
      })
    },
    reread: () => perform(['request-reread', ...UI_ORIGIN_ARGS], 're-read requested'),
    fulfil: id => edit(whyKey(id)),
    closeAsFulfilled: (id, why) => {
      if (!why.trim()) return refuse('say why the instruction is fulfilled')
      return perform(['close-instruction', id, '--as', 'fulfilled', '--why', why.trim(), ...UI_ORIGIN_ARGS], 'instruction closed as fulfilled', () => {
        state.editing = undefined
      })
    },
    custom: async (term, text) => {
      const custom = customOf(term)
      if (!custom) return
      const value = custom.parse(text)
      if (typeof value !== 'string') return refuse(value.refused)
      state.status = undefined
      await change(term, { custom: value, option: undefined })
    },
    addTool: term => edit(toolEditKey(term.key)),
    toolName: (term, name) => change(term, { add: { ...state.drafts[term.key]?.add, name: name.trim() } }),
    toolDescription: (term, description) => change(term, { add: { ...state.drafts[term.key]?.add, description: description.trim() } }),
    focusRow: async key => {
      state.focusedRow = key
      await redraw()
    },
  }
}

type Controlled = Pick<ContractProps, 'openTerm' | 'focusedRow' | 'drafts' | 'editing' | 'status' | 'onToggle' | 'onOption' | 'act'>

export function contractControls($: EngineInterface, contract: Contract): Controlled {
  return {
    openTerm: state.openTerm,
    focusedRow: state.focusedRow,
    drafts: state.drafts,
    editing: state.editing,
    status: state.status,
    onToggle: async key => {
      state.openTerm = state.openTerm === key ? undefined : key
      state.focusedRow = termRowKey(key)
      await $.ui.invalidate('ui.render')
    },
    onOption: async (key, option) => {
      state.focusedRow = optionRowKey(key, option)
      const term = contract.terms.find(one => one.key === key)
      if (term) pickOption(term, option)
      await $.ui.invalidate('ui.render')
    },
    act: actions($),
  }
}
