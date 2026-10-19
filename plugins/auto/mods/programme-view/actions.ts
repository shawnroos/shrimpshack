import type { EngineInterface } from 'claude-code'

import type { Term } from './contract'

export type Outcome = { ok: boolean; message: string }

export type Draft = {
  option?: string
  minutes?: number
  space?: string
  tools?: string[]
  add?: { name?: string; description?: string }
}

const MESSAGE_CAP = 400

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

const UI = ['--origin', 'ui']

export function toolsOf(term: Term, draft?: Draft): string[] {
  return draft?.tools ?? (Array.isArray(term.value) ? term.value.map(String) : [])
}

export function proposeArgv(term: Term, draft: Draft | undefined): string[] | string {
  const key = term.key
  if (key === 'tools_of_record') {
    const name = draft?.add?.name
    if (name && !draft?.add?.description) return `give ${name} a description first`
    const tools = toolsOf(term, draft)
    const list = name && !tools.includes(name) ? [...tools, name] : tools
    if (!draft?.tools && !name) return 'tick or add a tool first'
    const add = name ? ['--add', name, '--description', draft?.add?.description ?? ''] : []
    return ['propose-term', key, list.join(',') || 'none', ...add, ...UI]
  }
  if (key === 'remit' && draft?.space) return ['propose-term', key, '--add', draft.space, ...UI]
  if (key === 'cadence' && draft?.minutes) return ['propose-term', key, 'fixed', '--seconds', String(draft.minutes * 60), ...UI]
  if (draft?.option) return ['propose-term', key, draft.option, ...UI]
  return 'pick an option first'
}

export function minutesOf(text: string): number | undefined {
  const trimmed = text.trim()
  if (!/^\d+$/.test(trimmed)) return undefined
  const minutes = Number(trimmed)
  return minutes > 0 ? minutes : undefined
}

const words = (name: string) => name.replaceAll('_', ' ')

function interval(seconds: number): string {
  return seconds % 60 === 0 ? `every ${seconds / 60} min` : `every ${seconds} seconds`
}

// Every reply must name the term and the value: the approval check refuses a typed reply that does not
// (require_named / require_sources_named in lib/programme.py), and for tools it needs the dropped ones too.
function reply(term: Term, value: unknown, extras: Record<string, unknown>): string {
  const label = words(term.key)
  if (term.key === 'tools_of_record') {
    const before = Array.isArray(term.value) ? term.value.map(String) : []
    const after = Array.isArray(value) ? value.map(String) : []
    const dropped = before.filter(tool => !after.includes(tool))
    const verb = after.some(tool => !before.includes(tool)) ? 'widen' : 'amend'
    const drop = dropped.length > 0 ? ` and drop ${dropped.join(', ')}` : ''
    return `${verb} ${label} to ${after.join(', ') || 'none'}${drop}`
  }
  if (term.key === 'remit' && typeof extras.add === 'string') return `widen ${label} to add herdr space ${extras.add}`
  const parts = [`amend ${label} to ${words(String(value))}`]
  if (typeof extras.seconds === 'number') parts.push(interval(extras.seconds))
  if (typeof extras.until === 'string') parts.push(`until ${extras.until}`)
  return parts.join(' ')
}

export function acceptReply(term: Term): string | undefined {
  const proposal = term.proposal
  if (!proposal || (proposal.state !== 'pending' && proposal.state !== 'refused')) return
  return reply(term, proposal.value, proposal.extras ?? {})
}

// A new tool must be proposed before an amend may name it, so a draft that adds one has no reply yet.
export function draftReply(term: Term, draft: Draft | undefined): string | undefined {
  if (!draft) return
  if (term.key === 'tools_of_record') {
    if (draft.add?.name || !draft.tools) return
    const before = toolsOf(term)
    const same = draft.tools.length === before.length && draft.tools.every(tool => before.includes(tool))
    return same ? undefined : reply(term, draft.tools, {})
  }
  if (term.key === 'remit' && draft.space) return reply(term, term.value, { add: draft.space })
  if (term.key === 'cadence' && draft.minutes) return reply(term, 'fixed', { seconds: draft.minutes * 60 })
  const active = term.options.find(option => option.active)?.name
  if (draft.option && draft.option !== active) return reply(term, draft.option, {})
}

export function instructionTemplate(title: string | undefined): string {
  return `Instruction for ${title ?? 'the whole programme'}: `
}

export function withdrawReply(quote: string): string {
  return `Withdraw instruction "${quote}"`
}
