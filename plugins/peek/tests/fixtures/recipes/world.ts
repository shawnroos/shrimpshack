import type { McpToolResult, ProcessRunInit, ProcessRunResult } from 'claude-code'

import type { RunIo } from '../../../hooks/recipe-run'

export const HOME = '/home/u'
export const ROOT = `${HOME}/.local/share/claude-peek/recipes`

export const PAGE = { title: 'Design system', sections: [{ heading: 'Notes', block: { type: 'markdown', text: 'Hello' } }] }

type Node = { kind: 'file'; bytes: Uint8Array } | { kind: 'dir' } | { kind: 'link'; target: string }
type Body = string | Uint8Array | { link: string }

export type Child = { argv: readonly string[]; env: Record<string, string>; cwd?: string; stdin?: string }
export type ScriptAnswer = Partial<ProcessRunResult> | 'timeout' | Error
export type McpAnswer = McpToolResult | Error | 'hang'

type WorldOptions = {
  files: Record<string, Body>
  env?: Record<string, string>
  store?: Record<string, unknown>
  script?: (child: Child, world: World) => ScriptAnswer
  mcp?: (server: string, tool: string, args: Record<string, unknown> | undefined, world: World) => McpAnswer
  decision?: 'allow' | 'ask' | 'deny'
}

export type World = ReturnType<typeof world>

const encode = (text: string) => new TextEncoder().encode(text)

function base64(bytes: Uint8Array): string {
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary)
}

export function folder(id: string, recipe: Record<string, unknown>, extra: Record<string, Body> = {}): Record<string, Body> {
  const files: Record<string, Body> = {
    [`${ROOT}/${id}/recipe.json`]: JSON.stringify({ name: 'Figma files', match: [{ host: 'figma.com', path: '/file/*' }], ...recipe }),
  }
  for (const [path, body] of Object.entries(extra)) files[`${ROOT}/${id}/${path}`] = body
  return files
}

export const scriptFolder = (id: string, source: Record<string, unknown> = {}, extra: Record<string, Body> = {}) =>
  folder(id, { source: { run: ['./fetch.sh'], ...source } }, { 'fetch.sh': '#!/bin/sh\necho page\n', ...extra })

export const MAP_SCRIPT = '#!/usr/bin/env python3\nimport json, sys\nprint(json.load(sys.stdin)["text"])\n'

export const mcpFolder = (id: string, mcp: Record<string, unknown>, extra: Record<string, unknown> = {}, files: Record<string, Body> = {}) =>
  folder(id, { source: { mcp, map: ['./map.py'], ...extra } }, { 'map.py': MAP_SCRIPT, ...files })

// What a pass-through map prints: the tool's text, or its structured content when there is no text.
export function passThrough(child: Child): ScriptAnswer {
  const input = JSON.parse(child.stdin ?? '{}') as { text?: string; structured?: unknown }
  return { stdout: input.text || JSON.stringify(input.structured) }
}

