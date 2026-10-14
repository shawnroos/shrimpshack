import type { TasksIo } from '../tasks/store'
import { asObj, tryJson } from '../wire'
import type { AgentItem } from './records'

// peek's fs.read refuses files over 4 MiB, so a longer transcript is read from its tail.
const TAIL_BYTES = 4_000_000
const PROJECT_DIRS = 500

const textOf = (value: unknown) => (typeof value === 'string' ? value : typeof value === 'number' ? String(value) : undefined)
const listOf = (value: unknown) => (Array.isArray(value) ? value.flatMap(one => textOf(one) ?? []) : [])

function blocksOf(line: Record<string, unknown>): Record<string, unknown>[] {
  const content = asObj(line.message)?.content
  if (!Array.isArray(content)) return []
  return content.flatMap((one): Record<string, unknown>[] => {
    const block = asObj(one)
    return block ? [block] : []
  })
}

export function rebuildItems(text: string): AgentItem[] {
  const creates = new Map<string, Record<string, unknown>>()
  const items = new Map<string, AgentItem>()
  for (const raw of text.split('\n')) {
    const line = asObj(tryJson(raw))
    if (!line) continue
    for (const block of blocksOf(line)) {
      const input = asObj(block.input)
      if (block.type === 'tool_use' && block.name === 'TaskCreate' && input && typeof block.id === 'string') creates.set(block.id, input)
      if (block.type === 'tool_use' && block.name === 'TaskUpdate' && input) {
        const known = items.get(textOf(input.taskId) ?? '')
        if (!known) continue
        const status = textOf(input.status)
        const subject = textOf(input.subject)
        if (status) known.status = status
        if (subject) known.subject = subject
        known.blockedBy = [...new Set([...known.blockedBy, ...listOf(input.addBlockedBy)])]
      }
      if (block.type === 'tool_result' && typeof block.tool_use_id === 'string') {
        const input = creates.get(block.tool_use_id)
        const id = textOf(asObj(asObj(line.toolUseResult)?.task)?.id) ?? /Task #(\d+)/.exec(String(block.content ?? ''))?.[1]
        const subject = textOf(input?.subject)
        if (!input || !id || !subject) continue
        const description = textOf(input.description)
        items.set(id, { id, subject, status: 'pending', blockedBy: [], ...(description ? { description } : {}) })
      }
    }
  }
  return [...items.values()].sort((a, b) => Number(a.id) - Number(b.id))
}

export function transcriptCwd(text: string): string | undefined {
  for (const raw of text.split('\n')) {
    const cwd = asObj(tryJson(raw))?.cwd
    if (typeof cwd === 'string' && cwd.startsWith('/')) return cwd
  }
  return undefined
}

export async function findTranscript(io: TasksIo, home: string, session: string): Promise<string | null> {
  const projects = `${home}/.claude/projects`
  const dirs = (await io.list(projects).catch(() => [])).filter(one => one.kind === 'dir').slice(0, PROJECT_DIRS)
  for (const dir of dirs) {
    const path = `${projects}/${dir.name}/${session}.jsonl`
    if (await io.stat(path)) return path
  }
  return null
}

export async function readTranscript(io: TasksIo, path: string): Promise<string> {
  const whole = await io.read(path).catch(() => null)
  if (whole !== null) return whole
  const tail = await io.run(['tail', '-c', String(TAIL_BYTES), path]).catch(() => null)
  return tail?.exitCode === 0 ? tail.stdout.slice(tail.stdout.indexOf('\n') + 1) : ''
}
