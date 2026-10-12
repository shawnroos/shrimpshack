import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const PAGE = 'https://site.test/post'
// A PNG signature and an 800x600 IHDR chunk: the engine checks both before it draws.
const PNG_HEAD = 'iVBORw0KGgoAAAANSUhEUgAAAyAAAAJYCAIAAAAVFBUn'
const MARKER = '__peek_curl__ '
const VIDEO = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ'
const CONTENT = ['Intro text for the post.', '', `![](${VIDEO})`, '', 'Closing text.', '', '![A diagram](https://site.test/missing.png)'].join('\n')

function mediaWorld(on: On, options: { content?: string; pngBytes?: number } = {}) {
  const ran: string[][] = []
  mock.clock(on, { now: 10 * 3600_000 })
  on('session.id', () => ({ value: 'media-pane' }))
  on('session.cwd', () => ({ value: '/repo' }))
  on('env.get', (_$, e) => ({ value: e.name === 'HOME' ? '/home' : undefined }))
  on('ui.open', () => ({ value: { isPlaced: true as const } }))
  on('ui.toast', () => ({ value: undefined }))
  on('fs.stat', (_$, e) => {
    throw new Error(`ENOENT ${e.path}`)
  })
  on('fs.read', (_$, e) => {
    if (options.pngBytes && e.as === 'bytes' && e.path.endsWith('.png')) return { value: { base64: `${PNG_HEAD}${'A'.repeat(options.pngBytes - PNG_HEAD.length)}` } }
    throw new Error(`ENOENT ${e.path}`)
  })
  on('http.fetch', () => ({ value: { status: 404, ok: false, headers: {} as Record<string, string>, text: '' } }))
  on('process.run', (_$, e) => {
    ran.push([...e.argv])
    const done = (exitCode: number, stdout = '', stderr = '') => ({ value: { exitCode, stdout, stderr, isStdoutTruncated: false, isStderrTruncated: false } })
    const [bin = ''] = e.argv
    if (bin === 'sh') return done(0, 'curl\n')
    if (bin === 'test') return done(0)
    if (bin === 'node') return done(0, JSON.stringify({ content: options.content ?? CONTENT }))
    if (bin === 'sips') return done(0, 'pixelWidth: 800\npixelHeight: 600\n')
    if (bin === '/usr/bin/dscacheutil') return done(0, 'ip_address: 93.184.216.34\n')
    if (bin === 'curl' && e.argv.includes('-o')) return options.pngBytes ? done(0, '200 512 ') : done(22, '404 0 ')
    if (bin === 'curl') return done(0, '<html><head><title>Post</title><meta property="og:description" content="About the post"></head><body><p>Intro</p></body></html>', `${MARKER}200 ${PAGE}`)
    return done(0)
  })
  return { ran }
}

const props = { title: 'Peek', isFocused: true, bodyColumns: 100, placement: 'dock' as const, scroll: { offset: 0, bodyRows: 40 }, view: {} }

test('a video in a reader page shows a play button that opens it in the browser', async ($, on) => {
  const w = mediaWorld(on)
  await $.command.run({ command: 'peek', args: PAGE } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ text: /Intro text for the post/ })).toBeDefined()
  expect(await ui.find({ text: /^VIDEO$/ })).toBeDefined()
  expect(await ui.find({ text: /Closing text/ })).toBeDefined()
  await ui.press({ key: 'media-play-0' })
  expect(w.ran.at(-1)).toEqual(['open', VIDEO])
  await ui.unmount()
})

test('an image that could not be downloaded stays a link to it', async ($, on) => {
  mediaWorld(on)
  await $.command.run({ command: 'peek', args: PAGE } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ text: /^IMAGE$/ })).toBeDefined()
  expect(JSON.stringify(await ui.drawn()).includes('https://site.test/missing.png')).toBe(true)
  await ui.unmount()
})

test('the page description sits inside the DETAILS block; there is no separate PREVIEW block', async ($, on) => {
  mediaWorld(on)
  await $.command.run({ command: 'peek', args: PAGE } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  expect(await ui.find({ text: /^PREVIEW$/ })).toBeUndefined()
  const details = await ui.find({ key: 'remote-meta' })
  expect(JSON.stringify(details).includes('About the post')).toBe(true)
  await ui.unmount()
})

test('a page with more image data than one pane can carry links the overflow instead of failing to draw', async ($, on) => {
  const content = Array.from({ length: 6 }, (_, i) => `Para ${i}.\n\n![shot ${i}](https://site.test/s${i}.png)`).join('\n\n')
  mediaWorld(on, { content, pngBytes: 600_000 })
  await $.command.run({ command: 'peek', args: PAGE } as never)
  const ui = await $.ui.mount({ plugin: 'peek', surface: 'terminal', component: 'Pane', props, requestId: 'peek' })
  const tree = JSON.stringify(await ui.drawn())
  const inline = tree.split(PNG_HEAD).length - 1
  expect(inline * 600_000 <= 2_097_152).toBe(true)
  expect(inline > 0).toBe(true)
  expect(tree.includes('https://site.test/s5.png')).toBe(true)
  await ui.unmount()
})
