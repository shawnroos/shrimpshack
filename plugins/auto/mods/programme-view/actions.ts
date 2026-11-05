import type { EngineInterface } from 'claude-code'

import type { Term } from './contract'

export type Outcome = { ok: boolean; message: string }

export type Draft = {
  option?: string
  custom?: string
  tools?: string[]
  add?: { name?: string; description?: string }
}

export type EditorKind = 'choice' | 'checklist' | 'interval' | 'space' | 'until'

export type Refusal = { refused: string }

// A term's own typed value beside its options.
export type Custom = {
  field: string
  label: string
  placeholder: (spaces: string[]) => string
  parse: (text: string) => string | Refusal
  argv: (value: string) => string[]
  text: (value: string) => string
}

const MESSAGE_CAP = 400
const UTC_TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/

// Date.parse rolls 2026-02-30 over to March; the round trip refuses it, as Python's strptime does.
function isUtcTime(text: string): boolean {
  if (!UTC_TIME.test(text) || text.startsWith('0000')) return false
  const at = Date.parse(text)
  return !Number.isNaN(at) && new Date(at).toISOString().replace('.000Z', 'Z') === text
}

export const CUSTOM: Partial<Record<EditorKind, Custom>> = {
  interval: {
    field: 'minutes',
    label: 'Custom interval, in minutes: ',
    placeholder: () => '15',
    parse: text =>
      /^\d+$/.test(text.trim()) && Number(text) > 0 ? String(Number(text)) : { refused: `"${text}" is not a whole number of minutes` },
    argv: minutes => ['fixed', '--seconds', String(Number(minutes) * 60)],
    text: minutes => `fixed, every ${minutes} min`,
  },
  space: {
    field: 'space',
    label: 'Add a space (server.workspace, or host--server--workspace on Rex or Ghostty): ',
    placeholder: spaces => spaces[0] ?? 'default.w2',
    parse: text => text.trim(),
    argv: space => ['--add', space],
    text: space => `add space ${space}`,
  },
  until: {
    field: 'until',
    label: 'Stop at (UTC, like 2026-10-20T18:00:00Z): ',
    placeholder: () => '2026-10-20T18:00:00Z',
    parse: text => (isUtcTime(text.trim()) ? text.trim() : { refused: `"${text}" is not a UTC time like 2026-10-20T18:00:00Z` }),
    argv: until => ['until_time', '--until', until],
    text: until => `until_time, until ${until}`,
  },
}

export function isChecklist(term: Term): boolean {
  return term.editor === 'checklist'
}

export function customOf(term: Term): Custom | undefined {
  return CUSTOM[term.editor]
}

export async function runVerb($: EngineInterface, argv: string[]): Promise<Outcome> {
  const session = await $.session.id()
  let result: unknown
  try {
    result = await $.process.run([`${$.plugin.root}/lib/programme.sh`, ...argv], { env: { CLAUDE_CODE_SESSION_ID: session } })
  } catch (error) {
    return { ok: false, message: `not run: ${error instanceof Error ? error.message : String(error)}` }
  }
  const refused = (result as { deny?: unknown } | undefined)?.deny
  if (refused !== undefined) return { ok: false, message: `refused: ${String(refused)}` }
  const { exitCode, stdout = '', stderr = '' } = (result ?? {}) as { exitCode?: number; stdout?: string; stderr?: string }
  if (exitCode !== 0) {
    // stdout carries the rules text the compact guard prints; the reason is on stderr.
    const message = stderr.trim() || stdout.trim() || `${argv[0]} exited ${String(exitCode)}`
    return { ok: false, message: message.slice(0, MESSAGE_CAP) }
  }
  return { ok: true, message: stdout.trim() }
}

export const UI_ORIGIN_ARGS = ['--origin', 'ui']

export function toolsOf(term: Term, draft?: Draft): string[] {
  return draft?.tools ?? (Array.isArray(term.value) ? term.value.map(String) : [])
}

function checklistArgs(term: Term, draft: Draft | undefined): string[] | string {
  const name = draft?.add?.name
  if (name && !draft?.add?.description) return `give ${name} a description first`
  const tools = toolsOf(term, draft)
  const list = name && !tools.includes(name) ? [...tools, name] : tools
  if (!draft?.tools && !name) return 'tick or add a tool first'
  const add = name ? ['--add', name, '--description', draft?.add?.description ?? ''] : []
  return [list.join(',') || 'none', ...add]
}

function proposeArgs(term: Term, draft: Draft | undefined): string[] | string {
  if (isChecklist(term)) return checklistArgs(term, draft)
  const custom = customOf(term)
  if (custom && draft?.custom) return custom.argv(draft.custom)
  if (draft?.option) return [draft.option]
  return 'pick an option first'
}

export function proposeArgv(term: Term, draft: Draft | undefined): string[] | string {
  const args = proposeArgs(term, draft)
  return typeof args === 'string' ? args : ['propose-term', term.key, ...args, ...UI_ORIGIN_ARGS]
}

export const PM_WILL_ASK = 'The PM will ask you in the chat.'

export function proposalWaiting(term: Term): boolean {
  const state = term.proposal?.state
  return state === 'pending' || state === 'refused'
}

export function draftChanges(term: Term, draft: Draft | undefined): boolean {
  if (!draft) return false
  if (isChecklist(term)) {
    if (draft.add?.name) return true
    if (!draft.tools) return false
    const before = toolsOf(term)
    return draft.tools.length !== before.length || !draft.tools.every(tool => before.includes(tool))
  }
  if (customOf(term) && draft.custom) return true
  return Boolean(draft.option) && draft.option !== term.options.find(option => option.active)?.name
}

export function draftText(term: Term, draft: Draft): string | undefined {
  if (isChecklist(term)) {
    const name = draft.add?.name
    if (!draft.tools && !name) return
    const tools = toolsOf(term, draft)
    const parts = [(name && !tools.includes(name) ? [...tools, name] : tools).join(', ') || 'none']
    if (name) parts.push(`new tool ${name}${draft.add?.description ? ` (${draft.add.description})` : ', needs a description'}`)
    return parts.join(' · ')
  }
  const custom = customOf(term)
  if (custom && draft.custom) return custom.text(draft.custom)
  return draft.option
}

export function rulingHint(title: string | undefined): string {
  return `To add a Ruling for ${title ?? 'the whole programme'}, tell the PM in the chat.`
}

export const WITHDRAW_HINT = 'To withdraw this Ruling, tell the PM in the chat.'
