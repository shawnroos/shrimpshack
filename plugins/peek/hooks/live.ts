import type { ProcessRunInit, ProcessRunResult } from 'claude-code'

const HELPER_SOURCE = 'helper/peek-web.swift'
const CACHE_DIR = '.cache/claude-peek/bin'
// A cold `swiftc -O` of the helper took 38 s on an M-series Mac; leave room for a slower machine.
const BUILD_TIMEOUT_MS = 180_000

// `$` cannot cross an import (claude plugin validate), so register.tsx builds this port from `$`.
export type BuildIo = {
  root: string
  home: () => Promise<string | undefined>
  read: (path: string) => Promise<string>
  exists: (path: string) => Promise<boolean>
  run: (argv: readonly string[], init?: ProcessRunInit) => Promise<ProcessRunResult>
}

export type Built = { ok: true; path: string; isBuilt: boolean } | { ok: false; failure: 'live-unavailable'; reason: string }

async function sourceHash(source: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(source))
  return [...new Uint8Array(digest).slice(0, 8)].map(byte => byte.toString(16).padStart(2, '0')).join('')
}

export async function helperBinary(io: BuildIo & { beforeBuild?: () => void }): Promise<Built> {
  const sourcePath = `${io.root}/${HELPER_SOURCE}`
  const source = await io.read(sourcePath).catch(() => null)
  if (source === null) return { ok: false, failure: 'live-unavailable', reason: 'the helper source is missing' }
  const home = await io.home()
  if (!home) return { ok: false, failure: 'live-unavailable', reason: 'HOME is not set' }
  const dir = `${home}/${CACHE_DIR}`
  const path = `${dir}/peek-web-${await sourceHash(source)}`
  if (await io.exists(path)) return { ok: true, path, isBuilt: false }

  const found = await io.run(['sh', '-c', 'command -v swiftc']).catch(() => null)
  if (found?.exitCode !== 0) return { ok: false, failure: 'live-unavailable', reason: 'swiftc not found' }
  io.beforeBuild?.()
  const staged = `${path}.building`
  const steps: (readonly string[])[] = [
    ['mkdir', '-p', dir],
    ['swiftc', '-O', sourcePath, '-o', staged],
    ['codesign', '-s', '-', '-f', staged],
    ['mv', '-f', staged, path],
  ]
  for (const argv of steps) {
    const ran = await io.run(argv, { timeoutMs: BUILD_TIMEOUT_MS }).catch((error: unknown) => exited(-1, String(error)))
    if (ran.exitCode !== 0) {
      const detail = ran.stderr.split('\n').find(line => line.includes('error')) ?? ran.stderr.split('\n')[0] ?? ''
      return { ok: false, failure: 'live-unavailable', reason: `${argv[0]} failed${detail ? `: ${detail.slice(0, 160)}` : ''}` }
    }
  }
  return { ok: true, path, isBuilt: true }
}

function exited(exitCode: number, stderr: string): ProcessRunResult {
  return { exitCode, stdout: '', stderr, isStdoutTruncated: false, isStderrTruncated: false }
}

export type LoadState = 'loading' | 'ready' | 'failed'

export type LiveEvent =
  | { t: 'ready'; socket: string; dir: string; isThrottled: boolean }
  | { t: 'frame'; id: number; path: string; width: number; height: number }
  | { t: 'nav'; url: string; title: string; canBack: boolean; canForward: boolean }
  | { t: 'load'; state: LoadState; error?: string }
  | { t: 'focus'; isEditable: boolean }
  | { t: 'cookies'; isPresent: boolean }
  | { t: 'error'; message: string }

const isString = (value: unknown): value is string => typeof value === 'string'
const isNumber = (value: unknown): value is number => typeof value === 'number' && Number.isFinite(value)
const isBool = (value: unknown): value is boolean => typeof value === 'boolean'

