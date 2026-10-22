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

type Proposed = { value: unknown; extras: Record<string, unknown> }

export type Refusal = { refused: string }

// A term's own typed value beside its options.
export type Custom = {
  field: string
  label: string
  placeholder: (spaces: string[]) => string
  parse: (text: string) => string | Refusal
  argv: (value: string) => string[]
  proposed: (term: Term, value: string) => Proposed
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
    proposed: (_term, minutes) => ({ value: 'fixed', extras: { seconds: Number(minutes) * 60 } }),
    text: minutes => `fixed, every ${minutes} min`,
  },
  space: {
    field: 'space',
    label: 'Add a herdr space (server.workspace): ',
    placeholder: spaces => spaces[0] ?? 'default.w2',
    parse: text => text.trim(),
    argv: space => ['--add', space],
    proposed: (term, space) => ({ value: term.value, extras: { add: space } }),
    text: space => `add herdr space ${space}`,
  },
  until: {
    field: 'until',
    label: 'Stop at (UTC, like 2026-10-20T18:00:00Z): ',
    placeholder: () => '2026-10-20T18:00:00Z',
    parse: text => (isUtcTime(text.trim()) ? text.trim() : { refused: `"${text}" is not a UTC time like 2026-10-20T18:00:00Z` }),
    argv: until => ['until_time', '--until', until],
    proposed: (_term, until) => ({ value: 'until_time', extras: { until } }),
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

const words = (name: string) => name.replaceAll('_', ' ')

function interval(seconds: number): string {
  return seconds % 60 === 0 ? `every ${seconds / 60} min` : `every ${seconds} seconds`
}

// Every reply must name the term and the value: the approval check refuses a typed reply that does not
// (require_named / require_sources_named in lib/programme.py), and for tools it needs the dropped ones too.
function reply(term: Term, { value, extras }: Proposed): string {
  const label = words(term.key)
  if (isChecklist(term)) {
    const before = toolsOf(term)
    const after = Array.isArray(value) ? value.map(String) : []
    const dropped = before.filter(tool => !after.includes(tool))
    const verb = after.some(tool => !before.includes(tool)) ? 'widen' : 'amend'
    const drop = dropped.length > 0 ? ` and drop ${dropped.join(', ')}` : ''
    return `${verb} ${label} to ${after.join(', ') || 'none'}${drop}`
  }
  if (typeof extras.add === 'string') return `widen ${label} to add herdr space ${extras.add}`
  const parts = [`amend ${label} to ${words(String(value))}`]
  if (typeof extras.seconds === 'number') parts.push(interval(extras.seconds))
  if (typeof extras.until === 'string') parts.push(`until ${extras.until}`)
  return parts.join(' ')
}

export function acceptReply(term: Term): string | undefined {
  const proposal = term.proposal
  if (!proposal || (proposal.state !== 'pending' && proposal.state !== 'refused')) return
  return reply(term, { value: proposal.value, extras: proposal.extras ?? {} })
}

// A new tool must be proposed before an amend may name it, so a draft that adds one has no reply yet.
export function draftReply(term: Term, draft: Draft | undefined): string | undefined {
  if (!draft) return
  if (isChecklist(term)) {
    if (draft.add?.name || !draft.tools) return
    const before = toolsOf(term)
    const same = draft.tools.length === before.length && draft.tools.every(tool => before.includes(tool))
    return same ? undefined : reply(term, { value: draft.tools, extras: {} })
  }
  const custom = customOf(term)
  if (custom && draft.custom) return reply(term, custom.proposed(term, draft.custom))
  const active = term.options.find(option => option.active)?.name
  if (draft.option && draft.option !== active) return reply(term, { value: draft.option, extras: {} })
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

export function rulingTemplate(title: string | undefined): string {
  return `Ruling for ${title ?? 'the whole programme'}: `
}

// close-ruling --as withdrawn needs a typed prompt that names the Ruling's id.
export function withdrawReply(id: string, quote: string): string {
  return `Withdraw ruling ${id} "${quote}"`
}