// A world whose fs folds `..` and follows links the way `$.fs.stat({ resolve: true })` does, whose `$.process.run`
// applies `env -i` the way /usr/bin/env does, and whose clock moves only when a call takes time.
export function world(options: WorldOptions) {
  const nodes = new Map<string, Node>()
  const env = { HOME, PATH: '/usr/bin:/bin', LANG: 'en_US.UTF-8', TMPDIR: '/tmp/u/', ...options.env }
  const store = options.store ?? {}
  const calls = {
    run: [] as { argv: readonly string[]; init?: ProcessRunInit }[],
    children: [] as Child[],
    mcp: [] as { server: string; tool: string; args?: Record<string, unknown> }[],
    check: [] as { tool: string; input: unknown }[],
  }
  let clock = 1_000_000
  let hung = false

  const addDirs = (path: string) => {
    const parts = path.split('/').filter(Boolean)
    for (let index = 1; index < parts.length; index++) nodes.set(`/${parts.slice(0, index).join('/')}`, { kind: 'dir' })
  }
  const put = (path: string, body: Body) => {
    addDirs(path)
    if (typeof body === 'string') nodes.set(path, { kind: 'file', bytes: encode(body) })
    else if (body instanceof Uint8Array) nodes.set(path, { kind: 'file', bytes: body })
    else nodes.set(path, { kind: 'link', target: body.link })
  }
  for (const [path, body] of Object.entries(options.files)) put(path, body)

  const missing = (path: string) => Object.assign(new Error(`ENOENT: ${path}`), { code: 'ENOENT' })

  const resolve = (path: string, depth = 0): string | undefined => {
    if (depth > 20) return undefined
    const done: string[] = []
    const parts = path.split('/').filter(part => part !== '' && part !== '.')
    for (let index = 0; index < parts.length; index++) {
      const part = parts[index] ?? ''
      if (part === '..') {
        done.pop()
        continue
      }
      done.push(part)
      const here = `/${done.join('/')}`
      const node = nodes.get(here)
      if (!node) return undefined
      if (node.kind === 'link') {
        const rest = parts.slice(index + 1).join('/')
        return resolve(rest ? `${node.target}/${rest}` : node.target, depth + 1)
      }
    }
    return `/${done.join('/')}`
  }

  const self = {
    io: undefined as unknown as RunIo,
    calls,
    store,
    env,
    write: (path: string, body: Body) => put(path, body),
    advance: (ms: number) => {
      clock += ms
    },
    now: () => clock,
  }

  const io: RunIo = {
    home: async () => env.HOME,
    envGet: async name => env[name as keyof typeof env],
    list: async dir => {
      const real = resolve(dir)
      if (real === undefined || nodes.get(real)?.kind !== 'dir') throw missing(dir)
      return [...nodes.entries()]
        .filter(([path]) => path.slice(0, path.lastIndexOf('/')) === real)
        .map(([path, node]) => ({
          name: path.slice(path.lastIndexOf('/') + 1),
          kind: node.kind === 'link' ? 'other' : node.kind,
          size: node.kind === 'file' ? node.bytes.length : 0,
          isLink: node.kind === 'link',
        }))
    },
    read: async path => {
      const real = resolve(path)
      const node = real === undefined ? undefined : nodes.get(real)
      if (node?.kind !== 'file') throw missing(path)
      return { base64: base64(node.bytes) }
    },
    stat: async path => {
      const real = resolve(path)
      const node = real === undefined ? undefined : nodes.get(real)
      if (!node || real === undefined) throw missing(path)
      const own = nodes.get(path.replace(/\/+$/, ''))
      return { kind: node.kind === 'link' ? 'other' : node.kind, size: node.kind === 'file' ? node.bytes.length : 0, isLink: own?.kind === 'link', realPath: real }
    },
    storeGet: async key => store[key],
    run: async (argv, init) => {
      calls.run.push({ argv, init })
      const host: Record<string, string> = { ...env, ...init?.env }
      let childEnv = host
      let index = 0
      if (argv[0] === '/usr/bin/env') {
        index = 1
        if (argv[1] === '-i') {
          childEnv = {}
          index = 2
        } else childEnv = { ...host }
        while (index < argv.length && (argv[index] ?? '').includes('=')) {
          const pair = argv[index] ?? ''
          childEnv[pair.slice(0, pair.indexOf('='))] = pair.slice(pair.indexOf('=') + 1)
          index++
        }
      }
      const child: Child = { argv: argv.slice(index), env: childEnv, ...(init?.cwd === undefined ? {} : { cwd: init.cwd }), ...(init?.stdin === undefined ? {} : { stdin: init.stdin }) }
      calls.children.push(child)
      const answer = options.script ? options.script(child, self) : (child.stdin === undefined ? { stdout: JSON.stringify(PAGE) } : passThrough(child))
      if (answer === 'timeout') {
        clock += init?.timeoutMs ?? 30_000
        throw new Error(`command timed out: ${argv.join(' ')}`)
      }
      if (answer instanceof Error) {
        clock += 3
        throw answer
      }
      clock += 40
      return { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false, ...answer }
    },
    mcpCall: async (server, tool, args) => {
      calls.mcp.push({ server, tool, ...(args === undefined ? {} : { args }) })
      const answer = options.mcp ? options.mcp(server, tool, args, self) : { content: [{ type: 'text', text: JSON.stringify(PAGE) }], isError: false }
      if (answer === 'hang') {
        hung = true
        return new Promise<McpToolResult>(() => {})
      }
      if (answer instanceof Error) throw answer
      clock += 40
      return answer
    },
    toolCheck: async check => {
      calls.check.push(check)
      return { decision: options.decision ?? 'allow', reason: options.decision === 'allow' ? undefined : 'Bash needs approval' }
    },
    now: async () => clock,
    sleep: async ms => {
      if (!hung) return new Promise<void>(() => {})
      clock += ms
    },
  }
  self.io = io
  return self
}