export function parseEvent(line: string): LiveEvent | null {
  let raw: unknown
  try {
    raw = JSON.parse(line)
  } catch {
    return null
  }
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null
  const e = raw as Record<string, unknown>
  switch (e.t) {
    case 'ready':
      return isString(e.socket) && isString(e.dir) ? { t: 'ready', socket: e.socket, dir: e.dir, isThrottled: e.throttled === true } : null
    case 'frame':
      return isNumber(e.id) && isString(e.path) && isNumber(e.width) && isNumber(e.height)
        ? { t: 'frame', id: e.id, path: e.path, width: e.width, height: e.height }
        : null
    case 'nav':
      return isString(e.url) && isBool(e.canBack) && isBool(e.canForward)
        ? { t: 'nav', url: e.url, title: isString(e.title) ? e.title : '', canBack: e.canBack, canForward: e.canForward }
        : null
    case 'load':
      if (e.state !== 'loading' && e.state !== 'ready' && e.state !== 'failed') return null
      return isString(e.error) ? { t: 'load', state: e.state, error: e.error } : { t: 'load', state: e.state }
    case 'focus':
      return isBool(e.editable) ? { t: 'focus', isEditable: e.editable } : null
    case 'cookies':
      return isBool(e.present) ? { t: 'cookies', isPresent: e.present } : null
    case 'error':
      return isString(e.message) ? { t: 'error', message: e.message } : null
    default:
      return null
  }
}

export function splitLines(rest: string, text: string): { lines: string[]; rest: string } {
  const parts = (rest + text).split('\n')
  const tail = parts.pop() ?? ''
  return { lines: parts.filter(line => line.trim() !== ''), rest: tail }
}

export type LiveFailureKind = 'live-unavailable' | 'live-crashed' | 'live-stalled'

export type Viewport = { width: number; height: number }

export type LiveState = {
  phase: 'off' | 'building' | 'starting' | 'live'
  isShown: boolean
  url?: string
  title: string
  canBack: boolean
  canForward: boolean
  load?: LoadState
  loadError?: string
  frame?: { id: number; path: string; width: number; height: number }
  isEditable: boolean
  hasCookies: boolean
  isThrottled: boolean
  failure?: { kind: LiveFailureKind; reason: string }
}

export type Timer = { cancel: () => void }

export type LiveIo = BuildIo & {
  spawn: (argv: readonly string[]) => AsyncGenerator<{ stream: 'stdout' | 'stderr'; text: string }, unknown>
  post: (socket: string, path: string, body?: unknown) => Promise<boolean>
  after: (ms: number, fn: () => void) => Timer
  removeDir: (dir: string) => Promise<void>
}

export type LiveCommand = 'navigate' | 'back' | 'reload' | 'resize' | 'input'

const STALL_MS = 10_000
const IDLE_MS = 60_000

export function isWebUrl(url: string): boolean {
  try {
    const { protocol } = new URL(url)
    return protocol === 'http:' || protocol === 'https:'
  } catch {
    return false
  }
}

function initial(): LiveState {
  return { phase: 'off', isShown: false, title: '', canBack: false, canForward: false, isEditable: false, hasCookies: false, isThrottled: false }
}

