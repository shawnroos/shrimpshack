import { describe, expect, test } from 'claude-code/testing'
import type { ProcessRunInit, ProcessRunResult, ProcessSpawnChunk, ProcessSpawnResult } from 'claude-code'

import type { BuildIo, LiveIo, LiveState } from '../hooks/live'
import { createLive, helperBinary, parseEvent, splitLines } from '../hooks/live'
import { failureText } from '../hooks/sources'

function exited(exitCode: number, stdout = '', stderr = ''): ProcessRunResult {
  return { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false }
}

type BuildWorld = { source?: string; hasSwiftc?: boolean; swiftcExit?: number; cached?: string[] }

function buildWorld(options: BuildWorld = {}) {
  const argvs: string[][] = []
  const files = new Set(options.cached ?? [])
  const io: BuildIo = {
    root: '/plug',
    home: async () => '/Users/me',
    read: async path => {
      if (path !== '/plug/helper/peek-web.swift') throw new Error(`no such file ${path}`)
      return options.source ?? 'print("hi")'
    },
    exists: async path => files.has(path),
    run: async (argv: readonly string[], _init?: ProcessRunInit) => {
      argvs.push([...argv])
      const [bin = ''] = argv
      if (bin === 'sh') return options.hasSwiftc === false ? exited(1) : exited(0, '/usr/bin/swiftc\n')
      if (bin === 'swiftc') {
        const exit = options.swiftcExit ?? 0
        if (exit === 0) files.add(argv[argv.indexOf('-o') + 1] ?? '')
        return exited(exit, '', exit === 0 ? '' : 'error: cannot find WebKit')
      }
      if (bin === 'mv') files.add(argv[argv.length - 1] ?? '')
      return exited(0)
    },
  }
  return { io, argvs, files }
}

describe('helperBinary', () => {
  test('the cache path follows the helper source and nothing else', async () => {
    const first = await helperBinary(buildWorld({ source: 'let a = 1' }).io)
    const same = await helperBinary(buildWorld({ source: 'let a = 1' }).io)
    const changed = await helperBinary(buildWorld({ source: 'let a = 2' }).io)
    if (!first.ok || !same.ok || !changed.ok) throw new Error('build failed')
    expect(first.path).toBe(same.path)
    expect(first.path === changed.path).toBe(false)
    expect(first.path.startsWith('/Users/me/.cache/claude-peek/bin/peek-web-')).toBe(true)
  })

  test('a failing swiftc gives live-unavailable and no binary', async () => {
    const world = buildWorld({ swiftcExit: 1 })
    const result = await helperBinary(world.io)
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.failure).toBe('live-unavailable')
    expect(world.argvs.some(argv => argv[0] === 'mv')).toBe(false)
  })

  test('without swiftc nothing else runs', async () => {
    const world = buildWorld({ hasSwiftc: false })
    const result = await helperBinary(world.io)
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.failure).toBe('live-unavailable')
    expect(world.argvs.map(argv => argv[0])).toEqual(['sh'])
  })

  test('a cached binary for the current source skips the build', async () => {
    const built = buildWorld()
    const first = await helperBinary(built.io)
    if (!first.ok) throw new Error('build failed')
    expect(first.isBuilt).toBe(true)
    const world = buildWorld({ cached: [first.path] })
    const again = await helperBinary(world.io)
    expect(again.ok && again.path).toBe(first.path)
    expect(again.ok && again.isBuilt).toBe(false)
    expect(world.argvs).toEqual([])
  })

  test('a build compiles, signs, then moves into place', async () => {
    const world = buildWorld()
    const result = await helperBinary(world.io)
    if (!result.ok) throw new Error('build failed')
    expect(world.argvs.map(argv => argv[0])).toEqual(['sh', 'mkdir', 'swiftc', 'codesign', 'mv'])
    expect(world.argvs[4]?.at(-1)).toBe(result.path)
  })
})

