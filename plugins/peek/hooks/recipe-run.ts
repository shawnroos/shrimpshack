import type { McpToolResult, ProcessRunInit, ProcessRunResult } from 'claude-code'

import { cleanText, RECIPE_CAPS, validatePage } from './page'
import type { Page, Problem, Recipe } from './page'
import { loadRecipe } from './recipes'
import type { RecipesIo } from './recipes'

export type RunIo = RecipesIo & {
  envGet: (name: string) => Promise<string | undefined>
  run: (argv: readonly string[], init?: ProcessRunInit) => Promise<ProcessRunResult>
  mcpCall: (server: string, tool: string, args?: Record<string, unknown>) => Promise<McpToolResult>
  toolCheck: (check: { tool: string; input: unknown }) => Promise<{ decision: 'allow' | 'ask' | 'deny'; reason?: string }>
  now: () => Promise<number>
  sleep: (ms: number) => Promise<void>
}

export type RunTarget = { root: string; id: string; digest: string; draft: boolean }

export type RunFailure =
  | { kind: 'invalid-recipe'; problems: Problem[] }
  | { kind: 'changed-during-run'; phase: 'before' | 'after' }
  | { kind: 'needs-permission'; tool: string; command?: string; decision: 'ask' | 'deny'; reason?: string }
  | { kind: 'started-failed'; message: string }
  | { kind: 'timeout'; limitSeconds: number }
  | { kind: 'exit-nonzero'; exitCode: number; stderr: string }
  | { kind: 'output-truncated' }
  | { kind: 'not-JSON'; message: string }
  | { kind: 'server-not-connected'; server: string; message: string }
  | { kind: 'tool-error'; server: string; tool: string; message: string }
  | { kind: 'invalid-page'; problems: Problem[] }

export type RunOutcome =
  | { ok: true; kind: 'page'; id: string; name: string; digest: string; page: Page; ranAt: number }
  | ({ ok: false; id: string; name: string } & RunFailure)

export const EXCERPT_CHARS = 500
export const SCRIPT_ENV = ['HOME', 'PATH', 'LANG', 'TMPDIR'] as const
const ENV_BIN = '/usr/bin/env'
const REDACTED = '[redacted]'

type Loaded = Extract<Awaited<ReturnType<typeof loadRecipe>>, { ok: true }>
type Ran = { ok: true; text: string } | { ok: true; value: unknown } | ({ ok: false } & RunFailure)

const timeoutOf = (recipe: Recipe) => Math.min(recipe.source.timeoutSeconds ?? RECIPE_CAPS.defaultTimeoutSeconds, RECIPE_CAPS.timeoutSeconds)

function redact(text: string, secrets: readonly string[]): string {
  let out = text
  for (const secret of secrets.toSorted((a, b) => b.length - a.length)) out = out.replaceAll(secret, REDACTED)
  return out
}

export const excerpt = (text: string, secrets: readonly string[] = []): string => cleanText(redact(text, secrets).slice(0, EXCERPT_CHARS))

const shellWord = (word: string) => (/^[\w/.,:@%+=-]+$/.test(word) ? word : `'${word.replaceAll("'", String.raw`'\''`)}'`)

export const mcpToolName = (server: string, tool: string) => `mcp__${server.replaceAll(/[^\w-]/g, '_')}__${tool}`

function substitute(value: unknown, url: string): unknown {
  if (typeof value === 'string') return value.replaceAll('{{url}}', url)
  if (Array.isArray(value)) return value.map(one => substitute(one, url))
  if (typeof value === 'object' && value !== null) return Object.fromEntries(Object.entries(value).map(([key, one]) => [key, substitute(one, url)]))
  return value
}

async function scriptPath(io: RunIo, loaded: Loaded, run0: string): Promise<{ ok: true; script: string; folder: string } | { ok: false; problems: Problem[] }> {
  const refuse = (message: string) => ({ ok: false as const, problems: [{ path: 'source.run[0]', message: `"${run0}" ${message}` }] })
  const folder = await io.stat(loaded.dir).catch(() => undefined)
  const script = await io.stat(`${loaded.dir}/${run0.replace(/^\.\//, '')}`).catch(() => undefined)
  if (!folder?.realPath || !script?.realPath) return refuse('could not be resolved to a real path')
  if (script.isLink || script.kind !== 'file') return refuse('is not a regular file')
  if (!script.realPath.startsWith(`${folder.realPath}/`)) return refuse(`lands at ${script.realPath}, outside the recipe folder`)
  // /usr/bin/env reads any leading NAME=value word as an assignment, so a path holding = would not run as a command.
  if (script.realPath.includes('=')) return refuse('has = in its path, which env would read as a variable')
  return { ok: true, script: script.realPath, folder: folder.realPath }
}

