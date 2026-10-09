import { expect, mock, test } from 'claude-code/testing'
import type { On, ProcessSpawnChunk } from 'claude-code'
import type { Engine } from 'claude-code/testing'

const PAGE = 'https://news.test/'
const HTML = '<html><head><title>News Test</title></head><body><p>Readable story text.</p></body></html>'

type Helper = { say: (event: unknown) => void; end: () => void }

function liveWorld(on: On) {
  const posted: { path: string; body?: unknown }[] = []
  const spawned: string[][] = []
  const blits: unknown[] = []
  const helpers: Helper[] = []
  let invalidations = 0
  mock.clock(on, { now: 10 * 3600_000 })
  on('session.id', () => ({ value: 'live-pane' }))
  on('session.cwd', () => ({ value: '/repo' }))
  on('env.get', (_$, e) => ({ value: e.name === 'HOME' ? '/home' : undefined }))
  on('ui.open', () => ({ value: { isPlaced: true as const } }))
  on('ui.toast', () => ({ value: undefined }))
  on('ui.blit', (_$, e) => {
    blits.push(e)
    return { value: {} }
  })
  on('ui.invalidate', (_$, e, next) => {
    invalidations += 1
    return next(e)
  })
  on('fs.stat', (_$, e) => {
    throw new Error(`ENOENT ${e.path}`)
  })
  on('fs.exists', (_$, e) => ({ value: e.path.startsWith('/home/.cache/claude-peek/bin/') }))
  on('fs.read', (_$, e) => {
    if (e.path.endsWith('/helper/peek-web.swift')) return { value: 'print("helper")' }
    throw new Error(`ENOENT ${e.path}`)
  })
  on('process.run', () => ({ value: { exitCode: 0, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }))
  on('http.fetch', (_$, e) => {
    if (e.init?.socketPath) {
      const body = e.init.body ? JSON.parse(e.init.body) : undefined
      posted.push(body === undefined ? { path: e.url.replace('http://peek-web/', '') } : { path: e.url.replace('http://peek-web/', ''), body })
      return { value: { status: 200, ok: true, headers: {} as Record<string, string>, text: '{"ok":true}' } }
    }
    if (e.url === PAGE) return { value: { status: 200, ok: true, headers: { 'content-type': 'text/html' } as Record<string, string>, text: HTML } }
    return { value: { status: 404, ok: false, headers: {} as Record<string, string>, text: '' } }
  })
  on('process.spawn', async function* (_$, e) {
    spawned.push([...e.argv])
    const queue: ProcessSpawnChunk[] = []
    let wake: (() => void) | null = null
    let isEnded = false
    helpers.push({
      say: event => {
        queue.push({ stream: 'stdout', text: `${JSON.stringify(event)}\n` })
        wake?.()
      },
      end: () => {
        isEnded = true
        wake?.()
      },
    })
    while (true) {
      const chunk = queue.shift()
      if (chunk) {
        yield chunk
        continue
      }
      if (isEnded) return { value: { code: 1, signal: null } }
      await new Promise<void>(resolve => (wake = resolve))
    }
  })
  const settle = async () => {
    for (let i = 0; i < 400; i += 1) await Promise.resolve()
  }
  return {
    posted,
    spawned,
    blits,
    invalidations: () => invalidations,
    helper: (index = 0) => helpers[index] as Helper,
    settle,
    boot: async (index = 0) => {
      helpers[index]?.say({ t: 'ready', socket: '/run/ctl.sock', dir: '/tmp/peek-web.abc123', throttled: false })
      await settle()
    },
    frame: async (id: number, index = 0) => {
      helpers[index]?.say({ t: 'frame', id, path: `/tmp/peek-web.abc123/frame-${id}.png`, width: 600, height: 400, bytes: 1000 })
      await settle()
    },
  }
}

const props = {
  title: 'Peek',
  isFocused: true,
  bodyColumns: 100,
  placement: 'dock' as const,
  scroll: { offset: 0, bodyRows: 40 },
  view: {},
}

test('the reader page stays up, saying it is starting, until the first frame', async ($, on) => {
  const w = liveWorld(on)
  await $.command.run({ command: 'peek', args: PAGE } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  await ui.press({ key: 'live' })
  await w.settle()
  expect(w.spawned.length).toBe(1)
  expect(await ui.find({ text: /starting live view/ })).toBeDefined()
  expect(await ui.find({ text: /Readable story text/ })).toBeDefined()
  expect(await ui.find({ key: 'live-frame' })).toBeUndefined()
  await ui.unmount()
})

test('covers AE1: v starts live and the first frame replaces the page, footer reads live and the host', async ($, on) => {
  const w = liveWorld(on)
  await $.command.run({ command: 'peek', args: PAGE } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  await ui.press({ key: 'live' })
  await w.settle()
  await w.boot()
  expect(w.posted[0]).toEqual({ path: 'navigate', body: { url: PAGE } })
  await w.frame(1)
  const image = await ui.find({ key: 'live-frame' })
  expect(image).toBeDefined()
  expect((image?.props.source as { file?: string }).file).toBe('/tmp/peek-web.abc123/frame-1.png')
  expect(await ui.find({ text: /live · news\.test/ })).toBeDefined()
  expect(await ui.find({ text: /Readable story text/ })).toBeUndefined()
  await ui.unmount()
})

test('later frames are blitted in place without redrawing the pane', async ($, on) => {
  const w = liveWorld(on)
  await $.command.run({ command: 'peek', args: PAGE } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  await ui.press({ key: 'live' })
  await w.settle()
  await w.boot()
  await w.frame(1)
  await ui.find({ key: 'live-frame' })
  const before = w.invalidations()
  await w.frame(2)
  expect(w.invalidations()).toBe(before)
  expect(w.blits).toEqual([
    { requestId: 'peek', key: 'live-frame', source: { file: '/tmp/peek-web.abc123/frame-2.png', format: 'png', generation: 2 } },
  ])
  await ui.unmount()
})

test('pressing v again returns to the reader page and pauses the helper', async ($, on) => {
  const w = liveWorld(on)
  await $.command.run({ command: 'peek', args: PAGE } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  await ui.press({ key: 'live' })
  await w.settle()
  await w.boot()
  await w.frame(1)
  await ui.press({ key: 'live' })
  await w.settle()
  expect(w.posted.at(-1)).toEqual({ path: 'pause' })
  expect(await ui.find({ text: /Readable story text/ })).toBeDefined()
  expect(await ui.find({ key: 'live-frame' })).toBeUndefined()
  await ui.unmount()
})

test('a GitHub page and a desktop mount offer no live key', async ($, on) => {
  liveWorld(on)
  await $.command.run({ command: 'peek', args: PAGE } as never)
  const desktop = await $.ui.mount({ plugin: 'peek', surface: 'desktop', component: 'Pane', props, requestId: 'peek' })
  expect(await desktop.find({ key: 'live' })).toBeUndefined()
  await desktop.unmount()
  await $.command.run({ command: 'peek', args: 'https://github.com/acme/widgets/pull/42' } as never)
  const terminal = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await terminal.find({ key: 'live' })).toBeUndefined()
  await terminal.unmount()
})

test('a pane resize sends one resize with the new viewport', async ($, on) => {
  const w = liveWorld(on)
  await $.command.run({ command: 'peek', args: PAGE } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  await ui.press({ key: 'live' })
  await w.settle()
  await w.boot()
  await w.frame(1)
  await ui.find({ key: 'live-frame' })
  await ui.unmount()
  const narrow = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props: { ...props, bodyColumns: 70 }, requestId: 'peek' })
  await narrow.find({ key: 'live-frame' })
  await w.settle()
  const resizes = w.posted.filter(one => one.path === 'resize')
  expect(resizes.length).toBe(1)
  const spawnWidth = Number(w.spawned[0]?.[w.spawned[0].indexOf('--width') + 1])
  expect((resizes[0]?.body as { width: number }).width < spawnWidth).toBe(true)
  await narrow.unmount()
})

test('the helper stopping while live returns to the reader page with a one-line reason', async ($, on) => {
  const w = liveWorld(on)
  await $.command.run({ command: 'peek', args: PAGE } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  await ui.press({ key: 'live' })
  await w.settle()
  await w.boot()
  await w.frame(1)
  w.helper().end()
  await w.settle()
  expect(await ui.find({ text: /The live view stopped/ })).toBeDefined()
  expect(await ui.find({ text: /Readable story text/ })).toBeDefined()
  await ui.unmount()
})

test('with the menu open, live frames keep updating behind it', async ($, on) => {
  const w = liveWorld(on)
  await $.command.run({ command: 'peek', args: PAGE } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  await ui.press({ key: 'live' })
  await w.settle()
  await w.boot()
  await w.frame(1)
  await $.command.run({ command: 'peek-menu' } as never)
  expect(await ui.find({ key: 'live-frame' })).toBeDefined()
  expect(await ui.find({ text: /COMMANDS/ })).toBeDefined()
  await w.frame(2)
  expect(w.blits.length).toBe(1)
  await ui.unmount()
})

async function goLive($: Engine, w: ReturnType<typeof liveWorld>) {
  await $.command.run({ command: 'peek', args: PAGE } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  await ui.press({ key: 'live' })
  await w.settle()
  await w.boot()
  await w.frame(1)
  await ui.find({ key: 'live-input' })
  return ui
}

const inputs = (w: ReturnType<typeof liveWorld>) => w.posted.filter(one => one.path === 'input').flatMap(one => (one.body as { events: unknown[] }).events)

test('a click on the frame clicks the page at the matching point', async ($, on) => {
  const w = liveWorld(on)
  const ui = await goLive($, w)
  const layer = await ui.find({ key: 'live-input' })
  const columns = layer?.props.width as number
  await ui.pointer({ type: 'down', button: 'left', x: Math.floor(columns / 2), y: 0, in: 'live-input' })
  await w.settle()
  const [click] = inputs(w) as { type: string; x: number; y: number }[]
  expect(click?.type).toBe('click')
  expect(Math.abs((click?.x ?? 0) - Number(w.spawned[0]?.[w.spawned[0].indexOf('--width') + 1]) / 2) < 10).toBe(true)
  await ui.unmount()
})

test('covers AE3: after a click on a field, typed text and Enter reach the page in order', async ($, on) => {
  const w = liveWorld(on)
  const ui = await goLive($, w)
  await ui.pointer({ type: 'down', button: 'left', x: 3, y: 3, in: 'live-input' })
  w.helper().say({ t: 'focus', editable: true })
  await w.settle()
  for (const key of ['w', 'e', 'b', 'k', 'i', 't', 'return']) await ui.key({ key, in: 'live-input' })
  await w.settle()
  const sent = inputs(w).slice(1) as { type: string; text?: string; key?: string }[]
  expect(sent.map(one => one.text ?? `<${one.key}>`).join('')).toBe('webkit<Enter>')
  expect(sent.at(-1)).toEqual({ type: 'key', key: 'Enter' })
  expect(await ui.find({ key: 'done-typing' })).toBeDefined()
  await ui.unmount()
})

test('two key events posted in one frame are both delivered', async ($, on) => {
  const w = liveWorld(on)
  const ui = await goLive($, w)
  await ui.pointer({ type: 'down', button: 'left', x: 3, y: 3, in: 'live-input' })
  w.helper().say({ t: 'focus', editable: true })
  await w.settle()
  await ui.post({ liveInput: [{ seq: 90, type: 'key', key: 'a' }, { seq: 91, type: 'key', key: 'b' }] }, { in: 'live-input' })
  await ui.post({ liveInput: [{ seq: 90, type: 'key', key: 'a' }, { seq: 91, type: 'key', key: 'b' }] }, { in: 'live-input' })
  await w.settle()
  expect(inputs(w).filter(one => (one as { type: string }).type === 'text')).toEqual([{ type: 'text', text: 'ab' }])
  await ui.unmount()
})

test('Done typing stops forwarding text, and j then scrolls the live page', async ($, on) => {
  const w = liveWorld(on)
  const ui = await goLive($, w)
  await ui.pointer({ type: 'down', button: 'left', x: 3, y: 3, in: 'live-input' })
  w.helper().say({ t: 'focus', editable: true })
  await w.settle()
  await ui.press({ key: 'done-typing' })
  expect(await ui.find({ key: 'done-typing' })).toBeUndefined()
  await ui.key({ key: 'j', in: 'live-input' })
  await w.settle()
  const last = inputs(w).at(-1) as { type: string; dy: number }
  expect([last.type, last.dy > 0]).toEqual(['scroll', true])
  await ui.unmount()
})

test('covers AE2: after a click on a link, b goes back in the page instead of typing', async ($, on) => {
  const w = liveWorld(on)
  const ui = await goLive($, w)
  await ui.pointer({ type: 'down', button: 'left', x: 3, y: 3, in: 'live-input' })
  w.helper().say({ t: 'focus', editable: false })
  w.helper().say({ t: 'nav', url: 'https://news.test/story', title: 'Story', canBack: true, canForward: false })
  await w.settle()
  await ui.key({ key: 'b', in: 'live-input' })
  await w.settle()
  expect(w.posted.at(-1)).toEqual({ path: 'back' })
  expect(inputs(w).some(one => (one as { type: string }).type === 'text')).toBe(false)
  await ui.unmount()
})

test('j on the pane while live scrolls the page at its centre', async ($, on) => {
  const w = liveWorld(on)
  const ui = await goLive($, w)
  await ui.press({ key: 'next' })
  await w.settle()
  const last = inputs(w).at(-1) as { type: string; x: number; y: number; dy: number }
  const width = Number(w.spawned[0]?.[w.spawned[0].indexOf('--width') + 1])
  expect([last.type, last.x, last.dy > 0]).toEqual(['scroll', Math.floor(width / 2), true])
  await ui.unmount()
})