describe('parseEvent', () => {
  test('each event kind parses into its typed shape', () => {
    expect(parseEvent('{"t":"ready","socket":"/t/ctl.sock","dir":"/t","throttled":false}')).toEqual({
      t: 'ready',
      socket: '/t/ctl.sock',
      dir: '/t',
      isThrottled: false,
    })
    expect(parseEvent('{"t":"frame","id":3,"path":"/t/frame-3.png","width":600,"height":400,"bytes":9000}')).toEqual({
      t: 'frame',
      id: 3,
      path: '/t/frame-3.png',
      width: 600,
      height: 400,
    })
    expect(parseEvent('{"t":"nav","url":"https://a.dev/x","title":"X","canBack":true,"canForward":false}')).toEqual({
      t: 'nav',
      url: 'https://a.dev/x',
      title: 'X',
      canBack: true,
      canForward: false,
    })
    expect(parseEvent('{"t":"load","state":"failed","error":"offline"}')).toEqual({ t: 'load', state: 'failed', error: 'offline' })
    expect(parseEvent('{"t":"load","state":"ready"}')).toEqual({ t: 'load', state: 'ready' })
    expect(parseEvent('{"t":"focus","editable":true}')).toEqual({ t: 'focus', isEditable: true })
    expect(parseEvent('{"t":"cookies","present":true}')).toEqual({ t: 'cookies', isPresent: true })
    expect(parseEvent('{"t":"error","message":"refused file:"}')).toEqual({ t: 'error', message: 'refused file:' })
  })

  test('malformed and unknown lines are ignored, not thrown', () => {
    expect(parseEvent('')).toBeNull()
    expect(parseEvent('not json')).toBeNull()
    expect(parseEvent('{"t":"frame","id":"3"}')).toBeNull()
    expect(parseEvent('{"t":"load","state":"sideways"}')).toBeNull()
    expect(parseEvent('{"t":"mystery"}')).toBeNull()
    expect(parseEvent('[1,2]')).toBeNull()
  })
})

describe('splitLines', () => {
  test('a line split across chunks comes out whole', () => {
    const first = splitLines('', '{"t":"focus",')
    expect(first.lines).toEqual([])
    const second = splitLines(first.rest, '"editable":false}\n{"t":"cookies"')
    expect(second.lines).toEqual(['{"t":"focus","editable":false}'])
    expect(second.rest).toBe('{"t":"cookies"')
  })
})

type Posted = { path: string; body?: unknown }

function channel() {
  const queue: ProcessSpawnChunk[] = []
  let wake: (() => void) | null = null
  let isEnded = false
  let isKilled = false
  const done = (): IteratorResult<ProcessSpawnChunk, ProcessSpawnResult> => ({ done: true, value: { code: 1, signal: null } })
  const stream = {
    async next(): Promise<IteratorResult<ProcessSpawnChunk, ProcessSpawnResult>> {
      while (true) {
        if (isKilled) return done()
        const chunk = queue.shift()
        if (chunk) return { done: false, value: chunk }
        if (isEnded) return done()
        await new Promise<void>(resolve => (wake = resolve))
      }
    },
    async return(): Promise<IteratorResult<ProcessSpawnChunk, ProcessSpawnResult>> {
      isKilled = true
      wake?.()
      return done()
    },
    async throw(error: unknown): Promise<IteratorResult<ProcessSpawnChunk, ProcessSpawnResult>> {
      throw error
    },
    [Symbol.asyncIterator]() {
      return stream
    },
  } as AsyncGenerator<ProcessSpawnChunk, ProcessSpawnResult>
  return {
    stream,
    say: (event: unknown) => {
      queue.push({ stream: 'stdout', text: `${JSON.stringify(event)}\n` })
      wake?.()
    },
    end: () => {
      isEnded = true
      wake?.()
    },
    killed: () => isKilled,
  }
}

