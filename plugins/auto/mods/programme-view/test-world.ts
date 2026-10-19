import type { On } from 'claude-code'
import { mock } from 'claude-code/testing'
import type { Engine, Mounted } from 'claude-code/testing'

export const DATA = '/data'
export const HOME = `${DATA}/programmes/prog-1`
export const VIEW = `${HOME}/views/view.json`
export const LEASES = `${DATA}/programmes/leases`
export const LEASE = `${LEASES}/default__w2.json`

export type Pane = Mounted<'terminal', 'Pane'>
type Node = { type?: string; props?: Record<string, unknown>; children?: unknown[] }

export const step = (kind: string, title: string, clause: string | null = 'term:autonomy') => ({
  kind,
  title,
  clause,
  clause_label: clause ? clause.split(':')[1]!.replace('_', ' ') : 'no clause',
  no_clause: !clause,
  note: null,
})

export function workEntry(id: string, title: string, extra: Record<string, unknown> = {}) {
  return {
    id,
    title,
    state: 'open',
    joined_at: '2026-10-19T09:00:00Z',
    location: 'AI-Editor › owner-history',
    session_id: 'sess-w1',
    no_plan: false,
    steps: [
      step('done', 'Read view builder'),
      step('done', 'Add owner history field'),
      step('current', 'Write view test'),
      step('planned', 'Run auto suite'),
      step('planned', 'Open PR'),
    ],
    finish: 'PR open, CI green',
    recorded_at: '2026-10-19T09:50:00Z',
    age_seconds: 600,
    fade_after_seconds: 1800,
    faded: false,
    hash: 'h1',
    change_hash: null,
    changed_since_first: false,
    watch: null,
    ...extra,
  }
}

const option = (name: string, active = false) => ({ name, description: `what ${name} means`, active })

const EDITORS: Record<string, string> = {
  remit: 'space',
  stop_rule: 'until',
  autonomy: 'choice',
  cadence: 'interval',
  tools_of_record: 'checklist',
}

export function term(key: string, extra: Record<string, unknown> = {}) {
  return {
    key,
    editor: EDITORS[key] ?? 'choice',
    label: key.replaceAll('_', ' '),
    value: 'v',
    value_text: `${key} value`,
    description: `what ${key} controls`,
    binding: 'code',
    reliant_steps: 0,
    set_by: 'default',
    set_at: '2026-10-12T09:00:00Z',
    why: null,
    notes: [],
    proposal: null,
    options: [option('a', true), option('b')],
    ...extra,
  }
}

export function contractPart(terms: Record<string, unknown>[] = defaultTerms()) {
  return {
    accepted: { at: '2026-10-12T09:00:00Z' },
    terms,
    instructions: [
      { id: 'i1', quote: 'ask before closing', applies_to: 'programme', scope: 'inherited', reliant_steps: 1 },
    ],
  }
}

export function defaultTerms() {
  return [
    term('remit'),
    term('stop_rule'),
    term('autonomy', { binding: 'guidance' }),
    term('cadence', {
      value: 'fixed',
      value_text: 'fixed, seconds 900',
      binding: 'code',
      reliant_steps: 3,
      set_by: 'shawn',
      why: 'early in the project',
      notes: [{ text: 'revisit after first week', at: '2026-10-13T09:00:00Z', origin: 'ui' }],
      proposal: { value: 'on_change', extras: {}, at: '2026-10-19T09:00:00Z', origin: 'ui', state: 'pending' },
      options: [
        option('on_change'),
        option('fixed', true),
        option('o3'),
        option('o4'),
        option('o5'),
        option('o6'),
        option('o7'),
        option('o8'),
        option('o9'),
        option('o10'),
      ],
    }),
    term('tools_of_record', {
      binding: 'none',
      value: ['tracker', 'tasks'],
      options: [option('tracker', true), option('tasks', true), option('plans')],
    }),
  ]
}

export function viewText(
  parts: { work?: unknown[]; contract?: unknown; reread?: unknown; rows?: unknown[]; model?: unknown } = {},
  format = 3,
) {
  return JSON.stringify({
    view_format: format,
    run: 'prog-1',
    generated_at: '2026-10-19T10:00:00Z',
    model: parts.model ?? {},
    work: parts.work ?? [],
    contract: parts.contract ?? contractPart(),
    reread: parts.reread ?? { last_at: null, changed_since: [], requested: false, requested_at: null },
    rows: parts.rows ?? [],
  })
}