async function timed<T>(io: RunIo, limitMs: number, call: () => Promise<T>): Promise<{ ok: true; value: T } | { ok: false; isTimeout: boolean; error: unknown }> {
  const startedAt = await io.now()
  try {
    return { ok: true, value: await call() }
  } catch (error) {
    return { ok: false, isTimeout: (await io.now()) - startedAt >= limitMs, error }
  }
}

async function runScript(io: RunIo, loaded: Loaded, source: { run: string[]; env?: string[] }, url: string, draft: boolean): Promise<Ran> {
  const resolved = await scriptPath(io, loaded, source.run[0] ?? '')
  if (!resolved.ok) return { ok: false, kind: 'invalid-recipe', problems: resolved.problems }
  const argv = [resolved.script, ...source.run.slice(1), url]
  if (draft) {
    const command = argv.map(word => shellWord(word)).join(' ')
    const check = await io.toolCheck({ tool: 'Bash', input: { command } })
    if (check.decision !== 'allow') return { ok: false, kind: 'needs-permission', tool: 'Bash', command, decision: check.decision, ...(check.reason ? { reason: check.reason } : {}) }
  }
  const pairs: string[] = []
  for (const name of SCRIPT_ENV) {
    const value = await io.envGet(name)
    if (value !== undefined) pairs.push(`${name}=${value}`)
  }
  pairs.push(`PEEK_URL=${url}`)
  const secrets: string[] = []
  for (const name of source.env ?? []) {
    if ((SCRIPT_ENV as readonly string[]).includes(name) || name === 'PEEK_URL') continue
    const value = await io.envGet(name)
    if (value === undefined) continue
    pairs.push(`${name}=${value}`)
    if (value) secrets.push(value)
  }
  const limitSeconds = timeoutOf(loaded.recipe)
  const limitMs = limitSeconds * 1000
  const ran = await timed(io, limitMs, () => io.run([ENV_BIN, '-i', ...pairs, ...argv], { cwd: resolved.folder, timeoutMs: limitMs }))
  if (!ran.ok) {
    return ran.isTimeout ? { ok: false, kind: 'timeout', limitSeconds } : { ok: false, kind: 'started-failed', message: excerpt(String(ran.error), secrets) }
  }
  const result = ran.value
  if (result.exitCode !== 0) return { ok: false, kind: 'exit-nonzero', exitCode: result.exitCode, stderr: excerpt(result.stderr, secrets) }
  if (result.isStdoutTruncated) return { ok: false, kind: 'output-truncated' }
  return { ok: true, text: result.stdout }
}

async function runMcp(io: RunIo, loaded: Loaded, source: { server: string; tool: string; args?: Record<string, unknown> }, url: string, draft: boolean): Promise<Ran> {
  const { server, tool } = source
  const args = substitute(source.args ?? {}, url) as Record<string, unknown>
  if (draft) {
    const name = mcpToolName(server, tool)
    const check = await io.toolCheck({ tool: name, input: args })
    if (check.decision !== 'allow') return { ok: false, kind: 'needs-permission', tool: name, decision: check.decision, ...(check.reason ? { reason: check.reason } : {}) }
  }
  const limitSeconds = timeoutOf(loaded.recipe)
  const limitMs = limitSeconds * 1000
  const expired = Symbol('expired')
  const ran = await timed(io, limitMs, () => Promise.race([io.mcpCall(server, tool, args), io.sleep(limitMs).then(() => expired)]))
  if (!ran.ok) return { ok: false, kind: 'server-not-connected', server, message: excerpt(String(ran.error)) }
  if (ran.value === expired) return { ok: false, kind: 'timeout', limitSeconds }
  const result = ran.value as McpToolResult
  const text = result.content
    .map(block => block as { type?: unknown; text?: unknown })
    .filter((block): block is { type: 'text'; text: string } => block.type === 'text' && typeof block.text === 'string')
    .map(block => block.text)
    .join('\n')
  if (result.isError) return { ok: false, kind: 'tool-error', server, tool, message: excerpt(text || 'the tool reported an error and said nothing more') }
  if (!text.trim() && result.structuredContent !== undefined) return { ok: true, value: result.structuredContent }
  return { ok: true, text }
}