export function createLive(io: LiveIo, onChange: (state: LiveState, event?: LiveEvent) => void) {
  let state = initial()
  let child: AsyncGenerator<unknown, unknown> | null = null
  let socket: string | null = null
  let dir: string | null = null
  let pendingUrl: string | null = null
  let viewport: Viewport | null = null
  let stallTimer: Timer | null = null
  let idleTimer: Timer | null = null
  let generation = 0

  const set = (patch: Partial<LiveState>, event?: LiveEvent) => {
    state = { ...state, ...patch }
    onChange(state, event)
  }
  const clearTimers = () => {
    stallTimer?.cancel()
    idleTimer?.cancel()
    stallTimer = idleTimer = null
  }
  const send = (path: string, body?: unknown) => (socket ? io.post(socket, path, body).catch(() => false) : Promise.resolve(false))

  async function shutdown(failure?: LiveState['failure']) {
    generation += 1
    clearTimers()
    const running = child
    const runDir = dir
    if (socket) await send('quit')
    child = null
    socket = dir = pendingUrl = null
    // Not awaited: a stream blocked on its next read settles return() only after that read, and the engine kills the child on return() either way.
    void running?.return(undefined).catch(() => undefined)
    if (runDir) await io.removeDir(runDir).catch(() => undefined)
    state = { ...initial(), ...(failure ? { failure } : {}) }
    onChange(state)
  }

  const armIdle = () => {
    idleTimer?.cancel()
    idleTimer = null
    if (state.isShown || state.hasCookies || state.phase === 'off') return
    const armedFor = generation
    idleTimer = io.after(IDLE_MS, () => {
      if (armedFor === generation && !state.isShown && !state.hasCookies) void shutdown()
    })
  }

  async function onEvent(event: LiveEvent, ownGeneration: number) {
    if (ownGeneration !== generation) return
    switch (event.t) {
      case 'ready': {
        socket = event.socket
        dir = event.dir
        set({ isThrottled: event.isThrottled }, event)
        const url = pendingUrl
        pendingUrl = null
        if (url) await send('navigate', { url })
        if (!state.isShown) await send('pause')
        stallTimer = io.after(STALL_MS, () => {
          if (ownGeneration === generation && !state.frame) void shutdown({ kind: 'live-stalled', reason: 'no picture from the page within 10 seconds' })
        })
        return
      }
      case 'frame':
        stallTimer?.cancel()
        stallTimer = null
        set({ frame: { id: event.id, path: event.path, width: event.width, height: event.height }, phase: 'live' }, event)
        return
      case 'nav':
        set({ url: event.url, title: event.title, canBack: event.canBack, canForward: event.canForward }, event)
        return
      case 'load':
        set({ load: event.state, loadError: event.error }, event)
        return
      case 'focus':
        set({ isEditable: event.isEditable }, event)
        return
      case 'cookies':
        set({ hasCookies: event.isPresent }, event)
        armIdle()
        return
      case 'error':
        onChange(state, event)
        return
    }
  }

  async function read(stream: AsyncGenerator<{ stream: 'stdout' | 'stderr'; text: string }, unknown>, ownGeneration: number) {
    let rest = ''
    try {
      for await (const chunk of stream) {
        if (chunk.stream !== 'stdout') continue
        const split = splitLines(rest, chunk.text)
        rest = split.rest
        for (const line of split.lines) {
          const event = parseEvent(line)
          if (event) await onEvent(event, ownGeneration)
        }
      }
    } catch {
      // A spawn that cannot start rejects its first pull; that is a crash like any other exit.
    }
    if (ownGeneration !== generation) return
    const wasShown = state.isShown && state.phase !== 'off'
    await shutdown(wasShown ? { kind: 'live-crashed', reason: 'the live view helper stopped' } : undefined)
  }

  async function start(url: string, size: Viewport): Promise<boolean> {
    if (!isWebUrl(url)) return false
    idleTimer?.cancel()
    idleTimer = null
    const sizeChanged = viewport !== null && (viewport.width !== size.width || viewport.height !== size.height)
    viewport = size
    const wasShown = state.isShown
    if (state.phase !== 'off') {
      set({ isShown: true, failure: undefined })
      if (!socket) {
        pendingUrl = url
        return true
      }
      if (!wasShown) await send('resume')
      if (sizeChanged) await send('resize', size)
      if (url !== state.url) await send('navigate', { url })
      return true
    }
    const ownGeneration = ++generation
    pendingUrl = url
    set({ phase: 'starting', isShown: true, url, failure: undefined })
    const built = await helperBinary({ ...io, beforeBuild: () => set({ phase: 'building' }) })
    if (ownGeneration !== generation) return true
    if (!built.ok) {
      await shutdown({ kind: built.failure, reason: built.reason })
      return false
    }
    set({ phase: 'starting' })
    const stream = io.spawn([built.path, '--width', String(size.width), '--height', String(size.height)])
    child = stream
    void read(stream, ownGeneration)
    return true
  }

  async function leave() {
    if (state.phase === 'off' || !state.isShown) return
    set({ isShown: false, isEditable: false })
    await send('pause')
    armIdle()
  }

  async function command(path: LiveCommand, body?: unknown): Promise<boolean> {
    if (path === 'navigate') {
      const url = (body as { url?: unknown } | undefined)?.url
      if (typeof url !== 'string' || !isWebUrl(url)) return false
    }
    if (path === 'resize' && body) viewport = body as Viewport
    return send(path, body)
  }

  return {
    state: () => state,
    start,
    leave,
    command,
    stop: () => (state.phase === 'off' ? Promise.resolve() : shutdown()),
  }
}

export type Live = ReturnType<typeof createLive>
