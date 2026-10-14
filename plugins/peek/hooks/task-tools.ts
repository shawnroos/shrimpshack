import type { PropValue } from '../types'
import { plural } from './format'
import { readFrontmatter } from './frontmatter'
import { groupHome } from './groups-session'
import { mirrorRoot, readListState, withProp, writeAtomic } from './mirror/records'
import { createMirror } from './mirror/watch'
import type { Mirror } from './mirror/watch'
import type { NavIo } from './navigation'
import { definitionsOf, ownPlace, placeOfDoc, taskItems, tasksIoOf } from './pane/task-data'
import { resolvePath } from './paths'
import { taskSession } from './tasks/poll'
import { setStatus } from './tasks/status'
import { TASK_CAPS, capturePlace, createTask, ensureExcluded, userPlace } from './tasks/store'
import type { TaskPlace } from './tasks/store'
import { problemLine, readDefinition } from './views/definition'
import type { Item } from './views/items'

export type TaskToolName = 'list_tasks' | 'read_task' | 'save_task' | 'move_tasks' | 'check_view'
type TaskTool = { spec: { name: TaskToolName; description: string; inputSchema: Record<string, unknown> }; run: (io: NavIo, input: unknown) => Promise<{ result: string }> }
type Result = { result: string }

// The creator the pane writes for Shawn's own actions (pane/actions.ts), so his tasks read the same from either side.
const PERSON = 'shawn'
const STATUSES = ['todo', 'doing', 'done', 'cancelled']
const SEQUENCE_KEYS = ['after', 'before', 'with']
const DATE = /^\d{4}-\d{2}-\d{2}$/
const LIST = /^([^#\s/]+)#(\d+)$/
const CAPS = { listed: 200, attachments: 20, refs: 20, description: 20_000 }

const MESSAGES = {
  name: 'Give a name to create a task, or an id to change one.',
  onBehalf: 'on_behalf is person (a task Shawn asked for) or self (your own work).',
  status: `status is one of ${STATUSES.join(', ')}.`,
  due: 'due is a date like 2026-11-02.',
  sequence: 'sequence is { after, before, with }, each a task id or a list of them.',
  attachments: 'attachments is a list of file paths or URLs.',
  description: 'description is text.',
  to: 'to is mine, user, or a folder inside a git repo.',
  what: 'Give tasks (ids) or a list (session#n) to move.',
  view: 'Give a path to a definition file, or its text.',
}

const isText = (value: unknown): value is string => typeof value === 'string'
const isTextList = (value: unknown, cap: number): value is string[] => Array.isArray(value) && value.length <= cap && value.every(isText)
const noTask = (ref: string): Result => ({ result: `No task ${ref}; use an id from list_tasks.` })
const said = (result: string): Result => ({ result })
const textOf = (item: Item, key: string) => (typeof item.props[key] === 'string' ? (item.props[key] as string) : undefined)

async function sessionOf(io: NavIo) {
  return { id: await io.sessionId(), worktreeRoot: (await groupHome(io).catch(() => null))?.worktreeRoot }
}

// The session's own mirror when the task poll runs, so its in-memory records see the change; a fresh one otherwise.
async function mirrorOf(io: NavIo): Promise<Mirror> {
  const live = taskSession()?.mirror
  if (live) return live
  const session = await sessionOf(io)
  return createMirror(tasksIoOf(io), { id: session.id, root: session.worktreeRoot ?? (await io.sessionRoot()) })
}

async function findTask(io: NavIo, items: readonly Item[], ref: string): Promise<Item | null> {
  const path = resolvePath(ref, await io.cwd(), (await io.home()) ?? '')
  return items.find(one => one.id === ref) ?? items.find(one => one.href === ref || one.href === path) ?? null
}

function summary(item: Item) {
  const keep = ['status', 'creator', 'list', 'parent', 'sequence', 'due', 'session_ended', 'takeover']
  return {
    id: item.id,
    name: item.name,
    path: item.href,
    source: item.source,
    ...Object.fromEntries(keep.flatMap(key => (item.props[key] === undefined ? [] : [[key, item.props[key]]]))),
  }
}

async function listTasks(io: NavIo, raw: unknown): Promise<Result> {
  const input = (raw ?? {}) as { status?: unknown; creator?: unknown; list?: unknown }
  for (const key of ['status', 'creator', 'list'] as const) if (input[key] !== undefined && !isText(input[key])) return said(`${key} must be text.`)
  const self = await io.sessionId()
  const creator = input.creator === 'person' ? PERSON : input.creator === 'self' ? self : input.creator
  const items = (await taskItems(io)).filter(
    one =>
      (input.status === undefined || textOf(one, 'status') === input.status) &&
      (creator === undefined || textOf(one, 'creator') === creator) &&
      (input.list === undefined || textOf(one, 'list') === input.list),
  )
  const shown = items.slice(0, CAPS.listed).map(summary)
  const line = items.length ? `${plural(items.length, 'task')}${items.length > shown.length ? `, the first ${shown.length} shown` : ''}.` : 'No tasks match.'
  return said(`${line}\n${JSON.stringify({ tasks: shown })}`)
}

async function readTask(io: NavIo, raw: unknown): Promise<Result> {
  const id = (raw as { id?: unknown } | null)?.id
  if (!isText(id)) return said('Give the id of a task from list_tasks.')
  const item = await findTask(io, await taskItems(io, { isEverywhere: true }), id)
  if (!item) return noTask(id)
  const text = await io.readFile(item.href).catch(() => '')
  const body = readFrontmatter(text).body.trim()
  const line = `Task "${item.name}" (${item.id}): ${textOf(item, 'status') ?? 'no status'}.`
  return said(`${line}\n${JSON.stringify({ ...summary(item), props: item.props, body, ...(item.missing ? { missing: item.missing } : {}) })}`)
}

type SaveInput = {
  id?: unknown
  name?: unknown
  status?: unknown
  on_behalf?: unknown
  description?: unknown
  sequence?: unknown
  parent?: unknown
  due?: unknown
  attachments?: unknown
}

type Edits = Record<string, PropValue>

// Every ref names a task that exists, stored as that task's id, so a later rename or move of its file keeps the link.
async function readEdits(io: NavIo, input: SaveInput, items: readonly Item[]): Promise<{ edits: Edits } | Result> {
  const edits: Edits = {}
  if (input.name !== undefined) {
    if (!isText(input.name) || !input.name.trim()) return said(MESSAGES.name)
    if (input.name.trim().length > TASK_CAPS.name) return said(`A task name holds at most ${TASK_CAPS.name} characters.`)
    edits.name = input.name.trim()
  }
  if (input.status !== undefined && !(isText(input.status) && STATUSES.includes(input.status))) return said(MESSAGES.status)
  if (input.due !== undefined) {
    if (!isText(input.due) || !DATE.test(input.due)) return said(MESSAGES.due)
    edits.due = input.due
  }
  if (input.description !== undefined && !(isText(input.description) && input.description.length <= CAPS.description)) return said(MESSAGES.description)
  if (input.attachments !== undefined) {
    if (!isTextList(input.attachments, CAPS.attachments)) return said(MESSAGES.attachments)
    edits.attachments = input.attachments
  }
  const idOf = async (ref: string) => (await findTask(io, items, ref))?.id ?? null
  if (input.parent !== undefined) {
    if (!isText(input.parent)) return noTask(String(input.parent))
    const parent = await idOf(input.parent)
    if (!parent) return noTask(input.parent)
    edits.parent = parent
  }
  if (input.sequence !== undefined) {
    const sequence = input.sequence
    if (!sequence || typeof sequence !== 'object' || Array.isArray(sequence)) return said(MESSAGES.sequence)
    const entries = Object.entries(sequence)
    if (!entries.length || entries.some(([key, value]) => !SEQUENCE_KEYS.includes(key) || !(isText(value) || isTextList(value, CAPS.refs)))) return said(MESSAGES.sequence)
    const resolved: Record<string, string | string[]> = {}
    for (const [key, value] of entries as [string, string | string[]][]) {
      const refs: string[] = []
      for (const ref of isText(value) ? [value] : value) {
        const id = await idOf(ref)
        if (!id) return noTask(ref)
        refs.push(id)
      }
      resolved[key] = isText(value) ? (refs[0] ?? value) : refs
    }
    edits.sequence = resolved
  }
  return { edits }
}

function withBody(text: string, body: string): string {
  const lines = text.split('\n')
  const close = lines[0]?.trimEnd() === '---' ? lines.findIndex((one, i) => i > 0 && (one.trimEnd() === '---' || one.trimEnd() === '...')) : -1
  return close < 0 ? body : [...lines.slice(0, close + 1), body].join('\n')
}

async function rewrite(io: NavIo, path: string, edits: Edits, body: string | undefined) {
  const text = await io.readFile(path)
  const next = Object.entries(edits).reduce((doc, [key, value]) => withProp(doc, key, value), body === undefined ? text : withBody(text, body))
  if (next !== text) await writeAtomic(tasksIoOf(io), path, next)
}

const savedLine = (name: string, id: string, status: string) => `Saved task "${name}" (${id}): ${status}.`

async function saveTask(io: NavIo, raw: unknown): Promise<Result> {
  const input = (raw ?? {}) as SaveInput
  const isUpdate = input.id !== undefined
  if (isUpdate && !isText(input.id)) return noTask(String(input.id))
  if (!isUpdate && !isText(input.name)) return said(MESSAGES.name)
  const onBehalf = input.on_behalf
  if ((!isUpdate || onBehalf !== undefined) && onBehalf !== 'person' && onBehalf !== 'self') return said(MESSAGES.onBehalf)
  const items = await taskItems(io, { isEverywhere: true })
  const read = await readEdits(io, input, items)
  if ('result' in read) return read
  const { edits } = read
  const session = await sessionOf(io)
  const body = isText(input.description) ? input.description : undefined
  const status = isText(input.status) ? input.status : undefined

  if (!isUpdate) {
    const { name, ...rest } = edits
    const place = await ownPlace(io)
    // Peek, not the agent, names the creator; only on_behalf chooses between Shawn and the calling session.
    const creator = onBehalf === 'person' ? PERSON : session.id
    const made = await createTask(tasksIoOf(io), place, { name: String(name), creator, ...(status ? { status } : {}), ...(body !== undefined ? { body } : {}) })
    if (made.status === 'refused') return said(`Could not save the task: ${made.reason}.`)
    await rewrite(io, made.path, { session: session.id, ...rest }, undefined)
    io.invalidate()
    return said(`${savedLine(String(name), made.id, status ?? 'todo')}\n${JSON.stringify({ id: made.id, path: made.path, creator })}`)
  }

  const item = await findTask(io, items, String(input.id))
  if (!item) return noTask(String(input.id))
  const isMirrored = item.source === 'mirrored'
  if (isMirrored && (Object.keys(edits).length || body !== undefined)) return said('A mirrored task changes only its status here; move it into a list with move_tasks to change more.')
  if (!isMirrored && (Object.keys(edits).length || body !== undefined)) await rewrite(io, item.href, edits, body)
  let reason = ''
  if (status) {
    const how = { by: session.id, source: 'tool' as const }
    if (isMirrored) {
      const outcome = await (await mirrorOf(io)).setStatus(item.href, status, how)
      if (outcome.status === 'refused') reason = outcome.reason
    } else {
      const { place, worktree } = await placeOfDoc(io, item.href)
      const outcome = await setStatus(tasksIoOf(io), place, { doc: item.href, status, ...how, writer: session.id, ...(worktree ? { worktree } : {}) })
      if (outcome.status === 'refused') reason = outcome.reason
    }
  }
  io.invalidate()
  if (reason) return said(`Could not set the status: ${reason}.`)
  const name = isText(edits.name) ? edits.name : item.name
  return said(`${savedLine(name, item.id, status ?? textOf(item, 'status') ?? 'no status')}\n${JSON.stringify({ id: item.id, path: item.href })}`)
}

async function targetOf(io: NavIo, to: string): Promise<{ place: TaskPlace; root: string } | Result> {
  const tio = tasksIoOf(io)
  if (to === 'user') {
    const user = await userPlace(tio)
    return { place: user, root: user.folder }
  }
  if (to === 'mine') {
    const place = await ownPlace(io)
    return { place, root: place.isUser ? place.folder : ((await sessionOf(io)).worktreeRoot ?? (await io.sessionRoot())) }
  }
  const root = resolvePath(to, await io.cwd(), (await io.home()) ?? '')
  const place = await capturePlace(tio, root)
  return place.isUser ? said(`${to} is not inside a git repo; use user for the user-level list.`) : { place, root }
}

type Moved = { ref: string; status: 'applied' | 'unchanged' | 'refused'; reason: string; doc?: string }

async function moveDoc(io: NavIo, item: Item, place: TaskPlace): Promise<Moved> {
  const tio = tasksIoOf(io)
  const ref = item.id
  if (item.source === 'mirrored') {
    const made = await (await mirrorOf(io)).adopt(item.href, await io.sessionId(), place)
    return { ref, ...made }
  }
  if (item.source === 'deliverable') return { ref, status: 'refused', reason: `${item.href} is a deliverable; it stays in its worktree` }
  if (textOf(item, 'mirror')) return { ref, status: 'refused', reason: 'It took over an agent\'s item, which still points at it, so it stays where it is' }
  const name = item.href.slice(item.href.lastIndexOf('/') + 1)
  const to = `${place.folder}/${name}`
  if (to === item.href) return { ref, status: 'unchanged', reason: 'Already there', doc: to }
  if (await tio.stat(to)) return { ref, status: 'refused', reason: `${to} already exists` }
  const made = await tio.run(['mkdir', '-p', place.folder]).catch(() => null)
  if (made?.exitCode !== 0) return { ref, status: 'refused', reason: `Could not create ${place.folder}` }
  if (place.excludeFile) await ensureExcluded(tio, place.excludeFile).catch(() => undefined)
  const moved = await tio.run(['mv', '-f', item.href, to]).catch(() => null)
  return moved?.exitCode === 0 ? { ref, status: 'applied', reason: `Moved to ${place.folder}`, doc: to } : { ref, status: 'refused', reason: `Could not move ${item.href}` }
}

async function moveTasks(io: NavIo, raw: unknown): Promise<Result> {
  const input = (raw ?? {}) as { tasks?: unknown; list?: unknown; to?: unknown }
  if (!isText(input.to) || !input.to.trim()) return said(MESSAGES.to)
  const hasTasks = input.tasks !== undefined
  if (!hasTasks && input.list === undefined) return said(MESSAGES.what)
  if (hasTasks && !(isTextList(input.tasks, CAPS.listed) && input.tasks.length)) return said(MESSAGES.what)
  if (input.list !== undefined && !(isText(input.list) && LIST.test(input.list))) return said(`${String(input.list)} is not a list; a list is <session id>#<n> from list_tasks.`)
  const target = await targetOf(io, input.to.trim())
  if ('result' in target) return target

  if (isText(input.list)) {
    const [, session = '', key = ''] = LIST.exec(input.list) ?? []
    const tio = tasksIoOf(io)
    const state = await readListState(tio, session, await mirrorRoot(tio)).catch(() => null)
    if (!state?.lists[key]) return said(`No list ${input.list}; use a list from list_tasks.`)
    await (await mirrorOf(io)).moveList(session, target.root)
    io.invalidate()
    return said(`Moved list ${input.list} to ${target.place.folder}.`)
  }

  const items = await taskItems(io, { isEverywhere: true })
  const found: Item[] = []
  for (const ref of input.tasks as string[]) {
    const item = await findTask(io, items, ref)
    if (!item) return noTask(ref)
    found.push(item)
  }
  const outcomes: Moved[] = []
  for (const item of found) outcomes.push(await moveDoc(io, item, target.place))
  io.invalidate()
  const moved = outcomes.filter(one => one.status === 'applied').length
  const refused = outcomes.filter(one => one.status === 'refused')
  const line = `Moved ${plural(moved, 'task')} to ${target.place.folder}${refused.length ? `; ${refused.length} refused: ${refused[0]?.reason}` : ''}.`
  return said(`${line}\n${JSON.stringify({ outcomes })}`)
}

async function checkView(io: NavIo, raw: unknown): Promise<Result> {
  const input = (raw ?? {}) as { path?: unknown; text?: unknown }
  let file = 'The definition'
  let text: string
  if (isText(input.text)) text = input.text
  else if (isText(input.path) && input.path.trim()) {
    file = resolvePath(input.path.trim(), await io.cwd(), (await io.home()) ?? '')
    const read = await io.readFile(file).catch(() => null)
    if (read === null) return said(`No file at ${file}.`)
    text = read
  } else return said(MESSAGES.view)
  const check = readDefinition(file, text)
  const problems = check.ok ? [] : check.problems.map(problemLine)
  if (check.ok) {
    // A type defined twice loads in neither file, so a clash with a loaded definition is a problem too.
    const clash = (await definitionsOf(io).catch(() => [])).find(one => one.type === check.definition.type && one.file !== file)
    if (clash) problems.push(`${file}: type "${check.definition.type}" is also defined by ${clash.file}; neither would load`)
  }
  if (!problems.length && check.ok) return said(`The definition of "${check.definition.type}" has no problems.`)
  return said(`${file} has ${plural(problems.length, 'problem')}; peek would not load it.\n${JSON.stringify({ problems })}`)
}

const REF_HELP = 'A task id from list_tasks, or the path of a task doc'

export const TASK_TOOLS: Record<TaskToolName, TaskTool> = {
  list_tasks: {
    spec: {
      name: 'list_tasks',
      description:
        "List the person's tasks and agent task lists that peek shows: the repo's tasks folder, the user-level list, tracked docs marked isTask, and every agent session's mirrored list. Each task has its id, name, path, status, creator, and when set its list, parent, sequence and due date. Call before save_task to find the id of a task to link or change.",
      inputSchema: {
        type: 'object',
        properties: {
          status: { type: 'string', enum: STATUSES },
          creator: { type: 'string', description: 'person for the tasks Shawn created, self for this session\'s, or a session id' },
          list: { type: 'string', description: 'An agent list, <session id>#<n>' },
        },
      },
    },
    run: listTasks,
  },
  read_task: {
    spec: {
      name: 'read_task',
      description: 'Read one task in full: every prop, its body text, and any required prop it is missing.',
      inputSchema: { type: 'object', properties: { id: { type: 'string', description: REF_HELP } }, required: ['id'] },
    },
    run: readTask,
  },
  save_task: {
    spec: {
      name: 'save_task',
      description:
        "Capture or change a task in peek. Without id it writes a new task doc in the person's list (this repo's .peek/tasks, or the user-level list outside a repo) with status todo unless you give one. Whenever the person mentions something to do, save it with on_behalf person; save your own work with on_behalf self. Peek records the creator itself: the person for on_behalf person, this session for self. With id it changes the given fields; status changes are logged. A mirrored task from an agent list changes only its status.",
      inputSchema: {
        type: 'object',
        properties: {
          id: { type: 'string', description: `${REF_HELP}; leave out to create one` },
          name: { type: 'string', description: `What to do, up to ${TASK_CAPS.name} characters` },
          on_behalf: { type: 'string', enum: ['person', 'self'], description: 'person: the person asked for this task. self: it is your own work' },
          status: { type: 'string', enum: STATUSES },
          description: { type: 'string', description: 'The body of the task doc' },
          sequence: {
            type: 'object',
            description: 'Where the task sits among others: after, before or with, each a task id or a list of ids',
            properties: { after: {}, before: {}, with: {} },
          },
          parent: { type: 'string', description: 'The task this one is part of' },
          due: { type: 'string', description: 'A date, YYYY-MM-DD' },
          attachments: { type: 'array', items: { type: 'string' }, description: 'File paths or URLs the task needs' },
        },
      },
    },
    run: saveTask,
  },
  move_tasks: {
    spec: {
      name: 'move_tasks',
      description:
        "Move tasks to another list. Moving an agent's mirrored task makes it a task doc in the target list that keeps its id and creator (adopting it). Moving a whole agent list (<session id>#<n>) moves where that session's lists belong, with their group. to is mine (this session's repo, or the user-level list outside a repo), user (the user-level list) or a folder inside another git repo.",
      inputSchema: {
        type: 'object',
        properties: {
          tasks: { type: 'array', items: { type: 'string' }, description: REF_HELP },
          list: { type: 'string', description: 'An agent list, <session id>#<n>, from list_tasks' },
          to: { type: 'string', description: 'mine, user, or a folder inside a git repo' },
        },
        required: ['to'],
      },
    },
    run: moveTasks,
  },
  check_view: {
    spec: {
      name: 'check_view',
      description:
        'Check a peek view definition (a markdown file with frontmatter props and a template of peek blocks) before you save it in ~/.local/share/claude-peek/views/. Reports every problem, including a type name another definition already uses, without loading it. Pass the text you are about to write, or the path of a file.',
      inputSchema: { type: 'object', properties: { path: { type: 'string' }, text: { type: 'string' } } },
    },
    run: checkView,
  },
}
