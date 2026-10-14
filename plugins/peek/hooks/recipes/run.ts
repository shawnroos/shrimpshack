import type { McpToolResult, ProcessRunInit } from 'claude-code'

import { cleanText, RECIPE_CAPS, UNSAFE, validatePage } from './page'
import type { McpSource, Page, Problem, Recipe } from './page'
import { loadRecipe, mcpToolName } from './recipes'
import type { RecipesIo } from './recipes'
import type { Ports } from '../ports'

export type RunIo = RecipesIo & Pick<Ports, 'envGet' | 'run' | 'mcpCall' | 'toolCheck' | 'now' | 'sleep'>

export type RunTarget = { root: string; id: string; digest: string; draft: boolean }

export type RunFailure =
  | { kind: 'invalid-recipe'; problems: Problem[] }
  | { kind: 'changed-during-run'; phase: 'before' | 'after' }
  | { kind: 'needs-permission'; tool: string; command?: string; decision: 'ask' | 'deny'; reason?: string }
  | { kind: 'started-failed'; message: string }
  | { kind: 'timeout'; limitSeconds: number }
  | { kind: 'exit-nonzero'; exitCode: number; stderr: string; stdin?: string }
  | { kind: 'output-truncated' }
  | { kind: 'not-JSON'; message: string; stdin?: string }
  | { kind: 'server-not-connected'; server: string; message: string }
  | { kind: 'tool-error'; server: string; tool: string; message: string }
  | { kind: 'empty-result'; server: string; tool: string }
  | { kind: 'invalid-page'; problems: Problem[]; stdin?: string }

// The fields holding text a source wrote; everything else in a failure is what peek decided about the run.
export const SOURCE_FIELDS: Partial<Record<RunFailure['kind'], readonly string[]>> = {
  'started-failed': ['message'],
  'exit-nonzero': ['stderr', 'stdin'],
  'not-JSON': ['message', 'stdin'],
  'server-not-connected': ['message'],
  'tool-error': ['message'],
  'invalid-page': ['problems', 'stdin'],
}

export type RunOutcome =
  | { ok: true; kind: 'page'; id: string; name: string; digest: string; page: Page; ranAt: number }
  | ({ ok: false; id: string; name: string } & RunFailure)

export const EXCERPT_CHARS = 500
export const STDIN_ECHO_CHARS = 8000
export const SCRIPT_ENV = ['HOME', 'PATH', 'LANG', 'TMPDIR'] as const
const ENV_BIN = '/usr/bin/env'
const REDACTED = '[redacted]'

type Loaded = Extract<Awaited<ReturnType<typeof loadRecipe>>, { ok: true }>
type Ran = { ok: true; text: string; secrets: readonly string[]; rawStdin?: string } | ({ ok: false } & RunFailure)
type Script = { field: 'run' | 'map'; argv: readonly string[]; env?: readonly string[] }
type Resolved = { folder: string; argv: string[]; command: string }

const timeoutOf = (recipe: Recipe) => Math.min(recipe.source.timeoutSeconds ?? RECIPE_CAPS.defaultTimeoutSeconds, RECIPE_CAPS.timeoutSeconds)

function redact(text: string, secrets: readonly string[]): string {
  let out = text
  for (const secret of secrets.toSorted((a, b) => b.length - a.length)) out = out.replaceAll(secret, REDACTED)
  return out
}

export const excerpt = (text: string, secrets: readonly string[] = []): string => cleanText(redact(text, secrets).slice(0, EXCERPT_CHARS))

// The stdin is JSON, so unsafe characters are escaped rather than stripped: the echo still parses to what the map read.
const stdinEcho = (stdin: string, secrets: readonly string[]): string =>
  redact(stdin, secrets)
    .slice(0, STDIN_ECHO_CHARS)
    .replaceAll(UNSAFE, char => `${String.raw`\u`}${(char.codePointAt(0) ?? 0).toString(16).padStart(4, '0')}`)

export const mapStdin = (text: string, structured: unknown): string => `${JSON.stringify({ text, structured: structured ?? null })}\n`

const shellWord = (word: string) => (/^[\w/.,:@%+=-]+$/.test(word) ? word : `'${word.replaceAll("'", String.raw`'\''`)}'`)

function substitute(value: unknown, url: string): unknown {
  if (typeof value === 'string') return value.replaceAll('{{url}}', url)
  if (Array.isArray(value)) return value.map(one => substitute(one, url))
  if (typeof value === 'object' && value !== null) return Object.fromEntries(Object.entries(value).map(([key, one]) => [key, substitute(one, url)]))
  return value
}