function liveWorld(options: { swiftcExit?: number } = {}) {
  const build = buildWorld({ swiftcExit: options.swiftcExit })
  const spawns: string[][] = []
  const children: ReturnType<typeof channel>[] = []
  const posted: Posted[] = []
  const removed: string[] = []
  const timers: { at: number; fn: () => void; isCancelled: boolean }[] = []
  let now = 0
  const changes: LiveState[] = []
  const io: LiveIo = {
    ...build.io,
    spawn: argv => {
      spawns.push([...argv])
      const child = channel()
      children.push(child)
      return child.stream
    },
    post: async (socket, path, body) => {
      posted.push(body === undefined ? { path } : { path, body })
      return socket === '/run/ctl.sock'
    },
    after: (ms, fn) => {
      const timer = { at: now + ms, fn, isCancelled: false }
      timers.push(timer)
      return { cancel: () => (timer.isCancelled = true) }
    },
    removeDir: async dir => {
      removed.push(dir)
    },
  }
  const live = createLive(io, state => changes.push(state))
  const settle = async () => {
    for (let i = 0; i < 20; i += 1) await Promise.resolve()
  }
  return {
    live,
    spawns,
    posted,
    removed,
    changes,
    child: (index = 0) => children[index] as ReturnType<typeof channel>,
    paths: () => posted.map(one => one.path),
    settle,
    advance: async (ms: number) => {
      now += ms
      for (const timer of timers.filter(one => !one.isCancelled && one.at <= now)) {
        timer.isCancelled = true
        timer.fn()
      }
      await settle()
    },
    ready: async (index = 0) => {
      children[index]?.say({ t: 'ready', socket: '/run/ctl.sock', dir: '/run', throttled: false })
      await settle()
    },
    frame: async (id: number, index = 0) => {
      children[index]?.say({ t: 'frame', id, path: `/run/frame-${id}.png`, width: 600, height: 400, bytes: 1000 })
      await settle()
    },
  }
}

const VIEW = { width: 600, height: 400 }