export async function runRecipe(io: RunIo, target: RunTarget, url: string): Promise<RunOutcome> {
  const before = await loadRecipe(io, target.root, target.id)
  if (!before.ok) return { ok: false, id: target.id, name: target.id, kind: 'invalid-recipe', problems: before.problems }
  const named = { id: target.id, name: before.recipe.name }
  if (before.digest !== target.digest) return { ok: false, ...named, kind: 'changed-during-run', phase: 'before' }
  const { source } = before.recipe
  const ran = 'run' in source ? await runScript(io, before, source, url, target.draft) : await runMcp(io, before, source.mcp, url, target.draft)
  const ranAt = await io.now()
  if (!ran.ok && (ran.kind === 'invalid-recipe' || ran.kind === 'needs-permission')) return { ...ran, ...named }
  const after = await loadRecipe(io, target.root, target.id)
  if (!after.ok || after.digest !== target.digest) return { ok: false, ...named, kind: 'changed-during-run', phase: 'after' }
  if (!ran.ok) return { ...ran, ...named }
  let raw: unknown
  if ('value' in ran) raw = ran.value
  else {
    if (!ran.text.trim()) return { ok: false, ...named, kind: 'not-JSON', message: 'the source printed nothing; it must print one Page as JSON' }
    try {
      raw = JSON.parse(ran.text)
    } catch (error) {
      return { ok: false, ...named, kind: 'not-JSON', message: `${excerpt(String(error))}; output began ${JSON.stringify(excerpt(ran.text.trim().slice(0, 80)))}` }
    }
  }
  const checked = validatePage(raw)
  if (!checked.ok) return { ok: false, ...named, kind: 'invalid-page', problems: checked.problems }
  return { ok: true, kind: 'page', ...named, digest: target.digest, page: checked.page, ranAt }
}

export function failureText(outcome: Extract<RunOutcome, { ok: false }>): string {
  const who = `Recipe "${outcome.name}" (${outcome.id})`
  switch (outcome.kind) {
    case 'invalid-recipe': {
      return `${who} is invalid: ${outcome.problems.map(problem => `${problem.path} ${problem.message}`).join('; ')}`
    }
    case 'changed-during-run': {
      return outcome.phase === 'before'
        ? `${who} changed since it was loaded; open it again to run what is in the folder now`
        : `${who} changed while its source ran, so its output was discarded; open it again`
    }
    case 'needs-permission': {
      const what = outcome.command ? `Bash command ${outcome.command}` : `tool ${outcome.tool}`
      return `${who} is a draft, and this session would ${outcome.decision === 'deny' ? 'refuse' : 'ask before running'} the ${what}; allow it in the session's permissions, or approve the recipe in the pane`
    }
    case 'started-failed': {
      return `${who}: the script could not start: ${outcome.message}`
    }
    case 'timeout': {
      return `${who}: the source did not answer within ${outcome.limitSeconds} s`
    }
    case 'exit-nonzero': {
      return `${who}: the script exited with code ${outcome.exitCode}${outcome.stderr.trim() ? `: ${outcome.stderr.trim()}` : ''}`
    }
    case 'output-truncated': {
      return `${who}: the script printed more than 4 MiB, so its page was cut off`
    }
    case 'not-JSON': {
      return `${who}: the output is not JSON: ${outcome.message}`
    }
    case 'server-not-connected': {
      return `${who}: the MCP server "${outcome.server}" is not connected here: ${outcome.message}`
    }
    case 'tool-error': {
      return `${who}: the MCP tool ${outcome.tool} on "${outcome.server}" reported an error: ${outcome.message}`
    }
    case 'invalid-page': {
      return `${who} returned a page outside the vocabulary: ${outcome.problems.map(problem => `${problem.path} ${problem.message}`).join('; ')}`
    }
  }
}