async function resolveScript(io: RunIo, loaded: Loaded, script: Script, url: string): Promise<{ ok: true; resolved: Resolved } | { ok: false; problems: Problem[] }> {
  const run0 = script.argv[0] ?? ''
  const refuse = (message: string) => ({ ok: false as const, problems: [{ path: `source.${script.field}[0]`, message: `"${run0}" ${message}` }] })
  const folder = await io.statResolved(loaded.dir).catch(() => undefined)
  const file = await io.statResolved(`${loaded.dir}/${run0.replace(/^\.\//, '')}`).catch(() => undefined)
  if (!folder?.realPath || !file?.realPath) return refuse('could not be resolved to a real path')
  if (file.isLink || file.kind !== 'file') return refuse('is not a regular file')
  if (!file.realPath.startsWith(`${folder.realPath}/`)) return refuse(`lands at ${file.realPath}, outside the recipe folder`)
  // /usr/bin/env reads any leading NAME=value word as an assignment, so a path holding = would not run as a command.
  if (file.realPath.includes('=')) return refuse('has = in its path, which env would read as a variable')
  const argv = [file.realPath, ...script.argv.slice(1), url]
  return { ok: true, resolved: { folder: folder.realPath, argv, command: argv.map(word => shellWord(word)).join(' ') } }
}

async function refusedBash(io: RunIo, resolved: Resolved): Promise<({ ok: false } & RunFailure) | undefined> {
  const check = await io.toolCheck({ tool: 'Bash', input: { command: resolved.command } })
  if (check.decision === 'allow') return undefined
  return { ok: false, kind: 'needs-permission', tool: 'Bash', command: resolved.command, decision: check.decision, ...(check.reason ? { reason: check.reason } : {}) }
}

async function timed<T>(io: RunIo, limitMs: number, call: () => Promise<T>): Promise<{ ok: true; value: T } | { ok: false; isTimeout: boolean; error: unknown }> {
  const startedAt = await io.now()
  try {
    return { ok: true, value: await call() }
  } catch (error) {
    return { ok: false, isTimeout: (await io.now()) - startedAt >= limitMs, error }
  }
}

async function exec(io: RunIo, resolved: Resolved, script: Script, url: string, limit: { seconds: number; leftMs: number }, stdin?: string): Promise<Ran> {
  const declared = (script.env ?? []).filter(name => !(SCRIPT_ENV as readonly string[]).includes(name) && name !== 'PEEK_URL')
  const [fixed, values] = await Promise.all([Promise.all(SCRIPT_ENV.map(name => io.envGet(name))), Promise.all(declared.map(name => io.envGet(name)))])
  const pairs = SCRIPT_ENV.flatMap((name, index) => (fixed[index] === undefined ? [] : [`${name}=${fixed[index]}`]))
  pairs.push(`PEEK_URL=${url}`)
  const secrets: string[] = []
  for (const [index, name] of declared.entries()) {
    const value = values[index]
    if (value === undefined) continue
    pairs.push(`${name}=${value}`)
    if (value) secrets.push(value)
  }
  const init: ProcessRunInit = { cwd: resolved.folder, timeoutMs: limit.leftMs, ...(stdin === undefined ? {} : { stdin }) }
  const ran = await timed(io, limit.leftMs, () => io.run([ENV_BIN, '-i', ...pairs, ...resolved.argv], init))
  if (!ran.ok) {
    return ran.isTimeout ? { ok: false, kind: 'timeout', limitSeconds: limit.seconds } : { ok: false, kind: 'started-failed', message: excerpt(String(ran.error), secrets) }
  }
  const result = ran.value
  if (result.exitCode !== 0) return { ok: false, kind: 'exit-nonzero', exitCode: result.exitCode, stderr: excerpt(result.stderr, secrets), ...(stdin === undefined ? {} : { stdin: stdinEcho(stdin, secrets) }) }
  if (result.isStdoutTruncated) return { ok: false, kind: 'output-truncated' }
  return { ok: true, text: result.stdout, secrets, ...(stdin === undefined ? {} : { rawStdin: stdin }) }
}

async function runScript(io: RunIo, loaded: Loaded, source: { run: string[]; env?: string[] }, url: string, draft: boolean): Promise<Ran> {
  const script: Script = { field: 'run', argv: source.run, ...(source.env ? { env: source.env } : {}) }
  const found = await resolveScript(io, loaded, script, url)
  if (!found.ok) return { ok: false, kind: 'invalid-recipe', problems: found.problems }
  const refused = draft ? await refusedBash(io, found.resolved) : undefined
  if (refused) return refused
  const seconds = timeoutOf(loaded.recipe)
  return exec(io, found.resolved, script, url, { seconds, leftMs: seconds * 1000 })
}