describe('live helper manager', () => {
  test('starting spawns once and navigates after ready; a second page only navigates', async () => {
    const w = liveWorld()
    await w.live.start('https://a.dev/', VIEW)
    await w.settle()
    expect(w.spawns.length).toBe(1)
    expect(w.spawns[0]?.slice(1)).toEqual(['--width', '600', '--height', '400'])
    expect(w.posted).toEqual([])
    await w.ready()
    expect(w.posted).toEqual([{ path: 'navigate', body: { url: 'https://a.dev/' } }])
    await w.frame(1)
    expect(w.live.state().phase).toBe('live')
    expect(w.live.state().frame?.path).toBe('/run/frame-1.png')
    await w.live.start('https://b.dev/', VIEW)
    await w.settle()
    expect(w.spawns.length).toBe(1)
    expect(w.posted.at(-1)).toEqual({ path: 'navigate', body: { url: 'https://b.dev/' } })
  })

  test('no frame within 10 s of ready is live-stalled and quits; a slow build does not count', async () => {
    const w = liveWorld()
    await w.live.start('https://a.dev/', VIEW)
    await w.advance(30_000)
    expect(w.live.state().failure).toBeUndefined()
    await w.ready()
    await w.advance(9_000)
    expect(w.live.state().failure).toBeUndefined()
    await w.advance(1_000)
    expect(w.live.state().failure?.kind).toBe('live-stalled')
    expect(w.live.state().phase).toBe('off')
    expect(w.paths()).toContain('quit')
  })

  test('the helper exiting while live is live-crashed and cleans its run directory', async () => {
    const w = liveWorld()
    await w.live.start('https://a.dev/', VIEW)
    await w.ready()
    await w.frame(1)
    w.child().end()
    await w.settle()
    await w.settle()
    expect(w.live.state().failure?.kind).toBe('live-crashed')
    expect(w.live.state().phase).toBe('off')
    expect(w.removed).toEqual(['/run'])
  })

  test('leaving with no cookies quits after 60 s; coming back at 30 s cancels it', async () => {
    const w = liveWorld()
    await w.live.start('https://a.dev/', VIEW)
    await w.ready()
    await w.frame(1)
    w.child().say({ t: 'cookies', present: false })
    await w.settle()
    await w.live.leave()
    expect(w.paths().at(-1)).toBe('pause')
    await w.advance(30_000)
    await w.live.start('https://a.dev/', VIEW)
    expect(w.paths().at(-1)).toBe('resume')
    await w.advance(60_000)
    expect(w.paths()).not.toContain('quit')
    await w.live.leave()
    await w.advance(60_000)
    expect(w.paths().at(-1)).toBe('quit')
    expect(w.child().killed()).toBe(true)
  })

  test('leaving after a cookies report keeps the helper; stop still ends it', async () => {
    const w = liveWorld()
    await w.live.start('https://a.dev/', VIEW)
    await w.ready()
    await w.frame(1)
    w.child().say({ t: 'cookies', present: true })
    await w.settle()
    await w.live.leave()
    await w.advance(600_000)
    expect(w.paths()).not.toContain('quit')
    await w.live.stop()
    expect(w.paths().at(-1)).toBe('quit')
    expect(w.child().killed()).toBe(true)
  })

  test('re-entering the same page resumes without reloading it', async () => {
    const w = liveWorld()
    await w.live.start('https://a.dev/', VIEW)
    await w.ready()
    await w.frame(1)
    await w.live.leave()
    const before = w.posted.length
    await w.live.start('https://a.dev/', VIEW)
    expect(w.posted.slice(before)).toEqual([{ path: 'resume' }])
  })

  test('a viewport change on re-entry sends one resize', async () => {
    const w = liveWorld()
    await w.live.start('https://a.dev/', VIEW)
    await w.ready()
    await w.frame(1)
    await w.live.start('https://a.dev/', { width: 500, height: 300 })
    expect(w.posted.filter(one => one.path === 'resize')).toEqual([{ path: 'resize', body: { width: 500, height: 300 } }])
  })

  test('a non-http URL is refused before anything is sent or spawned', async () => {
    const w = liveWorld()
    expect(await w.live.start('file:///etc/passwd', VIEW)).toBe(false)
    expect(w.spawns).toEqual([])
    await w.live.start('https://a.dev/', VIEW)
    await w.ready()
    expect(await w.live.command('navigate', { url: 'javascript:alert(1)' })).toBe(false)
    expect(w.posted.some(one => JSON.stringify(one.body ?? '').includes('javascript'))).toBe(false)
  })

  test('a failed build is live-unavailable and spawns nothing', async () => {
    const w = liveWorld({ swiftcExit: 1 })
    await w.live.start('https://a.dev/', VIEW)
    expect(w.live.state().failure?.kind).toBe('live-unavailable')
    expect(w.spawns).toEqual([])
  })

  test('nav, load and focus events land in the state', async () => {
    const w = liveWorld()
    await w.live.start('https://a.dev/', VIEW)
    await w.ready()
    w.child().say({ t: 'nav', url: 'https://a.dev/story', title: 'Story', canBack: true, canForward: false })
    w.child().say({ t: 'load', state: 'ready' })
    w.child().say({ t: 'focus', editable: true })
    await w.settle()
    const state = w.live.state()
    expect([state.url, state.title, state.canBack, state.load, state.isEditable]).toEqual(['https://a.dev/story', 'Story', true, 'ready', true])
  })
})

test('each live failure kind has its own title and next action', () => {
  const texts = (['live-unavailable', 'live-crashed', 'live-stalled'] as const).map(failureText)
  expect(new Set(texts.map(text => text.title)).size).toBe(3)
  expect(texts.every(text => text.hint.length > 0)).toBe(true)
  expect(failureText('live-unavailable').hint).toBe('Install the command-line tools with `xcode-select --install`, then press v')
})