export function world(on: On, files: Record<string, string>, mtimes: Record<string, number> = {}) {
  const store = new Map<string, unknown>()
  const scrolls: { offset: number; by: number }[] = []
  mock.env(on, { CLAUDE_AUTO_DATA_DIR: DATA })
  on('session.id', () => ({ value: 'sess-pm' }))
  on('command.register', () => ({ value: { command: 'programme-view' } }))
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('ui.open', () => ({ value: { isPlaced: true } }))
  const clock = mock.clock(on, { now: Date.parse('2026-10-19T10:00:00Z') })
  on('ui.focus', () => ({}))
  on('ui.scroll', (_$, e) => {
    scrolls.push({ offset: e.offset, by: e.by })
    return {}
  })
  on('store.get', (_$, e) => ({ value: store.get(e.key) }))
  on('store.set', (_$, e) => {
    store.set(e.key, e.value)
    return { value: undefined }
  })
  on('fs.list', (_$, e) => ({
    value: Object.keys(files)
      .filter(path => path.startsWith(`${e.path}/`))
      .map(path => ({ name: path.slice(e.path.length + 1), kind: 'file' as const, size: 1, mtimeMs: 1, isLink: false })),
  }))
  on('fs.read', (_$, e) => {
    if (!(e.path in files)) throw new Error('ENOENT')
    return { value: files[e.path] ?? '' }
  })
  on('fs.stat', (_$, e) => {
    if (!(e.path in files)) throw new Error('ENOENT')
    return { value: { kind: 'file' as const, size: 1, mtimeMs: mtimes[e.path] ?? 1, isLink: false } }
  })
  return { store, scrolls, clock }
}

export const lease = (session = 'sess-pm') => JSON.stringify({ session_id: session, run: 'prog-1', home: HOME })

export async function settle() {
  for (let i = 0; i < 200; i += 1) await Promise.resolve()
}

export async function openPane($: Engine, isFocused = true, bodyRows = 40): Promise<Pane> {
  await $.session.start({ cwd: '/repo', surface: 'terminal', isInteractive: true })
  await $.command.run({ command: 'programme-view' } as never)
  const pane = await $.ui.mount({
    plugin: 'auto',
    surface: 'terminal',
    component: 'Pane',
    requestId: 'programme-view',
    props: { title: 'Programme', isFocused, bodyColumns: 100, placement: 'dock', scroll: { offset: 0, bodyRows }, view: {} },
  } as never)
  await settle()
  return pane as Pane
}

export async function contractPane($: Engine, isFocused = true, bodyRows = 40): Promise<Pane> {
  const pane = await openPane($, isFocused, bodyRows)
  await pane.press({ key: 'view:contract' })
  await settle()
  return pane
}

export function personFocus($: Engine, element: string) {
  return ($.ui as unknown as { focus: (e: unknown) => Promise<unknown> }).focus({
    component: 'Pane',
    requestId: 'programme-view',
    element,
    origin: { kind: 'person' },
  })
}

export function walk(node: unknown, visit: (one: Node) => void) {
  if (!node || typeof node !== 'object') return
  visit(node as Node)
  for (const child of (node as Node).children ?? []) walk(child, visit)
}

export function textOf(node: unknown): string {
  if (typeof node === 'string') return node
  if (!node || typeof node !== 'object') return ''
  const one = node as Node
  if (one.type === 'Button' && typeof one.props?.label === 'string' && !one.children?.length) return one.props.label
  return (one.children ?? []).map(textOf).join('')
}

// One line per row Box the views draw (each keyed `line:…`), as the person reads them.
export async function lines(pane: Pane): Promise<string[]> {
  const out: string[] = []
  walk(await pane.drawn(), one => {
    if (one.type === 'Box' && String(one.props?.key ?? '').startsWith('line:')) out.push(textOf(one))
  })
  return out
}

export async function buttonKeys(pane: Pane): Promise<string[]> {
  const keys: string[] = []
  walk(await pane.drawn(), one => {
    if (one.type === 'Button') keys.push(String(one.props?.key ?? one.props?.label))
  })
  return keys
}

export async function findNode(pane: Pane, test: (one: Node) => boolean): Promise<Node | undefined> {
  let found: Node | undefined
  walk(await pane.drawn(), one => {
    if (!found && test(one)) found = one
  })
  return found
}

export async function findAllNodes(pane: Pane, test: (one: Node) => boolean): Promise<Node[]> {
  const found: Node[] = []
  walk(await pane.drawn(), one => {
    if (test(one)) found.push(one)
  })
  return found
}

export type VerbCall = { argv: string[]; env: Record<string, string> }
export type VerbReply = { exitCode?: number; stdout?: string; stderr?: string } | { deny: string }

export function verbs(on: On, reply: (argv: string[]) => VerbReply = () => ({})) {
  const calls: VerbCall[] = []
  on('process.run', (_$, event) => {
    const argv = [...event.argv]
    calls.push({ argv, env: { ...event.init?.env } })
    const answer = reply(argv.slice(1))
    if ('deny' in answer) return answer as never
    return { value: { exitCode: answer.exitCode ?? 0, stdout: answer.stdout ?? '{}', stderr: answer.stderr ?? '' } }
  })
  return calls
}

export function prompts(on: On) {
  const sent: string[] = []
  on('prompt.submit', (_$, event) => {
    sent.push('prompt.submit')
    return { text: event.text }
  })
  on('prompt.suggest', () => {
    sent.push('prompt.suggest')
    return { isShown: false }
  })
  on('prompt.fill', () => {
    sent.push('prompt.fill')
    return { text: '', isFilled: false } as never
  })
  return sent
}