async function runMcp(io: RunIo, loaded: Loaded, source: McpSource, url: string, draft: boolean): Promise<Ran> {
  const { server, tool } = source.mcp
  const args = substitute(source.mcp.args ?? {}, url) as Record<string, unknown>
  const script: Script = { field: 'map', argv: source.map, ...(source.env ? { env: source.env } : {}) }
  const found = await resolveScript(io, loaded, script, url)
  if (!found.ok) return { ok: false, kind: 'invalid-recipe', problems: found.problems }
  if (draft) {
    const name = mcpToolName(server, tool)
    const check = await io.toolCheck({ tool: name, input: args })
    if (check.decision !== 'allow') return { ok: false, kind: 'needs-permission', tool: name, decision: check.decision, ...(check.reason ? { reason: check.reason } : {}) }
    const refused = await refusedBash(io, found.resolved)
    if (refused) return refused
  }
  const seconds = timeoutOf(loaded.recipe)
  const limitMs = seconds * 1000
  const startedAt = await io.now()
  const expired = Symbol('expired')
  const ran = await timed(io, limitMs, () => Promise.race([io.mcpCall(server, tool, args), io.sleep(limitMs).then(() => expired)]))
  if (!ran.ok) return { ok: false, kind: 'server-not-connected', server, message: excerpt(String(ran.error)) }
  if (ran.value === expired) return { ok: false, kind: 'timeout', limitSeconds: seconds }
  const result = ran.value as McpToolResult
  const text = result.content
    .map(block => block as { type?: unknown; text?: unknown })
    .filter((block): block is { type: 'text'; text: string } => block.type === 'text' && typeof block.text === 'string')
    .map(block => block.text)
    .join('\n')
  if (result.isError) return { ok: false, kind: 'tool-error', server, tool, message: excerpt(text || 'the tool reported an error and said nothing more') }
  if (!text.trim() && (result.structuredContent ?? null) === null) return { ok: false, kind: 'empty-result', server, tool }
  const leftMs = limitMs - ((await io.now()) - startedAt)
  if (leftMs <= 0) return { ok: false, kind: 'timeout', limitSeconds: seconds }
  return exec(io, found.resolved, script, url, { seconds, leftMs }, mapStdin(text, result.structuredContent))
}

export async function runRecipe(io: RunIo, target: RunTarget, url: string): Promise<RunOutcome> {
  const before = await loadRecipe(io, target.root, target.id)
  if (!before.ok) return { ok: false, id: target.id, name: target.id, kind: 'invalid-recipe', problems: before.problems }
  const named = { id: target.id, name: before.recipe.name }
  if (before.digest !== target.digest) return { ok: false, ...named, kind: 'changed-during-run', phase: 'before' }
  const { source } = before.recipe
  const ran = 'run' in source ? await runScript(io, before, source, url, target.draft) : await runMcp(io, before, source, url, target.draft)
  const ranAt = await io.now()
  if (!ran.ok && (ran.kind === 'invalid-recipe' || ran.kind === 'needs-permission')) return { ...ran, ...named }
  const after = await loadRecipe(io, target.root, target.id)
  if (!after.ok || after.digest !== target.digest) return { ok: false, ...named, kind: 'changed-during-run', phase: 'after' }
  if (!ran.ok) return { ...ran, ...named }
  const echo = () => (ran.rawStdin === undefined ? {} : { stdin: stdinEcho(ran.rawStdin, ran.secrets) })
  if (!ran.text.trim()) return { ok: false, ...named, kind: 'not-JSON', message: 'the source printed nothing; it must print one Page as JSON', ...echo() }
  let raw: unknown
  try {
    raw = JSON.parse(ran.text)
  } catch (error) {
    // The parser's own message quotes the stdout it choked on, so it is redacted like the excerpt.
    return { ok: false, ...named, kind: 'not-JSON', message: `${excerpt(String(error), ran.secrets)}; output began ${JSON.stringify(excerpt(ran.text.trim(), ran.secrets).slice(0, 80))}`, ...echo() }
  }
  const checked = validatePage(raw)
  if (!checked.ok) return { ok: false, ...named, kind: 'invalid-page', problems: checked.problems, ...echo() }
  return { ok: true, kind: 'page', ...named, digest: target.digest, page: checked.page, ranAt }
}

// Quiet leaves out what the source wrote, so the text can go where only peek's own words belong.
export function recipeFailureText(outcome: Extract<RunOutcome, { ok: false }>, { isQuiet = false } = {}): string {
  const who = `Recipe "${outcome.name}" (${outcome.id})`
  const said = (text: string) => (isQuiet ? 'see fetched.message' : text)
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
      return `${who}: the script could not start: ${said(outcome.message)}`
    }
    case 'timeout': {
      return `${who}: the source did not answer within ${outcome.limitSeconds} s`
    }
    case 'exit-nonzero': {
      return `${who}: the script exited with code ${outcome.exitCode}${outcome.stderr.trim() && !isQuiet ? `: ${outcome.stderr.trim()}` : ''}`
    }
    case 'output-truncated': {
      return `${who}: the script printed more than 4 MiB, so its page was cut off`
    }
    case 'not-JSON': {
      return `${who}: the output is not JSON: ${said(outcome.message)}`
    }
    case 'server-not-connected': {
      return `${who}: the MCP server "${outcome.server}" is not connected here: ${said(outcome.message)}`
    }
    case 'tool-error': {
      return `${who}: the MCP tool ${outcome.tool} on "${outcome.server}" reported an error: ${said(outcome.message)}`
    }
    case 'empty-result': {
      return `${who}: the MCP tool ${outcome.tool} on "${outcome.server}" returned nothing, no text and no structured content`
    }
    case 'invalid-page': {
      return `${who} returned a page outside the vocabulary: ${outcome.problems.map(problem => (problem.message && !isQuiet ? `${problem.path} ${problem.message}` : problem.path)).join('; ')}`
    }
  }
}
